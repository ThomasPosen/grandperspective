#import "LogManager.h"

@implementation LogManager

+ (LogManager *)defaultLogManager {
  static LogManager  *defaultLogManagerInstance = nil;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    defaultLogManagerInstance = [[LogManager alloc] init];
  });

  return defaultLogManagerInstance;
}

- (id) init {
  if (self = [super init]) {
    NSUserDefaults *args = NSUserDefaults.standardUserDefaults;
    bool enableTrustedLog = [args boolForKey: @"logAll"];

    mainLog = os_log_create("net.sf.grandperspectiv", "main");
    trustedLog = (enableTrustedLog
                  ? os_log_create("net.sf.grandperspectiv", "trusted")
                  : OS_LOG_DISABLED);

    os_log(mainLog, "trusted log enabled = %d", enableTrustedLog);
  }

  return self;
}

- (os_log_t)mainLog {
  return mainLog;
}

- (os_log_t)trustedLog {
  return trustedLog;
}

@end // @implementation LogManager
