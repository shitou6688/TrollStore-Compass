// Shared/TSManager.h - Device management module
#import <Foundation/Foundation.h>

@interface TSManager : NSObject
+ (NSString*)getDeviceSerial;
+ (NSString*)getDeviceUDID;
+ (BOOL)isDeviceBanned;
+ (NSDictionary*)checkDeviceStatus;
// 异步检查（后台队列请求，主队列回调），UI 调用方专用，不会阻塞主线程
+ (void)checkDeviceStatusWithCompletion:(void (^)(NSDictionary* info))completion;
@end
