// SPDX-License-Identifier: Apache-2.0
#import "ObjCExceptions.h"

@implementation HSObjC

+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"photos.homespun.objc-exception" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason, @"name": exception.name}];
        }
        return NO;
    }
}

@end
