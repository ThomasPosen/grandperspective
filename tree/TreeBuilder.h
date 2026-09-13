#import <Cocoa/Cocoa.h>

#include <fts.h>
@import os.log;

#import "FileItem.h"

extern NSString  *LogicalFileSizeName;
extern NSString  *PhysicalFileSizeName;
extern NSString  *TallyFileSizeName;

typedef NS_ENUM(NSInteger, FileSizeEnum) {
  LogicalFileSize = 1,
  PhysicalFileSize = 2,
  TallyFileSize = 3
};

@class AlertMessage;
@class FilteredTreeGuide;
@class TreeBalancer;
@class UniformTypeInventory;
@class PlainFileItem;
@class DirectoryItem;
@class ScanTreeRoot;
@class FilterSet;
@class TreeContext;
@class ScanProgressTracker;
@class ScanStackFrame;


/* Constructs trees for folders by (recursively) scanning the folder's contents.
 */
@interface TreeBuilder : NSObject {
  FilterSet  *filterSet;

  NSString  *fileSizeMeasureName;
  FileSizeEnum  fileSizeMeasure;

  FTS  *ftsp;

  // In case logical file sizes are used, tracks total physical size.
  item_size_t  totalPhysicalSize;
  // In case logical file sizes are used, tracks how many files are actually smaller than reported.
  NSUInteger  numOverestimatedFiles;
  NSUInteger  numDirectoryReadErrors;
  NSUInteger  numSkippedDataless;

  BOOL  abort;
  FilteredTreeGuide  *treeGuide;
  TreeBalancer  *treeBalancer;
  UniformTypeInventory  *typeInventory;
  dispatch_queue_t  treeBalanceDispatchQueue;
  
  // Contains the file numbers of the hard linked files that have been encountered so far. If a file
  // with a same number is encountered once more, it is ignored.
  NSMutableSet  *hardLinkedFileNumbers;
  
  ScanProgressTracker  *progressTracker;
  
  NSMutableArray<ScanStackFrame *>  *dirStack;
  // The index of the top element on the stack. It is not necessarly the last object in the array,
  // as items on the stack are never popped but kept for re-use.
  int  dirStackTopIndex;
  
  BOOL  ignoreHardLinksForDirectories;
  BOOL  fastPackageCheckEnabled;

  os_log_t  logger;
  os_log_t  trustedLogger;
}

+ (NSArray *)fileSizeMeasureNames;

- (instancetype) init;
- (instancetype) initWithFilterSet:(FilterSet *)filterSet NS_DESIGNATED_INITIALIZER;

@property (nonatomic, copy) NSString *fileSizeMeasure;

/* Construct a full tree for the given folder.
 */
- (TreeContext *)buildTreeForPath:(NSString *)path;

- (void) abort;

/* Returns a dictionary containing information about the progress of the ongoing tree-building task.
 *
 * It can safely be invoked from a different thread than the one that invoked -buildTreeForPath:
 * (and not doing so would actually be quite silly).
 */
@property (nonatomic, readonly, copy) NSDictionary *progressInfo;

/* An alert in case a warning should be shown to the user regarding the scan results.
 *
 * Note: This class does not directly create an instance of an NSAlert. That should always be done
 * on the main thread to avoid exceptions.
 */
@property (nonatomic, readonly, strong) AlertMessage *alertMessage;

@end

// The protected methods are only intended for use by the class itself or by TreeRefresher.
@interface TreeBuilder (ProtectedMethods)

/* Constructs a tree for the given folder. It is used to implement buildTreeForPath:. The default
 * implementation redirects to scanTreeForDirectory:atPath:.
 */
- (BOOL) buildTreeForDirectory:(DirectoryItem *)dirItem atPath:(NSString *)path;

/* Constructs a tree for the given folder. This is done by scanning the full contents of the folder
 * (except when parts can be skipped given the configured filter).
 */
- (BOOL) scanTreeForDirectory:(DirectoryItem *)dirItem atPath:(NSString *)path;

/* Performs a shallow scan of the folder at the given path to determine its contents.
 *
 * The contents are collected in a temporary directory, but not yet finalized (i.e. balanced).
 * Before that can be done, the sub-directories need to be populated (and finalized). It returns
 * the contents via this temporary directory item.
 */
- (DirectoryItem *)getContentsForDirectory:(DirectoryItem *)dirItem
                                    atPath:(NSString *)path;

- (AlertMessage *)createAlertMessage:(DirectoryItem *)scanTree;

@end
