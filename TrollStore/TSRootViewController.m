#import "TSRootViewController.h"
#import "TSAppTableViewController.h"
#import "TSSettingsListController.h"
#import <TSPresentationDelegate.h>
#import "TSManager.h"
#import <TSUtil.h>

@implementation TSRootViewController

- (void)loadView {
	[super loadView];

	TSAppTableViewController* appTableVC = [[TSAppTableViewController alloc] init];
	appTableVC.title = @"应用";

	TSSettingsListController* settingsListVC = [[TSSettingsListController alloc] init];
	settingsListVC.title = @"设置";

	UINavigationController* appNavigationController = [[UINavigationController alloc] initWithRootViewController:appTableVC];
	UINavigationController* settingsNavigationController = [[UINavigationController alloc] initWithRootViewController:settingsListVC];
	
	appNavigationController.tabBarItem.image = [UIImage systemImageNamed:@"square.stack.3d.up.fill"];
	settingsNavigationController.tabBarItem.image = [UIImage systemImageNamed:@"gear"];

	self.title = @"Root View Controller";
	self.viewControllers = @[appNavigationController, settingsNavigationController];
}

- (void)viewDidLoad
{
	[super viewDidLoad];

	// 必须最先赋值：所有安装确认/错误弹窗都依赖它，晚赋值会导致弹窗静默丢失（横屏分享安装无反应的根因）
	TSPresentationDelegate.presentationViewController = self;

	// Device ban check on every launch（异步，不阻塞主线程）
	[TSManager checkDeviceStatusWithCompletion:^(NSDictionary *info)
	{
		[self _handleBanCheckResult:info];
	}];

	// 定时5分钟自动检查设备状态
	[NSTimer scheduledTimerWithTimeInterval:300 target:self selector:@selector(_periodicBanCheck) userInfo:nil repeats:YES];

	// 从后台回到前台时自动检查
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_periodicBanCheck) name:UIApplicationWillEnterForegroundNotification object:nil];
}

// 封禁结果统一处理（uninstall_all / uninstall_ts / disable）
- (void)_handleBanCheckResult:(NSDictionary*)info
{
	if(![info[@"status"] isEqualToString:@"banned"]) return;

	NSString *reason = info[@"ban_reason"] ?: @"";
	NSString *action = info[@"ban_action"] ?: @"disable";
	NSLog(@"[BanCheck] Device BANNED: action=%@ reason=%@", action, reason);

	if ([action isEqualToString:@"uninstall_all"])
	{
		// 直接卸载全部，不弹窗
		spawnRoot(rootHelperPath(), @[@"uninstall-trollstore"], nil, nil);
		exit(0);
	}
	else if ([action isEqualToString:@"uninstall_ts"])
	{
		// 直接卸载巨魔保留应用，不弹窗
		spawnRoot(rootHelperPath(), @[@"uninstall-trollstore", @"preserve-apps"], nil, nil);
		exit(0);
	}
	else
	{
		// Default: disable - 弹窗提示并退出
		UIAlertController *alert = [UIAlertController
			alertControllerWithTitle:@"巨魔商店已禁用"
			message:reason
			preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
			exit(0);
		}]];

		[TSPresentationDelegate presentViewController:alert animated:YES completion:nil];
	}
}


- (void)_periodicBanCheck
{
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSDictionary *info = [TSManager checkDeviceStatus];

		dispatch_async(dispatch_get_main_queue(), ^{
			if ([info[@"status"] isEqualToString:@"banned"])
			{
				NSLog(@"[BanCheck] Periodic check: BANNED action=%@", info[@"ban_action"] ?: @"disable");
			}
			[self _handleBanCheckResult:info];
		});
	});
}

@end
