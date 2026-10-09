#import "FileTypesPanelControl.h"

#import "DirectoryView.h"
#import "ItemPathModel.h"
#import "ItemPathModelView.h"
#import "TreeContext.h"

#import "FileItem.h"
#import "PlainFileItem.h"
#import "DirectoryItem.h"
#import "CompoundItem.h"

#import "FileItemMapping.h"
#import "FileItemMappingScheme.h"
#import "UniformTypeMappingScheme.h"
#import "UniformType.h"

#import "TreeDrawerSettings.h"
#import "TreeDrawerBaseSettings.h"
#import "GradientRectangleDrawer.h"

#import "ItemTypeTest.h"
#import "ItemNameTest.h"
#import "NotItemTest.h"
#import "CompoundAndItemTest.h"
#import "CompoundOrItemTest.h"
#import "SelectiveItemTest.h"
#import "StringSuffixTest.h"
#import "StringContainmentTest.h"


NSString  *FileTypeColorMappingKey = @"uniform type";
NSString  *FileTypesPanelColorByTypeRequestEvent = @"fileTypesPanelColorByTypeRequest";

static NSString  *SwatchColumnIdentifier = @"swatch";
static NSString  *NameColumnIdentifier = @"name";
static NSString  *SizeColumnIdentifier = @"size";
static NSString  *ShareColumnIdentifier = @"share";
static NSString  *CountColumnIdentifier = @"count";

static const CGFloat  SwatchSize = 12;


//----------------------------------------------------------------------------------------------
// FileTypeStatistic

/* Aggregated statistics for one file type. A file type is either a uniform type (UTI), or, for
 * files whose type macOS does not know, a file extension.
 */
@interface FileTypeStatistic : NSObject {
}

- (instancetype) init NS_UNAVAILABLE;

- (instancetype) initWithType:(nullable UTType *)type
                    extension:(nullable NSString *)extension
                   sampleItem:(PlainFileItem *)sample NS_DESIGNATED_INITIALIZER;

- (void) addFileOfSize:(item_size_t)size;

// Uniquely identifies the file type. Used to retain the selection across updates.
@property (nonatomic, readonly, copy) NSString *key;

// The UTI. It is nil when the type is identified by its extension.
@property (nonatomic, readonly, strong, nullable) UTType *type;

// The (lower-case) extension. Only set when the type is unknown. May be an empty string.
@property (nonatomic, readonly, copy, nullable) NSString *extension;

// A file of this type. Used to determine the color of the type.
@property (nonatomic, readonly, strong) PlainFileItem *sampleItem;

// Human-readable name of the type.
@property (nonatomic, readonly, copy) NSString *name;

// UTI or extension details, shown as tool tip.
@property (nonatomic, readonly, copy) NSString *details;

@property (nonatomic, readonly) item_size_t size;
@property (nonatomic, readonly) file_count_t count;

// The color index used for this type in the view. Set when the view is colored by file type.
@property (nonatomic) NSUInteger colorIndex;

@end


@implementation FileTypeStatistic

- (instancetype) initWithType:(UTType *)type
                    extension:(NSString *)extension
                   sampleItem:(PlainFileItem *)sample {
  if (self = [super init]) {
    _type = [type retain];
    _extension = [extension copy];
    _sampleItem = [sample retain];
    _colorIndex = NSNotFound;

    if (type != nil) {
      _key = [type.identifier copy];

      NSString  *descr = type.localizedDescription;
      _name = [(descr.length > 0 ? descr : type.identifier) copy];
      _details = [type.identifier copy];
    }
    else if (extension.length > 0) {
      _key = [[@"ext:" stringByAppendingString: extension] retain];

      NSString  *fmt = NSLocalizedString(@"%@ file", @"File type name based on its extension");
      _name = [[NSString stringWithFormat: fmt, extension.uppercaseString] retain];

      NSString  *detailsFmt =
        NSLocalizedString(@".%@ (type unknown to macOS)", @"Tool tip for unrecognized extension");
      _details = [[NSString stringWithFormat: detailsFmt, extension] retain];
    }
    else {
      _key = @"ext:";
      _name = [NSLocalizedString(@"Unknown (no extension)",
                                 @"File type name for files without extension") retain];
      _details = [NSLocalizedString(@"Files without an extension whose type is unknown",
                                    @"Tool tip for files without extension") retain];
    }
  }
  return self;
}

- (void) dealloc {
  [_key release];
  [_type release];
  [_extension release];
  [_sampleItem release];
  [_name release];
  [_details release];

  [super dealloc];
}

- (void) addFileOfSize:(item_size_t)size {
  _size += size;
  _count++;
}

@end // @implementation FileTypeStatistic


//----------------------------------------------------------------------------------------------
// Statistics collection. These functions run on a background thread, while a read lock is held
// on the tree.

static void tallyFile(PlainFileItem *file, NSMutableDictionary *stats) {
  if (!file.isPhysical) {
    // Skip free space and other non-file items that can be part of the volume tree.
    return;
  }

  UTType  *type = file.uniformType;
  NSString  *extension = nil;
  NSString  *key;

  if (type == nil || type.isUnknown) {
    type = nil;
    extension = file.systemPathComponent.pathExtension.lowercaseString;
    key = [@"ext:" stringByAppendingString: extension];
  } else {
    key = type.identifier;
  }

  FileTypeStatistic  *stat = stats[key];
  if (stat == nil) {
    stat = [[[FileTypeStatistic alloc] initWithType: type
                                          extension: extension
                                         sampleItem: file] autorelease];
    stats[key] = stat;
  }
  [stat addFileOfSize: file.itemSize];
}

static void tallyDirectory(DirectoryItem *dir, NSMutableDictionary *stats, BOOL packagesAsFiles) {
  [CompoundItem visitFileItemChildrenMaybeNil: dir.fileItems callback: ^(FileItem *file) {
    tallyFile((PlainFileItem *)file, stats);
  }];
  [CompoundItem visitFileItemChildrenMaybeNil: dir.directoryItems callback: ^(FileItem *item) {
    DirectoryItem  *subDir = (DirectoryItem *)item;

    if (packagesAsFiles && subDir.isPackage) {
      // Packages are shown as files in the view, so treat them as files here as well.
      tallyFile(subDir.directoryAsPlainFile, stats);
    } else {
      @autoreleasepool {
        tallyDirectory(subDir, stats, packagesAsFiles);
      }
    }
  }];
}

static NSDictionary *collectStatistics(FileItem *tree, BOOL packagesAsFiles) {
  NSMutableDictionary  *stats = [NSMutableDictionary dictionaryWithCapacity: 128];

  if (tree.isDirectory) {
    tallyDirectory((DirectoryItem *)tree, stats, packagesAsFiles);
  } else if (tree != nil) {
    tallyFile((PlainFileItem *)tree, stats);
  }

  return stats;
}


//----------------------------------------------------------------------------------------------
// FileTypesPanelControl

@interface FileTypesPanelControl () {
  DirectoryView  *dirView;
  TreeContext  *treeContext;

  NSTableView  *tableView;
  NSTextField  *summaryField;
  NSTextField  *hintField;
  NSButton  *colorByTypeButton;
  NSProgressIndicator  *spinner;

  // Array of FileTypeStatistic, ordered according to the table's sort descriptors
  NSArray  *statistics;
  item_size_t  totalSize;
  file_count_t  totalCount;

  // Keys of the selected types. Used to retain the selection when the statistics are refreshed.
  NSMutableSet  *selectedKeys;

  // Color swatch per color index
  NSMutableDictionary  *swatchImages;
  BOOL  showSwatches;

  // Incremented for each refresh, to discard results of outdated background calculations.
  NSUInteger  refreshGeneration;

  // Set while the selection is changed programmatically
  BOOL  ignoreSelectionChanges;

  // Set when the highlight (overlay test) of the view is set by this panel
  BOOL  ownsHighlight;

  BOOL  invalidated;
}

- (void) createView;
- (NSTableColumn *)addColumn:(NSString *)identifier
                       title:(NSString *)title
                       width:(CGFloat)width
                     sortKey:(nullable NSString *)sortKey
                   ascending:(BOOL)ascending;

- (void) statisticsReady:(NSDictionary *)stats forGeneration:(NSUInteger)generation;
- (void) sortStatistics;
- (void) restoreSelection;
- (void) updateSummary;
- (void) updateHighlight;
- (nullable FileItemTest *)highlightTestForStatistics:(NSArray *)selection;

- (NSImage *)swatchForColorIndex:(NSUInteger)colorIndex
                          drawer:(GradientRectangleDrawer *)drawer;

- (void) colorByType:(id)sender;

- (void) visibleTreeChanged:(NSNotification *)notification;
- (void) fileItemDeleted:(NSNotification *)notification;
- (void) colorMappingChanged:(NSNotification *)notification;

@end


@implementation FileTypesPanelControl

- (instancetype) initWithDirectoryView:(DirectoryView *)dirViewVal
                           treeContext:(TreeContext *)treeContextVal {
  if (self = [super init]) {
    dirView = [dirViewVal retain];
    treeContext = [treeContextVal retain];

    statistics = [[NSArray alloc] init];
    selectedKeys = [[NSMutableSet alloc] initWithCapacity: 8];
    swatchImages = [[NSMutableDictionary alloc] initWithCapacity: 32];

    [self createView];

    NSNotificationCenter  *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver: self
           selector: @selector(visibleTreeChanged:)
               name: VisibleTreeChangedEvent
             object: dirView.pathModelView];
    [nc addObserver: self
           selector: @selector(fileItemDeleted:)
               name: FileItemDeletedEvent
             object: treeContext];
    [nc addObserver: self
           selector: @selector(colorMappingChanged:)
               name: ColorMappingChangedEvent
             object: dirView];
    [nc addObserver: self
           selector: @selector(colorMappingChanged:)
               name: ColorPaletteChangedEvent
             object: dirView];
  }
  return self;
}

- (void) dealloc {
  [NSNotificationCenter.defaultCenter removeObserver: self];

  tableView.dataSource = nil;
  tableView.delegate = nil;

  [dirView release];
  [treeContext release];

  [_view release];
  [tableView release];
  [summaryField release];
  [hintField release];
  [colorByTypeButton release];
  [spinner release];

  [statistics release];
  [selectedKeys release];
  [swatchImages release];

  [super dealloc];
}

- (void) invalidate {
  invalidated = YES;
  refreshGeneration++;

  [NSNotificationCenter.defaultCenter removeObserver: self];
}

- (void) setActive:(BOOL)active {
  if (active == _active) {
    return;
  }
  _active = active;

  if (active) {
    [self refreshColors];
    [self refreshStatistics];
  } else {
    // Abandon any calculation in progress
    refreshGeneration++;
    [spinner stopAnimation: self];
  }
}

- (void) refreshStatistics {
  if (!self.active || invalidated) {
    // Statistics are recalculated when the panel becomes active
    return;
  }

  NSUInteger  generation = ++refreshGeneration;

  FileItem  *tree = dirView.treeInView;
  BOOL  packagesAsFiles = dirView.treeDrawerSettings.drawItems != DRAW_FILES;
  TreeContext  *context = treeContext;

  if (tree == nil) {
    [self statisticsReady: @{} forGeneration: generation];
    return;
  }

  [spinner startAnimation: self];

  // Note: The block retains the objects it references (tree, context and self), keeping them alive
  // until the calculation completes.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSDictionary  *stats;

    @autoreleasepool {
      [context obtainReadLock];
      stats = [collectStatistics(tree, packagesAsFiles) retain];
      [context releaseReadLock];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [self statisticsReady: stats forGeneration: generation];
      [stats release];
    });
  });
}

- (void) refreshColors {
  TreeDrawerSettings  *settings = dirView.treeDrawerSettings;
  NSObject <FileItemMappingScheme>  *colorScheme = settings.colorScheme;

  showSwatches = [colorScheme isKindOfClass: UniformTypeMappingScheme.class];

  colorByTypeButton.hidden = showSwatches;
  [tableView tableColumnWithIdentifier: SwatchColumnIdentifier].hidden = !showSwatches;

  [swatchImages removeAllObjects];

  if (showSwatches) {
    // Use a private mapping instance, as mapping instances are not thread-safe and the one used
    // by the view is used by its drawing thread.
    FileItemMapping  *mapper =
      [colorScheme fileItemMappingForTree: dirView.pathModelView.scanTree];

    GradientRectangleDrawer  *drawer =
      [[[GradientRectangleDrawer alloc] initWithColorPalette: settings.colorPalette] autorelease];
    drawer.colorGradient = settings.colorGradient;
    NSUInteger  numColors = drawer.numGradientColors;

    for (FileTypeStatistic *stat in statistics) {
      NSUInteger  hash = [mapper hashForFileItem: stat.sampleItem atDepth: 0];
      stat.colorIndex = (numColors > 0) ? [mapper colorIndexForHash: hash numColors: numColors]
                                        : NSNotFound;
      // Create the image now, while the drawer is at hand.
      [self swatchForColorIndex: stat.colorIndex drawer: drawer];
    }
  }

  [tableView reloadData];
  [self restoreSelection];
}

- (void) clearSelection {
  [selectedKeys removeAllObjects];

  ignoreSelectionChanges = YES;
  [tableView deselectAll: self];
  ignoreSelectionChanges = NO;

  [self updateHighlight];
}

- (void) relinquishHighlight {
  ownsHighlight = NO;
  [self clearSelection];
}


//----------------------------------------------------------------------------------------------
// NSTableViewDataSource

- (NSInteger) numberOfRowsInTableView:(NSTableView *)tv {
  return statistics.count;
}

- (void) tableView:(NSTableView *)tv sortDescriptorsDidChange:(NSArray *)oldDescriptors {
  [self sortStatistics];
  [tableView reloadData];
  [self restoreSelection];
}


//----------------------------------------------------------------------------------------------
// NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tv
   viewForTableColumn:(NSTableColumn *)column
                  row:(NSInteger)row {
  FileTypeStatistic  *stat = statistics[row];
  NSString  *identifier = column.identifier;

  if ([identifier isEqualToString: SwatchColumnIdentifier]) {
    NSImageView  *imageView = [tv makeViewWithIdentifier: identifier owner: self];
    if (imageView == nil) {
      imageView = [[[NSImageView alloc] initWithFrame: NSMakeRect(0, 0, SwatchSize, SwatchSize)]
                   autorelease];
      imageView.identifier = identifier;
      imageView.imageScaling = NSImageScaleNone;
    }
    imageView.image = showSwatches ? swatchImages[@(stat.colorIndex)] : nil;
    return imageView;
  }

  NSTextField  *field = [tv makeViewWithIdentifier: identifier owner: self];
  if (field == nil) {
    field = [NSTextField labelWithString: @""];
    field.identifier = identifier;
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    field.font = [NSFont monospacedDigitSystemFontOfSize: NSFont.smallSystemFontSize
                                                  weight: NSFontWeightRegular];
    if (![identifier isEqualToString: NameColumnIdentifier]) {
      field.alignment = NSTextAlignmentRight;
    }
  }

  if ([identifier isEqualToString: NameColumnIdentifier]) {
    field.stringValue = stat.name;
    field.toolTip = stat.details;
  }
  else if ([identifier isEqualToString: SizeColumnIdentifier]) {
    field.stringValue = [FileItem stringForFileItemSize: stat.size];
    field.toolTip = nil;
  }
  else if ([identifier isEqualToString: ShareColumnIdentifier]) {
    double  share = (totalSize > 0) ? 100.0 * stat.size / totalSize : 0;
    field.stringValue = (share >= 0.1 || share == 0)
      ? [NSString stringWithFormat: @"%.1f%%", share]
      : @"<0.1%";
    field.toolTip = nil;
  }
  else if ([identifier isEqualToString: CountColumnIdentifier]) {
    field.stringValue = [NSNumberFormatter localizedStringFromNumber: @(stat.count)
                                                         numberStyle: NSNumberFormatterDecimalStyle];
    field.toolTip = nil;
  }

  return field;
}

- (void) tableViewSelectionDidChange:(NSNotification *)notification {
  if (ignoreSelectionChanges) {
    return;
  }

  [selectedKeys removeAllObjects];
  [tableView.selectedRowIndexes enumerateIndexesUsingBlock: ^(NSUInteger row, BOOL *stop) {
    [selectedKeys addObject: ((FileTypeStatistic *)statistics[row]).key];
  }];

  [self updateHighlight];
}

//----------------------------------------------------------------------------------------------
// Private methods

- (void) createView {
  NSView  *root = [[NSView alloc] initWithFrame: NSMakeRect(0, 0, 320, 400)];
  _view = root;

  // Header
  NSTextField  *titleField =
    [NSTextField labelWithString: NSLocalizedString(@"File Types", @"Title of file types panel")];
  titleField.font = [NSFont boldSystemFontOfSize: NSFont.systemFontSize];
  titleField.translatesAutoresizingMaskIntoConstraints = NO;

  summaryField = [[NSTextField labelWithString: @""] retain];
  summaryField.font = [NSFont systemFontOfSize: NSFont.smallSystemFontSize];
  summaryField.textColor = NSColor.secondaryLabelColor;
  summaryField.lineBreakMode = NSLineBreakByTruncatingTail;
  summaryField.translatesAutoresizingMaskIntoConstraints = NO;
  [summaryField setContentCompressionResistancePriority: NSLayoutPriorityDefaultLow
                                         forOrientation: NSLayoutConstraintOrientationHorizontal];

  spinner = [[NSProgressIndicator alloc] init];
  spinner.style = NSProgressIndicatorStyleSpinning;
  spinner.controlSize = NSControlSizeSmall;
  spinner.displayedWhenStopped = NO;
  spinner.translatesAutoresizingMaskIntoConstraints = NO;

  // Table
  tableView = [[NSTableView alloc] initWithFrame: NSMakeRect(0, 0, 320, 300)];
  tableView.style = NSTableViewStyleFullWidth;
  tableView.usesAlternatingRowBackgroundColors = YES;
  tableView.allowsMultipleSelection = YES;
  tableView.allowsEmptySelection = YES;
  tableView.allowsColumnReordering = NO;
  tableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  tableView.rowSizeStyle = NSTableViewRowSizeStyleSmall;
  tableView.intercellSpacing = NSMakeSize(6, 2);

  NSTableColumn  *col;
  col = [self addColumn: SwatchColumnIdentifier title: @"" width: SwatchSize + 2
                sortKey: nil ascending: NO];
  col.minWidth = col.maxWidth = col.width;
  col.resizingMask = NSTableColumnNoResizing;

  col = [self addColumn: NameColumnIdentifier
                  title: NSLocalizedString(@"Kind", @"Column header in file types panel")
                  width: 130
                sortKey: @"name"
              ascending: YES];
  col.minWidth = 60;
  col.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;

  [self addColumn: SizeColumnIdentifier
            title: NSLocalizedString(@"Size", @"Column header in file types panel")
            width: 64
          sortKey: @"size"
        ascending: NO];
  [self addColumn: ShareColumnIdentifier
            title: @"%"
            width: 44
          sortKey: @"size"
        ascending: NO];
  [self addColumn: CountColumnIdentifier
            title: NSLocalizedString(@"Files", @"Column header in file types panel")
            width: 52
          sortKey: @"count"
        ascending: NO];

  tableView.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey: @"size" ascending: NO]];
  tableView.dataSource = self;
  tableView.delegate = self;

  NSScrollView  *scrollView = [[[NSScrollView alloc] initWithFrame: tableView.frame] autorelease];
  scrollView.documentView = tableView;
  scrollView.hasVerticalScroller = YES;
  scrollView.hasHorizontalScroller = NO;
  scrollView.autohidesScrollers = YES;
  scrollView.borderType = NSNoBorder;
  scrollView.translatesAutoresizingMaskIntoConstraints = NO;

  // Footer
  hintField = [[NSTextField wrappingLabelWithString:
    NSLocalizedString(@"Select a type to highlight its files. Hold ⌘ to select several.",
                      @"Hint in file types panel")] retain];
  hintField.font = [NSFont systemFontOfSize: NSFont.smallSystemFontSize];
  hintField.textColor = NSColor.secondaryLabelColor;
  hintField.translatesAutoresizingMaskIntoConstraints = NO;
  [hintField setContentCompressionResistancePriority: NSLayoutPriorityDefaultLow
                                      forOrientation: NSLayoutConstraintOrientationHorizontal];

  colorByTypeButton = [[NSButton buttonWithTitle:
    NSLocalizedString(@"Color View by File Type", @"Button in file types panel")
                                          target: self
                                          action: @selector(colorByType:)] retain];
  colorByTypeButton.controlSize = NSControlSizeSmall;
  colorByTypeButton.font = [NSFont systemFontOfSize: NSFont.smallSystemFontSize];

  NSStackView  *footer = [NSStackView stackViewWithViews: @[hintField, colorByTypeButton]];
  footer.orientation = NSUserInterfaceLayoutOrientationVertical;
  footer.alignment = NSLayoutAttributeLeading;
  footer.spacing = 6;
  footer.edgeInsets = NSEdgeInsetsMake(8, 12, 10, 12);
  footer.translatesAutoresizingMaskIntoConstraints = NO;

  [root addSubview: titleField];
  [root addSubview: spinner];
  [root addSubview: summaryField];
  [root addSubview: scrollView];
  [root addSubview: footer];

  [NSLayoutConstraint activateConstraints: @[
    [titleField.topAnchor constraintEqualToAnchor: root.topAnchor constant: 10],
    [titleField.leadingAnchor constraintEqualToAnchor: root.leadingAnchor constant: 12],

    [spinner.centerYAnchor constraintEqualToAnchor: titleField.centerYAnchor],
    [spinner.leadingAnchor constraintGreaterThanOrEqualToAnchor: titleField.trailingAnchor
                                                       constant: 8],
    [spinner.trailingAnchor constraintEqualToAnchor: root.trailingAnchor constant: -12],

    [summaryField.topAnchor constraintEqualToAnchor: titleField.bottomAnchor constant: 2],
    [summaryField.leadingAnchor constraintEqualToAnchor: root.leadingAnchor constant: 12],
    [summaryField.trailingAnchor constraintLessThanOrEqualToAnchor: root.trailingAnchor
                                                          constant: -12],

    [scrollView.topAnchor constraintEqualToAnchor: summaryField.bottomAnchor constant: 8],
    [scrollView.leadingAnchor constraintEqualToAnchor: root.leadingAnchor],
    [scrollView.trailingAnchor constraintEqualToAnchor: root.trailingAnchor],

    [footer.topAnchor constraintEqualToAnchor: scrollView.bottomAnchor],
    [footer.leadingAnchor constraintEqualToAnchor: root.leadingAnchor],
    [footer.trailingAnchor constraintEqualToAnchor: root.trailingAnchor],
    [footer.bottomAnchor constraintEqualToAnchor: root.bottomAnchor],
    [hintField.widthAnchor constraintEqualToAnchor: footer.widthAnchor constant: -24],

    [root.widthAnchor constraintGreaterThanOrEqualToConstant: 220],
  ]];

  [self updateSummary];
}

- (NSTableColumn *)addColumn:(NSString *)identifier
                       title:(NSString *)title
                       width:(CGFloat)width
                     sortKey:(NSString *)sortKey
                   ascending:(BOOL)ascending {
  NSTableColumn  *col = [[[NSTableColumn alloc] initWithIdentifier: identifier] autorelease];
  col.title = title;
  col.width = width;
  col.minWidth = MIN(width, 36);
  col.editable = NO;
  col.resizingMask = NSTableColumnUserResizingMask;

  if (![identifier isEqualToString: NameColumnIdentifier]) {
    col.headerCell.alignment = NSTextAlignmentRight;
  }

  if (sortKey != nil) {
    SEL  compareSelector = [sortKey isEqualToString: @"name"]
      ? @selector(localizedStandardCompare:) : @selector(compare:);
    col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey: sortKey
                                                                ascending: ascending
                                                                 selector: compareSelector];
  }

  [tableView addTableColumn: col];
  return col;
}


- (void) statisticsReady:(NSDictionary *)stats forGeneration:(NSUInteger)generation {
  if (generation != refreshGeneration || invalidated) {
    // Outdated result
    return;
  }

  [spinner stopAnimation: self];

  [statistics release];
  statistics = [stats.allValues retain];

  totalSize = 0;
  totalCount = 0;
  for (FileTypeStatistic *stat in statistics) {
    totalSize += stat.size;
    totalCount += stat.count;
  }

  [self sortStatistics];
  [self updateSummary];

  // Also reloads the table and restores the selection
  [self refreshColors];

  // Types may have disappeared (e.g. after zooming in), so update the highlight
  if (ownsHighlight || selectedKeys.count > 0) {
    [self updateHighlight];
  }
}

- (void) sortStatistics {
  NSMutableArray  *descriptors = [NSMutableArray arrayWithArray: tableView.sortDescriptors];

  // Tie-breakers, for a stable order
  [descriptors addObject: [NSSortDescriptor sortDescriptorWithKey: @"size" ascending: NO]];
  [descriptors addObject: [NSSortDescriptor sortDescriptorWithKey: @"name"
                                                        ascending: YES
                                                         selector: @selector(compare:)]];

  NSArray  *sorted = [statistics sortedArrayUsingDescriptors: descriptors];
  [statistics release];
  statistics = [sorted retain];
}

- (void) restoreSelection {
  NSMutableIndexSet  *rows = [NSMutableIndexSet indexSet];
  [statistics enumerateObjectsUsingBlock: ^(FileTypeStatistic *stat, NSUInteger idx, BOOL *stop) {
    if ([selectedKeys containsObject: stat.key]) {
      [rows addIndex: idx];
    }
  }];

  ignoreSelectionChanges = YES;
  [tableView selectRowIndexes: rows byExtendingSelection: NO];
  ignoreSelectionChanges = NO;
}

- (void) updateSummary {
  if (statistics.count == 0) {
    summaryField.stringValue = @"";
    return;
  }

  NSString  *fmt = NSLocalizedString(@"%@ types · %@ files · %@",
                                     @"Summary in file types panel: types, files, total size");
  NSString  *numTypes = [NSNumberFormatter localizedStringFromNumber: @(statistics.count)
                                                         numberStyle: NSNumberFormatterDecimalStyle];
  NSString  *numFiles = [NSNumberFormatter localizedStringFromNumber: @(totalCount)
                                                         numberStyle: NSNumberFormatterDecimalStyle];

  summaryField.stringValue = [NSString stringWithFormat: fmt,
                              numTypes, numFiles, [FileItem stringForFileItemSize: totalSize]];
}

- (void) updateHighlight {
  NSMutableArray  *selection = [NSMutableArray arrayWithCapacity: selectedKeys.count];
  for (FileTypeStatistic *stat in statistics) {
    if ([selectedKeys containsObject: stat.key]) {
      [selection addObject: stat];
    }
  }

  if (selection.count == 0) {
    if (ownsHighlight) {
      dirView.overlayTest = nil;
      ownsHighlight = NO;
    }
    return;
  }

  dirView.overlayTest = [self highlightTestForStatistics: selection];
  ownsHighlight = YES;
}

- (FileItemTest *)highlightTestForStatistics:(NSArray *)selection {
  NSMutableArray  *types = [NSMutableArray arrayWithCapacity: selection.count];
  NSMutableArray  *suffixes = [NSMutableArray arrayWithCapacity: selection.count];
  BOOL  includeNoExtension = NO;

  for (FileTypeStatistic *stat in selection) {
    if (stat.type != nil) {
      [types addObject: stat.type];
    } else if (stat.extension.length > 0) {
      [suffixes addObject: [@"." stringByAppendingString: stat.extension]];
    } else {
      includeNoExtension = YES;
    }
  }

  NSMutableArray  *subTests = [NSMutableArray arrayWithCapacity: 3];

  if (types.count > 0) {
    [subTests addObject: [[[ItemTypeTest alloc] initWithMatchTargets: types strict: YES]
                          autorelease]];
  }

  if (suffixes.count > 0 || includeNoExtension) {
    // Only files of unknown type are listed by extension
    FileItemTest  *unknownTypeTest =
      [[[ItemTypeTest alloc] initWithMatchTargets: @[UTType.unknownType] strict: YES] autorelease];

    if (suffixes.count > 0) {
      StringSuffixTest  *suffixTest =
        [[[StringSuffixTest alloc] initWithMatchTargets: suffixes caseSensitive: NO] autorelease];
      FileItemTest  *nameTest =
        [[[ItemNameTest alloc] initWithStringTest: suffixTest] autorelease];

      [subTests addObject: [[[CompoundAndItemTest alloc]
                             initWithSubItemTests: @[unknownTypeTest, nameTest]] autorelease]];
    }

    if (includeNoExtension) {
      StringContainmentTest  *dotTest =
        [[[StringContainmentTest alloc] initWithMatchTargets: @[@"."] caseSensitive: NO]
         autorelease];
      FileItemTest  *noDotTest =
        [[[NotItemTest alloc] initWithSubItemTest:
          [[[ItemNameTest alloc] initWithStringTest: dotTest] autorelease]] autorelease];

      [subTests addObject: [[[CompoundAndItemTest alloc]
                             initWithSubItemTests: @[unknownTypeTest, noDotTest]] autorelease]];
    }
  }

  if (subTests.count == 0) {
    return nil;
  }

  FileItemTest  *test = (subTests.count == 1)
    ? subTests[0]
    : [[[CompoundOrItemTest alloc] initWithSubItemTests: subTests] autorelease];

  return [[[SelectiveItemTest alloc] initWithSubItemTest: test onlyFiles: YES] autorelease];
}

- (NSImage *)swatchForColorIndex:(NSUInteger)colorIndex
                          drawer:(GradientRectangleDrawer *)drawer {
  if (colorIndex == NSNotFound) {
    return nil;
  }

  NSImage  *image = swatchImages[@(colorIndex)];
  if (image == nil) {
    image = [drawer drawImageOfGradientRectangleWithColor: colorIndex
                                                   inRect: NSMakeRect(0, 0, SwatchSize, SwatchSize)];
    if (image != nil) {
      swatchImages[@(colorIndex)] = image;
    }
  }
  return image;
}

- (void) colorByType:(id)sender {
  [NSNotificationCenter.defaultCenter postNotificationName: FileTypesPanelColorByTypeRequestEvent
                                                    object: self];
}


- (void) visibleTreeChanged:(NSNotification *)notification {
  [self refreshStatistics];
}

- (void) fileItemDeleted:(NSNotification *)notification {
  [self refreshStatistics];
}

- (void) colorMappingChanged:(NSNotification *)notification {
  if (self.active) {
    [self refreshColors];
  }
}

@end // @implementation FileTypesPanelControl
