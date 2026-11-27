#import <UIKit/UIKit.h>

@interface TSPresentationDelegate : NSObject
@property (class) UIViewController* presentationViewController;
@property (class) UIAlertController* activityController;
+ (void)startActivity:(NSString*)activity withCancelHandler:(void (^)(void))cancelHandler;
+ (void)startActivity:(NSString*)activity;
// 更新当前进度框的标题文案（进度框不存在时静默忽略）
+ (void)updateActivityMessage:(NSString*)message;
+ (void)stopActivityWithCompletion:(void (^)(void))completion;
+ (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion;
@end