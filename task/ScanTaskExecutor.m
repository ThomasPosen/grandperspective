#import "ScanTaskExecutor.h"

#import "TreeBuilder.h"
#import "TreeRefresher.h"
#import "ScanTaskInput.h"
#import "ScanTaskOutput.h"
#import "ProgressTracker.h"
#import "LogManager.h"
#import "UniformTypeInventory.h"


@implementation ScanTaskExecutor

- (instancetype) init {
  if (self = [super init]) {
    taskLock = [[NSLock alloc] init];
    treeBuilder = nil;
  }
  return self;
}

- (void) dealloc {
  [taskLock release];
  
  NSAssert(treeBuilder == nil, @"treeBuilder should be nil.");
  
  [super dealloc];
}


- (void) prepareToRunTask {
  // Can be ignored because a one-shot object is used for running the task.
}

- (id) runTaskWithInput:(id)input {
  NSAssert(treeBuilder == nil, @"treeBuilder already set.");

  ScanTaskInput  *myInput = input;

  [taskLock lock];
  if (myInput.treeSource != nil) {
    // The scan is only partial
    treeBuilder = [[TreeRefresher alloc] initWithFilterSet: myInput.filterSet
                                                   oldTree: myInput.treeSource];
  } else {
    treeBuilder = [[TreeBuilder alloc] initWithFilterSet: myInput.filterSet];
  }
  [treeBuilder setFileSizeMeasure: myInput.fileSizeMeasure];
  [taskLock unlock];
  
  NSDate  *startTime = [NSDate date];
  UniformTypeInventory*  typeInventory = UniformTypeInventory.defaultUniformTypeInventory;
  NSUInteger  numBefore = typeInventory.numUnrecognizedExtensions;

  TreeContext*  scanTree = [treeBuilder buildTreeForPath: myInput.path];
  ScanTaskOutput  *scanResult = nil;

  os_log_t  logger = LogManager.defaultLogManager.mainLog;
  if (scanTree != nil) {
    os_log(logger, "Done scanning: %d folders scanned (%d skipped) in %.2fs.",
            [self.progressInfo[NumFoldersProcessedKey] intValue],
            [self.progressInfo[NumFoldersSkippedKey] intValue],
            -startTime.timeIntervalSinceNow);
    scanResult = [ScanTaskOutput scanTaskOutput: scanTree alert: treeBuilder.alertMessage];
  }
  else {
    if (treeBuilder.alertMessage != nil) {
      os_log(logger, "Scanning failed.");
      scanResult = [ScanTaskOutput failedScanTaskOutput: treeBuilder.alertMessage];
    } else {
      os_log(logger, "Scanning aborted.");
    }
  }

  NSUInteger  numAfter = typeInventory.numUnrecognizedExtensions;
  if (numAfter > numBefore) {
    os_log_info(logger,
                "Encountered %lu new unrecognized file extensions (enable full logging for details)",
                numAfter - numBefore);
  }

  [taskLock lock];
  [treeBuilder release];
  treeBuilder = nil;
  [taskLock unlock];

  return scanResult;
}

- (void) abortTask {
  [treeBuilder abort];
}


- (NSDictionary *)progressInfo {
  NSDictionary  *dict;

  [taskLock lock];
  // The "taskLock" ensures that when treeBuilder is not nil, the object will
  // always be valid when it is used (i.e. it won't be deallocated).
  dict = treeBuilder.progressInfo;
  [taskLock unlock];
  
  return dict;
}

@end
