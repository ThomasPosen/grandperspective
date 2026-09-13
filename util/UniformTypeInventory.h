#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString  *UniformTypeAddedEvent;
extern NSString  *UniformTypeKey;


@class FileItem;
@class UTType;

/* Maintains a collection of uniform types, dynamically extended with additional types when files of
 * a new type are encountered. It maintains various look-up tables to speed-up the mapping from a
 * file to the associated uniform type.
 *
 * Note: The implementation of this class is not thread-safe. However, it has been implemented so
 * that it can be used in a background thread (in particular, it ensures that notifications are
 * always posted from the main thread).
 */
@interface UniformTypeInventory : NSObject {

  // Maps NSStrings to UniformTypes
  NSMutableDictionary  *typeForExtension;

  // Maps NSStrings to UniformTypes
  NSMutableDictionary  *typeForUTI;

  NSUInteger  numUnrecognizedExtensions;
}

@property (class, nonatomic, readonly) UniformTypeInventory *defaultUniformTypeInventory;

@property (nonatomic, readonly) NSUInteger count;
@property (nonatomic, readonly) NSUInteger numUnrecognizedExtensions;

/* Returns the type associated with the given file extension. If there is no properly defined type,
 * it returns the type the generic "unknown" type (see -unknownUniformType).
 */
- (UTType *)uniformTypeForExtension:(NSString *)ext;

/* Returns the type that corresponds to the given UTI. If the UTI is not recognized, it returns nil.
 */
- (UTType *)uniformTypeForIdentifier:(NSString *)uti;

/* Enumerates over all types maintained by this inventory. These types include those that have been
 * registered directly, as well as those that have been registered indirectly (as a result of being
 * ancestors of a registered type).
 */
- (NSEnumerator *)uniformTypeEnumerator;

@end

NS_ASSUME_NONNULL_END
