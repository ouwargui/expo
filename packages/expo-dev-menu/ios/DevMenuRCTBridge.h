// Copyright 2015-present 650 Industries. All rights reserved.

#import <React/RCTBridge+Private.h>

NS_ASSUME_NONNULL_BEGIN

@interface DevMenuRCTCxxBridge : RCTCxxBridge

- (NSArray<Class> *)filterModuleList:(NSArray<Class> *)modules;

@end

@interface DevMenuRCTBridge : RCTBridge

- (Class)bridgeClass;

@end

@interface DevMenuRCTCxxBridgeDelegate : NSObject

@end

NS_ASSUME_NONNULL_END
