#import "TreeBuilder.h"

#include <fts.h>
#include <sys/stat.h>
#include <sys/mount.h>

#import "AlertMessage.h"
#import "PlainFileItem.h"
#import "DirectoryItem.h"
#import "ScanTreeRoot.h"
#import "CompoundItem.h"
#import "TreeContext.h"
#import "FilterSet.h"
#import "FilteredTreeGuide.h"
#import "TreeBalancer.h"
#import "NSURL.h"
#import "ControlConstants.h"
#import "LogManager.h"

#import "ScanProgressTracker.h"
#import "UniformType.h"
#import "UniformTypeInventory.h"
#import "PreferencesPanelControl.h"


NSString  *LogicalFileSizeName = @"logical";
NSString  *PhysicalFileSizeName = @"physical";
NSString  *TallyFileSizeName = @"tally";

// Options for PackageCheckBehavior preference
NSString  *RobustBehavior = @"robust";
NSString  *AdaptiveBehavior = @"adaptive";
NSString  *FastBehavior = @"fast";

/* Use smaller bounds given the extra scan cost needed to determine the number of directories
 * at each level used for tracking progress.
 */
#define  NUM_SCAN_PROGRESS_ESTIMATE_LEVELS MIN(6, NUM_PROGRESS_ESTIMATE_LEVELS)

static const int AUTORELEASE_PERIOD = 1024;

/* Helper class that is used to temporarily store additional info for directories that are being
 * scanned. It stores the info that is not maintained by the DirectoryItem class yet is needed
 * while its contents are still being scanned.
 */
@interface ScanStackFrame : NSObject {
@public
  // The parent for the new children
  DirectoryItem  *parent;

  // The node where to collect the children. For normal scans it is the same as "parent" but for
  // shallow scans it is different, as the sizes of the sub-directory children are not yet known,
  // which is a pre-requisite before they can be added to their parent directory.
  DirectoryItem  *collector;

  FTSENT  *entp;
}

- (instancetype) init NS_DESIGNATED_INITIALIZER;

// Convenience "constructors" for repeated usage
- (void) initWithParent:(DirectoryItem *)parent entp:(FTSENT *)entp;

- (void) initWithParent:(DirectoryItem *)parent
              collector:(DirectoryItem *)collector
                   entp:(FTSENT *)entp;

- (void) resetFrame;

@end // @interface ScanStackFrame


@interface TreeBuilder (PrivateMethods)

+ (item_size_t) getLogicalFileSize:(FTSENT *)entp withType:(UTType *)fileType;

- (NSURL *)getVolumeRoot:(NSURL *)url;

// Create alert with details of failure
- (void) scanFailed:(NSString *)details;

/* Creates a tree context for the volume containing the path.
 *
 * The path should point to a directory. Returns nil if it does not. In this case, an alert
 * message is also set.
 */
- (TreeContext *)treeContextForVolumeContaining:(NSString *)path;

- (ScanTreeRoot *)treeRootForPath:(NSString *)path
                          context:(TreeContext *)treeContext;

- (void) addToStack:(DirectoryItem *)dirItem entp:(FTSENT *)entp;
- (BOOL) unwindStackToParent:(FTSENT *)entp;

- (FileItem *)finalizeStackFrame:(ScanStackFrame *)stackFrame;

- (BOOL) visitItem:(FTSENT *)entp
            parent:(ScanStackFrame *)parent
           recurse:(BOOL)visitDescendants;
- (BOOL) visitHardLinkedItem:(FTSENT *)entp;

// Return the number of sub-folders of the (directory) item last returned by fts_read
- (int) determineNumSubFolders;

- (FTSENT *)startScan:(NSString *)path;
- (void) stopScan;

@end // @interface TreeBuilder (PrivateMethods)


CFAbsoluteTime convertTimespec(struct timespec ts) {
  // Ignore nanoseconds; we do not need sub-second accuracy
  return (CFAbsoluteTime)((CFTimeInterval)ts.tv_sec - kCFAbsoluteTimeIntervalSince1970);
}

@implementation ScanStackFrame

// Overrides super's designated initialiser.
- (instancetype) init {
  if (self = [super init]) {
    parent = nil;
    collector = nil;
  }
  return self;
}

// "Constructor" intended for repeated usage. It assumes init has already been invoked
- (void) initWithParent:(DirectoryItem *)parentVal
                   entp:(FTSENT *)entpVal {
  [self initWithParent: parentVal collector: parentVal entp: entpVal];
}

// "Constructor" intended for repeated usage. It assumes init has already been invoked
- (void) initWithParent:(DirectoryItem *)parentVal
              collector:(DirectoryItem *)collectorVal
                   entp:(FTSENT *)entpVal {
  if (parent != parentVal) {
    [parent release];
  }
  parent = [parentVal retain];

  if (collector != collectorVal) {
    [collector release];
  }
  collector = [collectorVal retain];

  entp = entpVal;
}

// Reset frame for re-use (and avoid unnecessary memory retention)
- (void) resetFrame {
  entp = NULL;

  [parent release];
  parent = nil;

  [collector release];
  collector = nil;
}

- (void) dealloc {
  [self resetFrame];

  [super dealloc];
}

@end // @implementation ScanStackFrame


@implementation TreeBuilder

+ (NSArray *)fileSizeMeasureNames {
  static NSArray  *fileSizeMeasureNames = nil;
  static dispatch_once_t  onceToken;

  dispatch_once(&onceToken, ^{
    fileSizeMeasureNames = [@[LogicalFileSizeName, PhysicalFileSizeName, TallyFileSizeName] retain];
  });

  return fileSizeMeasureNames;
}

- (instancetype) init {
  return [self initWithFilterSet: nil];
}


- (instancetype) initWithFilterSet:(FilterSet *)filterSetVal {
  if (self = [super init]) {
    filterSet = [filterSetVal retain];

    treeGuide = [[FilteredTreeGuide alloc] initWithFileItemTest: filterSet.fileItemTest];
    [treeGuide setPackagesAsFiles: filterSet.packagesAsFiles];

    treeBalancer = [[TreeBalancer alloc] init];
    treeBalanceDispatchQueue = TreeBalancer.dispatchQueue;
    typeInventory = [UniformTypeInventory.defaultUniformTypeInventory retain];

    ftsp = NULL;

    hardLinkedFileNumbers = [[NSMutableSet alloc] initWithCapacity: 32];
    abort = NO;
    
    progressTracker =
      [[ScanProgressTracker alloc] initWithMaxLevel: NUM_SCAN_PROGRESS_ESTIMATE_LEVELS];
    
    dirStack = [[NSMutableArray alloc] initWithCapacity: 16];
    
    [self setFileSizeMeasure: LogicalFileSizeName];
    
    logger = LogManager.defaultLogManager.mainLog;
    trustedLogger = LogManager.defaultLogManager.trustedLog;

    NSUserDefaults *args = NSUserDefaults.standardUserDefaults;
    NSString  *behavior = [args stringForKey: PackageCheckBehaviorKey];
    fastPackageCheckEnabled = ([behavior isEqualToString: FastBehavior]
                               || ([behavior isEqualToString: AdaptiveBehavior]
                                   && !filterSet.packagesAsFiles));
    os_log_info(logger, "fastPackageCheckEnabled = %d", fastPackageCheckEnabled);

    _alertMessage = nil;
  }
  return self;
}


- (void) dealloc {
  [filterSet release];

  [treeGuide release];
  [treeBalancer release];
  [typeInventory release];

  NSAssert(ftsp == NULL, @"ftsp not closed");

  [hardLinkedFileNumbers release];
  [fileSizeMeasureName release];
  
  [progressTracker release];
  
  [dirStack release];

  [_alertMessage release];
  
  [super dealloc];
}


- (NSString *)fileSizeMeasure {
  return fileSizeMeasureName;
}

- (void) setFileSizeMeasure:(NSString *)measure {
  if ([measure isEqualToString: LogicalFileSizeName]) {
    fileSizeMeasure = LogicalFileSize;
  }
  else if ([measure isEqualToString: PhysicalFileSizeName]) {
    fileSizeMeasure = PhysicalFileSize;
  }
  else if ([measure isEqualToString: TallyFileSizeName]) {
    fileSizeMeasure = TallyFileSize;
  }
  else {
    NSAssert(NO, @"Invalid file size measure.");
  }
  
  if (measure != fileSizeMeasureName) {
    [fileSizeMeasureName release];
    fileSizeMeasureName = [measure retain];
  }
}


- (void) abort {
  abort = YES;
}

- (TreeContext *)buildTreeForPath:(NSString *)path {
  TreeContext  *treeContext = [self treeContextForVolumeContaining: path];
  if (treeContext == nil) {
    return nil;
  }

  DirectoryItem  *scanTree = [self treeRootForPath: path context: treeContext];

  numDirectoryReadErrors = 0;
  numSkippedDataless = 0;
  [progressTracker startingTask];

  BOOL  ok = [self buildTreeForDirectory: scanTree atPath: path];

  [progressTracker finishedTask];
  if (numDirectoryReadErrors) {
    os_log_info(logger,
                "Failed to read %lu directories (enable full logging for details)",
                numDirectoryReadErrors);
  }
  if (numSkippedDataless) {
    os_log_info(logger,
                "Skipped scanning of %lu dataless folders (enable full logging for details)",
                numSkippedDataless);
  }

  if (! ok) {
    return nil;
  }

  [treeContext setScanTree: scanTree];
  _alertMessage = [[self createAlertMessage: scanTree] retain];

  return treeContext;
}

- (NSDictionary *)progressInfo {
  // To be safe, do not return info when aborted. Auto-releasing parts of constructed tree could
  // invalidate path construction done by progressTracker. Even though it does not look that could
  // happen with current code, it could after some refactoring.
  return abort ? nil : progressTracker.progressInfo;
}

@end // @implementation TreeBuilder


@implementation TreeBuilder (ProtectedMethods)

- (BOOL) buildTreeForDirectory:(DirectoryItem *)dirItem atPath:(NSString *)path {
  return [self scanTreeForDirectory: dirItem atPath: path];
}

- (BOOL) scanTreeForDirectory:(DirectoryItem *)dirItem atPath:(NSString *)path {
  os_log_debug(logger, "scanTreeForDirectory %@", path);

  NSAutoreleasePool  *autoreleasePool = nil;
  int  i = 0;
  dirStackTopIndex = -1;

  [self addToStack: dirItem entp: [self startScan: path]];

  @try {
    FTSENT *entp;
    while (!abort && (entp = fts_read(ftsp)) != NULL) {

      switch (entp->fts_info) {
        case FTS_DP:
          // Directory being visited a second time
          // Note: not popping from stack here, as this event can also occur without the item
          // being added to the stack (when the directory should be skipped)
          continue;
        case FTS_DNR:
        case FTS_ERR:
        case FTS_NS:
          numDirectoryReadErrors++;
          // Optionally log to trusted logger, which is disabled by default.
          os_log_info(trustedLogger, "Error reading directory %{public}s: %s",
                      entp->fts_path, strerror(entp->fts_errno));
          continue;
      }

      BOOL  popped = [self unwindStackToParent: entp->fts_parent];
      NSAssert1(popped, @"Failed to unwind to %s", entp->fts_parent->fts_path);

      ScanStackFrame  *parent = dirStack[dirStackTopIndex];

      if (![self visitItem: entp parent: parent recurse: YES]) {
        fts_set(ftsp, entp, FTS_SKIP);
      }

      if (++i == AUTORELEASE_PERIOD) {
        [autoreleasePool release];
        autoreleasePool = [[NSAutoreleasePool alloc] init];
        i = 0;
      }
    }

    [self unwindStackToParent: nil];
    NSAssert(dirStackTopIndex == -1, @"Final stack unwind failed?");
  }
  @finally {
    [autoreleasePool release];
    [self stopScan];
  }

  // Wait for the tree balancing to end
  dispatch_sync(treeBalanceDispatchQueue, ^{});

  return !abort;
}

- (DirectoryItem *)getContentsForDirectory:(DirectoryItem *)dirItem
                                    atPath:(NSString *)path {
  ScanStackFrame  *parent = [[[ScanStackFrame alloc] init] autorelease];
  DirectoryItem  *collector = (DirectoryItem *)[dirItem duplicateFileItem: dirItem.parentDirectory];

  [parent initWithParent: dirItem collector: collector entp: [self startScan: path]];

  FTSENT *entp;
  while ((entp = fts_read(ftsp)) != NULL) {
    if (entp->fts_info == FTS_DP) continue; // Directory being visited a second time

    BOOL  isDirectory = S_ISDIR(entp->fts_statp->st_mode);
    [self visitItem: entp parent: parent recurse: NO];
    if (isDirectory) {
      fts_set(ftsp, entp, FTS_SKIP);
    }
  }

  [self stopScan];

  return collector;
}

- (AlertMessage *)createAlertMessage:(DirectoryItem *)scanTree {
  if (fileSizeMeasure == LogicalFileSize) {
    if (scanTree.itemSize > totalPhysicalSize) {
      AlertMessage  *alert = [[[AlertMessage alloc] init] autorelease];
      alert.messageText = NSLocalizedString
        (@"The reported total size is larger than the actual size on disk", @"Alert message");
      NSString *fmt = NSLocalizedString
        (@"The actual (physical) size is %.1f%% of the reported (logical) size. Consider rescanning using the Physical file size measure",
         @"Alert message");
      float percentage = (100.0 * totalPhysicalSize) / scanTree.itemSize;
      alert.informativeText = [NSString stringWithFormat: fmt, percentage];
      return alert;
    }

    if (numOverestimatedFiles > 0) {
      AlertMessage  *alert = [[[AlertMessage alloc] init] autorelease];
      alert.messageText = NSLocalizedString
        (@"The reported size of some files is larger than their actual size on disk",
         @"Alert message");
      NSString *fmt = NSLocalizedString
        (@"For %d files the reported (logical) size is larger than their actual (physical) size. Consider rescanning using the Physical file size measure",
         @"Alert message");
      alert.informativeText = [NSString stringWithFormat: fmt, numOverestimatedFiles];
      return alert;
    }
  }

  return nil;
}

@end // @implementation TreeBuilder (ProtectedMethods)


@implementation TreeBuilder (PrivateMethods)

+ (item_size_t) getLogicalFileSize:(FTSENT *)entp withType:(UTType *)fileType {
  if ([fileType.identifier isEqualToString: @"com.apple.icloud-file-fault"]) {
    NSURL  *url = [NSURL fileURLWithFileSystemRepresentation: entp->fts_path
                                                 isDirectory: S_ISDIR(entp->fts_statp->st_mode)
                                               relativeToURL: NULL];
    NSDictionary  *dict = [NSDictionary dictionaryWithContentsOfURL: url];
    NSNumber  *fileSize = [dict objectForKey: @"NSURLFileSizeKey"];

    return fileSize.unsignedLongLongValue;
  } else {
    return entp->fts_statp->st_size;
  }
}

- (NSURL *)getVolumeRoot:(NSURL *)url {
  NSError  *error = nil;
  NSURL  *volumeRoot = nil;

  [url getResourceValue: &volumeRoot forKey: NSURLVolumeURLKey error: &error];
  if (error != nil) {
    os_log(logger, "Failed to determine volume root of %@: %@", url, error.description);
    return nil;
  }
  os_log_info(logger, "VolumeURLKey: url = %@, volumeRoot = %@", url, volumeRoot);

  if ([url.path hasPrefix: volumeRoot.path]) {
    return volumeRoot;
  }

  os_log(logger, "Volume root prefix mismatch");

  // Try to determine the volume root the hard way. Traverse up the folder hierarchy until a
  // folder is found that is a volume root.
  volumeRoot = url;
  while (true) {
    NSNumber* isVolume;
    [volumeRoot getResourceValue: &isVolume forKey: NSURLIsVolumeKey error: &error];

    if (error != nil) {
      os_log(logger, "Failed to get IsVolumeKey for %@", volumeRoot);
      return nil;
    }

    if (isVolume.boolValue) {
      os_log_info(logger, "Found volume root %@", volumeRoot);
      return volumeRoot;
    }

    NSUInteger lenBefore = volumeRoot.path.length;
    volumeRoot = volumeRoot.URLByDeletingLastPathComponent;
    if (volumeRoot.path.length >= lenBefore) {
      os_log(logger, "Terminating traversal at %@ without finding volume root", volumeRoot);
      return nil;
    }
  }

  return nil;
}

- (void) scanFailed:(NSString *)details {
  [_alertMessage release];

  _alertMessage = [[AlertMessage alloc] init];
  _alertMessage.messageText = NSLocalizedString(@"Scanning failed", @"Alert message");
  _alertMessage.informativeText = details;
}

- (TreeContext *)treeContextForVolumeContaining:(NSString *)path {
  NSURL  *url = [NSURL fileURLWithPath: path];

  if (!url.isDirectory) {
    // This may happen when the directory has been deleted (which can happen when rescanning)
    os_log(logger, "Path to scan %@ is not a directory.", path);

    NSString *fmt = NSLocalizedString
      (@"The path %@ does not exist or is not a folder", @"Alert message");
    [self scanFailed: [NSString stringWithFormat: fmt, path]];

    return nil;
  }

  NSError  *error = nil;
  NSURL  *volumeRoot = [self getVolumeRoot: url];
  if (volumeRoot == nil) {
    // TODO: Check if there is fallback logic that could be used instead

    NSString *details = NSLocalizedString(@"Failed to determine volume root", @"Alert message");
    [self scanFailed: details];

    return nil;
  }

  NSNumber  *freeSpace;
  [volumeRoot getResourceValue: &freeSpace forKey: NSURLVolumeAvailableCapacityKey error: &error];
  if (error != nil) {
    os_log(logger, "Failed to determine free space for %@: %@", volumeRoot, error.description);
  }

  NSNumber  *volumeSize;
  [volumeRoot getResourceValue: &volumeSize forKey: NSURLVolumeTotalCapacityKey error: &error];
  if (error != nil) {
    os_log(logger, "Failed to determine capacity of %@: %@", volumeRoot, error.description);
  }

  NSString  *volumeFormat;
  [volumeRoot getResourceValue: &volumeFormat forKey: NSURLVolumeLocalizedFormatDescriptionKey
                         error: &error];
  if (error == nil) {
    os_log_info(logger, "Volume format = %{public}@", volumeFormat);
  }

  ignoreHardLinksForDirectories = NO; // Default
  struct statfs volinfo;
  if (statfs(volumeRoot.path.fileSystemRepresentation, &volinfo) == 0) {
    os_log_info(logger, "fstypename = %{public}s", volinfo.f_fstypename);
    if (strcmp("apfs", volinfo.f_fstypename) == 0) {
      // APFS does not support hardlinking directories. However, directories will have a non-zero
      // hardlink count, as each file it contains increases the count. So ignore this count when
      // deciding if a directory should be visited in APFS
      ignoreHardLinksForDirectories = YES;
    }
  }
  os_log_info(logger, "ignoreHardLinksForDirectories = %d", ignoreHardLinksForDirectories);

  return [[[TreeContext alloc] initWithVolumePath: volumeRoot.path
                                  fileSizeMeasure: fileSizeMeasureName
                                       volumeSize: volumeSize.unsignedLongLongValue
                                        freeSpace: freeSpace.unsignedLongLongValue
                                        filterSet: filterSet
                                      monitorPath: path] autorelease];
}

- (ScanTreeRoot *)treeRootForPath:(NSString *)path
                          context:(TreeContext *)treeContext {
  // Determine relative path
  NSString  *volumePath = treeContext.volumeTree.systemPathComponent;
  NSString  *relativePath =
    volumePath.length < path.length ? [path substringFromIndex: volumePath.length] : @"";
  if (relativePath.absolutePath) {
    // Strip leading slash.
    relativePath = [relativePath substringFromIndex: 1];
  }

  NSFileManager  *manager = NSFileManager.defaultManager;
  if (relativePath.length > 0) {
    os_log_info(logger, "Scanning volume %@ [%@], starting at %@",
                volumePath, [manager displayNameAtPath: volumePath], relativePath);
  }
  else {
    os_log_info(logger, "Scanning entire volume %@ [%@].",
                volumePath, [manager displayNameAtPath: volumePath]);
  }

  // Get the properties
  NSURL  *treeRootURL = [NSURL fileURLWithPath: path];
  FileItemOptions  flags = 0;
  if (treeRootURL.isPackage) {
    flags |= FileItemIsPackage;
  }
  if (treeRootURL.isHardLinked) {
    flags |= FileItemIsHardlinked;
  }

  ScanTreeRoot  *scanTree = [[[ScanTreeRoot alloc] initWithLabel: relativePath
                                                          parent: treeContext.scanTreeParent
                                                           flags: flags
                                                    creationTime: treeRootURL.creationTime
                                                modificationTime: treeRootURL.modificationTime
                                                      accessTime: treeRootURL.accessTime
                             ] autorelease];

  // Reset other state
  totalPhysicalSize = 0;
  numOverestimatedFiles = 0;
  [hardLinkedFileNumbers removeAllObjects];
  [_alertMessage release];
  _alertMessage = nil;

  return scanTree;
}

- (void) addToStack:(DirectoryItem *)dirItem entp:(FTSENT *)entp {
//  os_log_debug(logger, "Push: %s", entp->fts_path);

  // Expand stack if required
  if (dirStackTopIndex + 1 == (int)dirStack.count) {
    [dirStack addObject: [[[ScanStackFrame alloc] init] autorelease]];
  }
  
  // Add the item to the stack. Overwriting the previous entry.
  [dirStack[++dirStackTopIndex] initWithParent: dirItem entp: entp];
  
  [treeGuide descendIntoDirectory: dirItem];
  [progressTracker processingFolder: dirItem];

  // Log to trusted logger as this message is not useful when anonymized.
  // This logger needs to be explicitly enabled. It is disabled by default.
  os_log_debug(trustedLogger, "Scanning %{public}s", entp->fts_path);

  if (dirStackTopIndex < NUM_SCAN_PROGRESS_ESTIMATE_LEVELS) {
    [progressTracker setNumSubFolders: [self determineNumSubFolders]];
  }
}

- (BOOL) unwindStackToParent:(FTSENT *)entp {
  FileItem  *finalizedSubdir = nil;
  while (dirStackTopIndex >= 0) {
    ScanStackFrame  *topDir = dirStack[dirStackTopIndex];

    if (finalizedSubdir != nil) {
      [topDir->collector addSubdir: finalizedSubdir];
      finalizedSubdir = nil;
    }

    if (topDir->entp == entp) {
      return YES;
    }

    finalizedSubdir = [self finalizeStackFrame: topDir];
    [topDir resetFrame];
    dirStackTopIndex--;
  }

  return NO;
}

- (FileItem *)finalizeStackFrame:(ScanStackFrame *)topDir {
//  os_log_debug(logger, "Pop: %s", topDir->entp->fts_path);

  DirectoryItem  *dirItem = topDir->parent;
  [dirItem setSize]; // Fix the size

  [treeGuide emergedFromDirectory: dirItem];
  [progressTracker processedFolder: dirItem];

  if ([treeGuide includeFileItem: dirItem] == nil) {
    return nil;
  }

  dispatch_async(treeBalanceDispatchQueue, ^{ [dirItem balanceTree: treeBalancer]; });

  // Let it survive after scan stack frame is reset
  return [[dirItem retain] autorelease];
}

- (BOOL) visitItem:(FTSENT *)entp
            parent:(ScanStackFrame *)parent
           recurse:(BOOL)visitDescendants {
  FileItemOptions  flags = 0;
  struct stat  *statBlock = entp->fts_statp;
  BOOL  isDirectory = S_ISDIR(statBlock->st_mode);

  // Apple File System (APFS) does not support hard-links to directories, but has "hard links"
  // for each file a directory contains (including . and ..). So a possible optimization is to skip
  // the hardlink check for directories on APFS as this will greatly reduce the size of the set
  // used to track the hard-linked items. Note, some directories in /System/Volumes have the same
  // inode but their contents differ so there's no duplication in scanning each of these.
  if (statBlock->st_nlink > 1 && !(isDirectory && ignoreHardLinksForDirectories)) {
    flags |= FileItemIsHardlinked;

    if (![self visitHardLinkedItem: entp]) {
      // Do not visit descendants if the item was a directory
      if (isDirectory) {
        visitDescendants = NO;
      }

      return visitDescendants;
    }
  }

  NSString  *lastPathComponent = [NSString stringWithUTF8String: entp->fts_name];

  if (isDirectory) {
    if (!fastPackageCheckEnabled || lastPathComponent.pathExtension.length > 0) {
      // The package check is relatively expensive (it consumes about 30% of total scanning time).
      //
      // As most packages are identified by extension and few normal directories have an extension,
      // an optimization it to only perform this check if the path has an extension. A drawback is
      // that this fails to identify some packages. On my macOS 12.6.3 on 2023/05 this applies to
      // ~/Pictures/Photo Booth Library and ~/Library/Application Support/SyncServices/Local.
      NSURL  *url = [NSURL fileURLWithFileSystemRepresentation: entp->fts_path
                                                   isDirectory: YES
                                                 relativeToURL: NULL];
      if (url.isPackage) {
        flags |= FileItemIsPackage;
      }
    }
    
    DirectoryItem  *dirChildItem = [[DirectoryItem alloc]
                                    initWithLabel: lastPathComponent
                                           parent: parent->parent
                                            flags: flags
                                     creationTime: convertTimespec(statBlock->st_birthtimespec)
                                 modificationTime: convertTimespec(statBlock->st_mtimespec)
                                       accessTime: convertTimespec(statBlock->st_atimespec)];

    bool skip = true;
    if (statBlock->st_flags & SF_DATALESS) {
      // Do not scan contents of folders that are not already available offline. Doing so would
      // trigger download of their contents. This is unwanted, as the state of the volume should
      // not change as a result of the scan. Additionally, it would slow down scanning
      // unnecessarily (and block scanning if there is no network access).
      numSkippedDataless++;
      os_log_info(trustedLogger, "Skipping scan of dataless folder %s", entp->fts_path);
    } else if ([lastPathComponent isEqualToString: @"Data"] &&
               [dirChildItem.path isEqualToString: @"/System/Volumes/Data"]) {
      // Do not scan the contents of the System Data volume to prevent its contents from being
      // scanned twice (as the contents also appear inside the root via firmlinks). Ideally, we use
      // a more generic mechanism for this, similar to how hardlinks are handled, but there does
      // not yet seem to be an API to support this.
      os_log_info(logger, "Skipping scan of data volume %s", entp->fts_path);
    } else if (![treeGuide shouldDescendIntoDirectory: dirChildItem]) {
      os_log_info(logger, "Skipping scan of %s (filtered out)", entp->fts_path);
    } else {
      skip = false;
    }

    if (skip) {
      [progressTracker skippedFolder: dirChildItem];
      visitDescendants = NO;
    } else {
      if (visitDescendants) {
        [self addToStack: dirChildItem entp: entp];
      } else {
        // When performing a shallow scan, we cannot apply a filter based on its contents (size).
        [parent->collector addSubdir: dirChildItem];
      }
    }

    [dirChildItem release];
  }
  else { // A file node.
    // According to stat(2) documentation, st_blocks returns the number of 512B blocks allocated.
    item_size_t  physicalFileSize = statBlock->st_blocks * 512;
    item_size_t  fileSize;

    UTType  *fileType = [typeInventory uniformTypeForExtension: lastPathComponent.pathExtension];

    switch (fileSizeMeasure) {
      case LogicalFileSize: {
        fileSize = [TreeBuilder getLogicalFileSize: entp withType: fileType];
        totalPhysicalSize += physicalFileSize;

        if (fileSize > physicalFileSize) {
          os_log_info(logger, "Warning: logical file size larger than physical file size for %s (%llu > %llu)",
                      entp->fts_path, fileSize, physicalFileSize);
          numOverestimatedFiles++;
        }
        break;
      }
      case PhysicalFileSize:
        fileSize = physicalFileSize;
        break;
      case TallyFileSize:
        fileSize = 1;
    }

    PlainFileItem  *fileChildItem =
      [[PlainFileItem alloc] initWithLabel: lastPathComponent
                                    parent: parent->parent
                                      size: fileSize
                                      type: fileType
                                     flags: flags
                              creationTime: convertTimespec(statBlock->st_birthtimespec)
                          modificationTime: convertTimespec(statBlock->st_mtimespec)
                                accessTime: convertTimespec(statBlock->st_atimespec)];

    // Only add file items that pass the filter test.
    if ( [treeGuide includeFileItem: fileChildItem] ) {
      [parent->collector addFile: fileChildItem];
    }

    [fileChildItem release];
  }

  return visitDescendants;
}


/* Returns YES if item should be included in the tree. It returns NO when the item is hard-linked
 * and has already been encountered.
 */
- (BOOL) visitHardLinkedItem:(FTSENT *)entp {
  NSNumber  *fileNumber = [NSNumber numberWithUnsignedLongLong: entp->fts_statp->st_ino];
  NSUInteger  sizeBefore = hardLinkedFileNumbers.count;

  [hardLinkedFileNumbers addObject: fileNumber];

  return sizeBefore < hardLinkedFileNumbers.count; // Only scan newly encountered items
}

- (FTSENT *)startScan:(NSString *)path {
  char*  paths[2] = {(char *)path.UTF8String, NULL};
  ftsp = fts_open(paths, FTS_PHYSICAL | FTS_XDEV, NULL);

  if (ftsp == NULL) {
    os_log_error(logger, "Error: fts_open failed for %@", path);
    return NULL;
  }

  // Get the root directory out of the way
  return fts_read(ftsp);
}

- (void) stopScan {
  fts_close(ftsp);
  ftsp = NULL;
}

- (int) determineNumSubFolders {
  int  numSubDirs = 0;
  FTSENT *entp = fts_children(ftsp, 0);
  while (entp != NULL) {
    if (S_ISDIR(entp->fts_statp->st_mode)) {
      numSubDirs++;
    }
    entp = entp->fts_link;
  }

  return numSubDirs;
}

@end // @implementation TreeBuilder (PrivateMethods)
