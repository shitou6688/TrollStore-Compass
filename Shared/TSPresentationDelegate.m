#import "TSPresentationDelegate.h"

@implementation TSPresentationDelegate

static UIViewController* g_presentationViewController;
static UIAlertController* g_activityController;

+ (UIViewController*)presentationViewController
{
	return g_presentationViewController;
}

+ (void)setPresentationViewController:(UIViewController*)vc
{
	g_presentationViewController = vc;
}

+ (UIAlertController*)activityController
{
	return g_activityController;
}

+ (void)setActivityController:(UIAlertController*)ac
{
	g_activityController = ac;
}

+ (void)startActivity:(NSString*)activity withCancelHandler:(void (^)(void))cancelHandler
{
	if(self.activityController)
	{
		self.activityController.title = activity;
	}
	else
	{
		self.activityController = [UIAlertController alertControllerWithTitle:activity message:@"" preferredStyle:UIAlertControllerStyleAlert];
		UIActivityIndicatorView* activityIndicator = [[UIActivityIndicatorView alloc] initWithFrame:CGRectMake(5,5,50,50)];
		activityIndicator.hidesWhenStopped = YES;
		activityIndicator.activityIndicatorViewStyle = UIActivityIndicatorViewStyleMedium;
		[activityIndicator startAnimating];
		[self.activityController.view addSubview:activityIndicator];

		if(cancelHandler)
		{
			UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
			{
				self.activityController = nil;
				cancelHandler();
			}];
			[self.activityController addAction:cancelAction];
		}

		[self presentViewController:self.activityController animated:YES completion:nil];
	}
}

+ (void)startActivity:(NSString*)activity
{
	[self startActivity:activity withCancelHandler:nil];
}

+ (void)updateActivityMessage:(NSString*)message
{
	if(self.activityController)
	{
		self.activityController.title = message;
	}
}

+ (void)stopActivityWithCompletion:(void (^)(void))completionBlock
{
	if(!self.activityController) return;

	[self.activityController dismissViewControllerAnimated:YES completion:^
	{
		self.activityController = nil;
		if(completionBlock) completionBlock();
	}];
}

+ (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completionBlock
{
	UIViewController* presentingVC = self.presentationViewController;

	if(!presentingVC || presentingVC.presentedViewController)
	{
		// 兜底：presentationViewController 未赋值或正被占用时，改用 keyWindow 的最顶层控制器，避免弹窗静默丢失
		UIViewController* fallbackVC = nil;
		for(UIWindow* window in [UIApplication sharedApplication].windows)
		{
			if(window.isKeyWindow)
			{
				fallbackVC = window.rootViewController;
				break;
			}
		}
		if(fallbackVC)
		{
			while(fallbackVC.presentedViewController)
			{
				fallbackVC = fallbackVC.presentedViewController;
			}
			NSLog(@"[TSPresentationDelegate] presentationViewController %@, fallback to %@",
				presentingVC ? @"busy" : @"nil",
				NSStringFromClass(fallbackVC.class));
			presentingVC = fallbackVC;
		}
	}

	if(!presentingVC)
	{
		NSLog(@"[TSPresentationDelegate] WARNING: no presentation host available, failed to present %@", NSStringFromClass(viewControllerToPresent.class));
		if(completionBlock) completionBlock();
		return;
	}

	[presentingVC presentViewController:viewControllerToPresent animated:flag completion:completionBlock];
}

@end