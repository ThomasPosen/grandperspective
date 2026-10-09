#import <Cocoa/Cocoa.h>

@class DirectoryView;
@class TreeContext;

NS_ASSUME_NONNULL_BEGIN

/* The key of the color mapping scheme that colors file items by their (uniform) file type.
 */
extern NSString  *FileTypeColorMappingKey;

/* Sent by the panel when the user asks for the view to be colored by file type.
 */
extern NSString  *FileTypesPanelColorByTypeRequestEvent;


/* Controls the "File Types" side panel of a directory view window. Inspired by the "kind
 * statistics" window of Disk Inventory X, it lists every file type in the part of the tree that is
 * shown in the view, together with its total size, its share of the total and the number of files.
 * When the view is colored by file type, each row shows the color used for that type in the view.
 *
 * Selecting one or more rows highlights all files of the selected type(s) in the view.
 *
 * Files whose type is unknown to macOS are listed per file extension (e.g. "ASD file"), as these
 * otherwise all end up in a single "unknown" bucket that tells you very little.
 */
@interface FileTypesPanelControl : NSObject <NSTableViewDataSource, NSTableViewDelegate>

- (instancetype) init NS_UNAVAILABLE;

- (instancetype) initWithDirectoryView:(DirectoryView *)dirView
                           treeContext:(TreeContext *)treeContext NS_DESIGNATED_INITIALIZER;

/* The view containing the panel. It is created by the control.
 */
@property (nonatomic, readonly, strong) NSView *view;

/* When NO, the panel does not (re)calculate its statistics. This avoids needless work while the
 * panel is hidden. Setting it to YES triggers a refresh.
 */
@property (nonatomic) BOOL active;

/* Recalculates the statistics (in the background). It is invoked automatically when the visible
 * tree changes, or files are deleted. It should be invoked when display settings change that
 * affect which items are shown (e.g. whether package contents are shown).
 */
- (void) refreshStatistics;

/* Updates the color swatches. It is invoked automatically when the color mapping or palette
 * changes.
 */
- (void) refreshColors;

/* Clears the selection. When the panel was responsible for the highlight in the view, it is
 * removed as well.
 */
- (void) clearSelection;

/* Clears the selection without touching the highlight in the view. Should be used when the
 * highlight in the view is about to be replaced by something else (e.g. a search).
 */
- (void) relinquishHighlight;

/* Must be invoked when the window closes. It stops observing events and abandons pending work.
 */
- (void) invalidate;

@end

NS_ASSUME_NONNULL_END
