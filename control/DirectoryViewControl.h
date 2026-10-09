#import <Cocoa/Cocoa.h>

// Deletion options
extern NSString  *DeleteNothing;
extern NSString  *OnlyDeleteFiles;
extern NSString  *DeleteFilesAndFolders;

// Notifications when opening and closing views
extern NSString  *ViewWillOpenEvent;
extern NSString  *ViewWillCloseEvent;

@class DirectoryView;
@class ItemPathModel;
@class ItemPathModelView;
@class DirectoryViewControlSettings;
@class DirectoryViewDisplaySettings;
@class TreeContext;
@class AnnotatedTreeContext;
@class FileTypesPanelControl;

@interface DirectoryViewControl : NSWindowController<NSMenuItemValidation> {

  // Main window
  IBOutlet NSTextField  *itemPathField;
  IBOutlet NSTextField  *itemSizeField;
  IBOutlet DirectoryView  *mainView;
  
  ItemPathModelView  *pathModelView;
  TreeContext  *treeContext;
  
  // The "initialSettings" field is only used between initialization and subsequent creation of the
  // window. It's subsequently dynamically created as needed.
  DirectoryViewControlSettings  *initialSettings;

  DirectoryViewDisplaySettings  *displaySettings;

  BOOL  canDeleteFiles;
  BOOL  canDeleteFolders;
  BOOL  confirmFileDeletion;
  BOOL  confirmFolderDeletion;

  // The (absolute) path of the scan tree.
  NSString  *scanPathName;
  
  // The part of the (absolute) path that is outside the visible tree.
  NSString  *invisiblePathName;

  // Status message that is temporarily shown in the status bar
  NSString  *statusMessage;

  NSURL  *customOpenApp;
  NSURL  *customRevealApp;

  // The size of the view when it is not zoomed.
  NSSize  unzoomedViewSize;

  // The "File Types" side panel, and the split view that hosts it next to the main view.
  NSSplitView  *splitView;
  FileTypesPanelControl  *fileTypesControl;
  CGFloat  fileTypesPanelWidth;

  // The color mapping that was active before showing the File Types panel switched the view to
  // coloring by file type. It is restored when the panel is hidden again. It is nil when the panel
  // did not change the color mapping (or when the user changed it since).
  NSString  *savedColorMappingKey;
}

- (IBAction) openFile:(id)sender;
- (IBAction) previewFile:(id)sender;
- (IBAction) revealFileInFinder:(id)sender;
- (IBAction) deleteFile:(id)sender;
- (IBAction) showInfo:(id)sender;

/* Shows or hides the File Types panel, which lists the file types in the view by size (similar to
 * the "kind statistics" of Disk Inventory X). Showing it also colors the view by file type.
 */
- (IBAction) toggleFileTypesPanel:(id)sender;

- (void) searchForFiles:(NSString *)searchSpec;

// Override designated initialisers
- (instancetype) initWithWindow:(NSWindow *)window NS_UNAVAILABLE;
- (instancetype) initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

- (instancetype) initWithAnnotatedTreeContext:(AnnotatedTreeContext *)treeContext;
- (instancetype) initWithAnnotatedTreeContext:(AnnotatedTreeContext *)treeContext
                                    pathModel:(ItemPathModel *)itemPathModel
                                     settings:(DirectoryViewControlSettings *)settings NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly, copy) NSString *comments;

@property (nonatomic, readonly, strong) NSString *nameOfActiveMask;

@property (nonatomic, readonly, strong) ItemPathModelView *pathModelView;

@property (nonatomic, readonly, strong) DirectoryView *directoryView;

/* Returns a newly created object that represents the current settings of the view. It can
 * subsequently be safely modified. This will not affect the view.
 */
@property (nonatomic, readonly, strong) DirectoryViewControlSettings *directoryViewControlSettings;

@property (nonatomic, readonly, strong) TreeContext *treeContext;
@property (nonatomic, readonly, strong) AnnotatedTreeContext *annotatedTreeContext;

/* Returns YES iff the action is currently enabled. 
 *
 * Only works for a subset of of actions, e.g. openFile: and deleteFile:. See implementation for
 * complete list, which can be extended when needed.
 */
- (BOOL) validateAction:(SEL)action;

/* Returns YES iff the selection is currently locked, which means that it does not change when the
 * mouse position changes.
 */
@property (nonatomic, getter=isSelectedFileLocked, readonly) BOOL selectedFileLocked;

@property (nonatomic, getter=isFileTypesPanelShown, readonly) BOOL fileTypesPanelShown;

@property (class, nonatomic, readonly) NSArray *fileDeletionTargetNames;

- (void) showInformativeAlert:(NSAlert *)alert;

@end
