#import "UniformTypeInventory.h"

#import "FileItem.h"
#import "UniformType.h"
#import "LogManager.h"


NSString  *UniformTypeAddedEvent = @"uniformTypeAdded";

NSString  *UniformTypeKey = @"uniformType";

@interface UniformTypeInventory (PrivateMethods) 

- (void) postNotification:(NSNotification *)notification;

- (UTType *)createUniformTypeForIdentifier:(NSString *)uti;

@end


@implementation UniformTypeInventory

+ (UniformTypeInventory *)defaultUniformTypeInventory {
  static UniformTypeInventory  *defaultUniformTypeInventoryInstance = nil;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    defaultUniformTypeInventoryInstance = [[UniformTypeInventory alloc] init];
  });
  
  return defaultUniformTypeInventoryInstance;
}


// Overrides super's designated initialiser.
- (instancetype) init {
  if (self = [super init]) {
    typeForExtension = [[NSMutableDictionary alloc] initWithCapacity: 32];
    typeForUTI = [[NSMutableDictionary alloc] initWithCapacity: 32];
    numUnrecognizedExtensions = 0;

    UTType*  unknownType = UTType.unknownType;
    typeForUTI[unknownType.uniformTypeIdentifier] = unknownType;
  }
  
  return self;
}

- (void) dealloc {

  [typeForExtension release];
  [typeForUTI release];
    
  [super dealloc];
}


- (NSUInteger) count {
  return typeForUTI.count;
}

- (NSUInteger) numUnrecognizedExtensions {
  return numUnrecognizedExtensions;
}


- (NSEnumerator *)uniformTypeEnumerator {
  return [typeForUTI objectEnumerator];
}


- (UTType *)uniformTypeForExtension:(NSString *)ext {
  UTType  *type = typeForExtension[ext];
  if (type != nil) {
    // The extension was already encountered.
    return type;
  }

  type = [UTType typeWithFilenameExtension: ext];
  if (type.isPublicType || type.isDeclared) {
    // Only create types for declared types (not for dynamically created ones).
    type = [self uniformTypeForIdentifier: type.identifier];
  } else {
    numUnrecognizedExtensions++;
    os_log_debug(LogManager.defaultLogManager.trustedLog,
                 "Unrecognized extension: %{public}@", ext);
    type = UTType.unknownType;
  }

  typeForExtension[ext] = type;

  return type;
}

- (UTType *)uniformTypeForIdentifier:(NSString *)uti {
  UTType  *type = typeForUTI[uti];

  if (type != nil) {
    // It has already been registered
    return type;
  }

  // Temporarily associate "unknown" with the UTI to mark that the type is currently being created.
  // This is done to guard against infinite recursion should there be a cycle in the
  // type-conformance relationships.
  typeForUTI[uti] = UTType.unknownType;

  type = [self createUniformTypeForIdentifier: uti];

  typeForUTI[uti] = type;

  // Notify interested observers
  NSNotification  *notification = 
    [NSNotification notificationWithName: UniformTypeAddedEvent 
                                  object: self
                                userInfo: @{UniformTypeKey: type}];
  [self performSelectorOnMainThread: @selector(postNotification:)
                         withObject: notification
                      waitUntilDone: NO];
  
  return type;
}

@end // @implementation UniformTypeInventory


@implementation UniformTypeInventory (PrivateMethods)

- (void) postNotification:(NSNotification *)notification {
  [NSNotificationCenter.defaultCenter postNotification: notification];
}

- (UTType *)createUniformTypeForIdentifier:(NSString *)uti {
  UTType  *type = [UTType typeWithIdentifier: uti];
    
  if (type == nil) {
    // The UTI is not recognized.
    os_log_info(LogManager.defaultLogManager.mainLog, "Failed to create type for %{public}@", uti);

    return UTType.unknownType;
  }

  // Ensure all ancestor types are also created
  for (UTType* ancestor in type.supertypes) {
    [self uniformTypeForIdentifier: ancestor.identifier];
  }

  return type;
}

@end // @implementation UniformTypeInventory (PrivateMethods)
