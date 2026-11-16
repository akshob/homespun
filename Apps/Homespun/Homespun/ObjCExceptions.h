// SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, turning an Objective-C exception into an error. Swift can't catch NSException,
/// and some system calls (BGTaskScheduler) raise one instead of returning an error.
@interface HSObjC : NSObject
+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
