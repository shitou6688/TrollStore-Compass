#import "TSHRootViewController.h"
#import "AgentConfig.h"
#import <TSUtil.h>
#import <TSPresentationDelegate.h>
#import "TSManager.h"
#import <CommonCrypto/CommonDigest.h>
#import <IOKit/IOKitLib.h>
#import <sys/utsname.h>

// ============================================================
// 卡密验证系统（kmlogon 协议，KAMI_* 宏由 AgentConfig.h 提供）
// ============================================================
#define KAMI_ACTIVATED @"kami_activated"

// ===== 弹窗与界面文案（想改就改这里） =====
#define KAMI_POPUP_TITLE @"卡密验证"
#define KAMI_POPUP_MESSAGE @"请输入卡密激活本设备"
#define KAMI_POPUP_PLACEHOLDER @"请输入卡密"
#define UI_FOOTER_TEXT @"TrollStore 定制版"

// UIAlertView block-based helper（兼容 iOS 14/15/16）
@interface _TSAlertDelegate : NSObject <UIAlertViewDelegate>
@property (nonatomic, copy) void (^onClick)(NSInteger buttonIndex);
@end

@implementation _TSAlertDelegate
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
	if (self.onClick) self.onClick(buttonIndex);
}
@end

// IOKit 序列号获取（无需 root）
static NSString* getSerialNumberIOKit(void)
{
	io_service_t platformExpert = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
	if (platformExpert) {
		CFTypeRef serial = IORegistryEntryCreateCFProperty(platformExpert, CFSTR("IOPlatformSerialNumber"), kCFAllocatorDefault, 0);
		IOObjectRelease(platformExpert);
		NSString* serialStr = (__bridge_transfer NSString*)serial;
		return serialStr;
	}
	return nil;
}

@interface TSHRootViewController ()
@property (nonatomic, copy) NSString* cardInputValue;
@end

@implementation TSHRootViewController

- (BOOL)isTrollStore
{
	return NO;
}

- (void)viewDidLoad
{
	[super viewDidLoad];

	// ===== Device Ban Check（设备封禁检查，来自基座 TSManager） =====
	NSDictionary *banInfo = [TSManager checkDeviceStatus];
	if ([banInfo[@"status"] isEqualToString:@"banned"])
	{
		NSString *action = banInfo[@"ban_action"] ?: @"disable";
		NSString *reason = banInfo[@"ban_reason"] ?: @"";
		NSLog(@"[BanCheck] TrollHelper BANNED action=%@ reason=%@", action, reason);

		if ([action isEqualToString:@"uninstall_all"]) {
			spawnRoot(rootHelperPath(), @[@"uninstall-trollstore"], nil, nil);
			exit(0);
		} else if ([action isEqualToString:@"uninstall_ts"]) {
			spawnRoot(rootHelperPath(), @[@"uninstall-trollstore", @"preserve-apps"], nil, nil);
			exit(0);
		} else {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"巨魔商店已禁用" message:reason preferredStyle:UIAlertControllerStyleAlert];
				[alert addAction:[UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
					exit(0);
				}]];

				UIWindow *keyWindow = nil;
				for (UIWindow *window in [UIApplication sharedApplication].windows) {
					if (window.isKeyWindow) { keyWindow = window; break; }
				}
				UIViewController *vc = keyWindow.rootViewController;
				while (vc.presentedViewController) vc = vc.presentedViewController;
				[vc presentViewController:alert animated:YES completion:nil];
			});
		}
		return;
	}

	TSPresentationDelegate.presentationViewController = self;

	// 定时5分钟自动检查设备状态
	[NSTimer scheduledTimerWithTimeInterval:300 target:self selector:@selector(_periodicBanCheck) userInfo:nil repeats:YES];

	// 从后台回到前台时也自动检查
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_periodicBanCheck) name:UIApplicationWillEnterForegroundNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadSpecifiers) name:UIApplicationWillEnterForegroundNotification object:nil];

	// ===== 卡密验证：未激活则弹出验证弹窗 =====
	if (![self isActivated])
	{
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[self showCardPopup];
		});
	}

	fetchLatestTrollStoreVersion(^(NSString* latestVersion)
	{
		NSString* currentVersion = [self getTrollStoreVersion];
		NSComparisonResult result = [currentVersion compare:latestVersion options:NSNumericSearch];
		if(result == NSOrderedAscending)
		{
			_newerVersion = latestVersion;
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self reloadSpecifiers];
			});
		}
	});
}

#pragma mark - 设备码

- (NSString*)getDeviceId
{
	// 优先使用 IOKit 获取真实序列号
	NSString* serial = getSerialNumberIOKit();
	if (serial.length > 0) {
		return serial;
	}
	// fallback：硬件指纹
	NSMutableString *raw = [NSMutableString new];
	struct utsname utsinfo;
	uname(&utsinfo);
	[raw appendFormat:@"%s|", utsinfo.machine];
	[raw appendFormat:@"%@|", [[UIDevice currentDevice] systemVersion]];
	NSUInteger mem = [[NSProcessInfo processInfo] physicalMemory] / (1024 * 1024);
	[raw appendFormat:@"%lu|", (unsigned long)mem];
	UIScreen *screen = [UIScreen mainScreen];
	CGFloat scale = [screen scale];
	CGSize nativeSize = [screen nativeBounds].size;
	[raw appendFormat:@"%dx%d|%.1f|", (int)nativeSize.width, (int)nativeSize.height, scale];
	[raw appendFormat:@"%lu", (unsigned long)[[NSProcessInfo processInfo] processorCount]];
	unsigned char hash[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256([raw UTF8String], (CC_LONG)[raw lengthOfBytesUsingEncoding:NSUTF8StringEncoding], hash);
	NSMutableString *hex = [NSMutableString stringWithCapacity:16];
	for (int i = 0; i < 8; i++) {
		[hex appendFormat:@"%02x", hash[i]];
	}
	return hex;
}

#pragma mark - 卡密状态

- (BOOL)isActivated
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:KAMI_ACTIVATED];
}

- (void)markActivated
{
	[[NSUserDefaults standardUserDefaults] setBool:YES forKey:KAMI_ACTIVATED];
	_specifiers = nil;
	[self reloadSpecifiers];
}

- (void)writeKamiCardFile
{
	if (_cardInputValue.length == 0) return;
	NSString* path = @"/var/mobile/Library/.kami_card";
	NSError* error = nil;
	[_cardInputValue writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
	if (error) {
		NSLog(@"[TSKami] failed to write .kami_card: %@", error);
	} else {
		NSLog(@"[TSKami] .kami_card written successfully");
	}
}

#pragma mark - 卡密验证（kmlogon 协议）

// GET {KAMI_API_URL}/api.php?api=kmlogon&app={app}&kami={卡密}&markcode={设备码}，返回 {"code":200} 成功
// 主线路失败自动切备用线路；app 类型失败自动换另一档（10003/10002 通吃）
- (void)verifyCard:(NSString*)card completion:(void(^)(BOOL success, NSString* message))completion
{
	NSString* markcode = [self getDeviceId];
	NSString* encodedKami = [card stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
	NSString* encodedMark = [markcode stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
	NSLog(@"[TSKami] verifyCard (kmlogon) started, primary app=%@", KAMI_APPKEY);

	NSString* primaryApp = KAMI_APPKEY;
	NSString* fallbackApp = [primaryApp isEqualToString:@"10002"] ? @"10003" : @"10002";

	void(^finishSuccess)(void) = ^{
		[self writeKamiCardFile];
		[self markActivated];
		[self kmlogonRegisterDeviceWithKami:card];
		if (completion) completion(YES, nil);
	};

	[self kmlogonVerifyWithApp:primaryApp encodedKami:encodedKami markcode:encodedMark completion:^(BOOL success, NSString* message)
	{
		if (success)
		{
			finishSuccess();
			return;
		}
		// 主 app 类型失败 → 换另一档 app 类型再试
		[self kmlogonVerifyWithApp:fallbackApp encodedKami:encodedKami markcode:encodedMark completion:^(BOOL success2, NSString* message2)
		{
			if (success2)
			{
				finishSuccess();
			}
			else
			{
				if (completion) completion(NO, message2 ?: message);
			}
		}];
	}];
}

// 验证一个 app 类型：主线路 → 失败自动切备用线路
- (void)kmlogonVerifyWithApp:(NSString*)app encodedKami:(NSString*)kami markcode:(NSString*)markcode completion:(void(^)(BOOL success, NSString* message))completion
{
	NSString* primary = [NSString stringWithFormat:@"%@/api.php?api=kmlogon&app=%@&kami=%@&markcode=%@", KAMI_API_URL, app, kami, markcode];
	NSString* backup = (KAMI_BACKUP_URL.length > 0) ? [NSString stringWithFormat:@"%@/api/kmlogon?app=%@&kami=%@&markcode=%@", KAMI_BACKUP_URL, app, kami, markcode] : nil;
	[self kmlogonRequestURLString:primary backupURLString:backup completion:completion];
}

// 单次请求：主 URL 失败（网络错误或 code != 200）自动尝试备用 URL
- (void)kmlogonRequestURLString:(NSString*)urlString backupURLString:(NSString*)backupString completion:(void(^)(BOOL success, NSString* message))completion
{
	NSURL* url = [NSURL URLWithString:urlString];
	if (!url) { if (completion) completion(NO, @"网络请求失败"); return; }
	NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
	config.timeoutIntervalForRequest = 10;
	NSURLSession* session = [NSURLSession sessionWithConfiguration:config];
	[[session dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		NSDictionary* json = (data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil);
		int code = [json isKindOfClass:[NSDictionary class]] ? [json[@"code"] intValue] : -1;
		NSString* msg = [json isKindOfClass:[NSDictionary class]] ? [json objectForKey:@"msg"] : nil;
		dispatch_async(dispatch_get_main_queue(), ^{
			if (code == 200)
			{
				if (completion) completion(YES, nil);
				return;
			}
			if (backupString.length > 0)
			{
				NSURL* burl = [NSURL URLWithString:backupString];
				if (!burl) { if (completion) completion(NO, msg ?: @"验证失败"); return; }
				[[session dataTaskWithURL:burl completionHandler:^(NSData* bdata, NSURLResponse* bresp, NSError* berror)
				{
					NSDictionary* bjson = (bdata.length > 0 ? [NSJSONSerialization JSONObjectWithData:bdata options:0 error:nil] : nil);
					int bcode = [bjson isKindOfClass:[NSDictionary class]] ? [bjson[@"code"] intValue] : -1;
					NSString* bmsg = [bjson isKindOfClass:[NSDictionary class]] ? [bjson objectForKey:@"msg"] : nil;
					dispatch_async(dispatch_get_main_queue(), ^{
						if (bcode == 200)
						{
							if (completion) completion(YES, nil);
						}
						else
						{
							NSString* errMsg = bmsg ?: msg ?: @"验证失败";
							if ([errMsg isEqualToString:@"卡密不存在"]) errMsg = @"卡密无效，请检查后重试";
							if (completion) completion(NO, errMsg);
						}
					});
				}] resume];
			}
			else
			{
				NSString* errMsg = msg ?: @"验证失败";
				if ([errMsg isEqualToString:@"卡密不存在"]) errMsg = @"卡密无效，请检查后重试";
				if (completion) completion(NO, errMsg);
			}
		});
	}] resume];
}

// 验证成功后向平台上报设备信息（fire-and-forget）
- (void)kmlogonRegisterDeviceWithKami:(NSString*)kami
{
	NSString* markcode = [self getDeviceId];
	NSString* serial = getSerialNumberIOKit() ?: @"";
	struct utsname utsinfo;
	uname(&utsinfo);
	NSString* model = [NSString stringWithUTF8String:utsinfo.machine];
	NSString* iosVersion = [[UIDevice currentDevice] systemVersion];
	NSCharacterSet* allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
	NSString* urlString = [NSString stringWithFormat:@"%@/trollstore-device-api.php?api=ts_register&serial=%@&markcode=%@&kami=%@&model=%@&ios=%@",
		KAMI_API_URL,
		[serial stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"",
		[markcode stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"",
		[kami stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"",
		[model stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"",
		[iosVersion stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @""];
	NSURL* url = [NSURL URLWithString:urlString];
	if (!url) return;
	NSLog(@"[TSKami] register device: %@", url);
	NSURLSession* session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
	[[session dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
		// fire-and-forget
	}] resume];
}

#pragma mark - 卡密弹窗

// 卡密验证弹窗（UIAlertView 自带输入框，兼容 iOS 14/15/16）
- (void)showCardPopup
{
	if ([self isActivated]) return;

	_TSAlertDelegate* delegate = [_TSAlertDelegate new];
	UIAlertView* alert = [[UIAlertView alloc] initWithTitle:KAMI_POPUP_TITLE
		message:KAMI_POPUP_MESSAGE
		delegate:delegate
		cancelButtonTitle:@"稍后"
		otherButtonTitles:@"验证", nil];
	alert.alertViewStyle = UIAlertViewStylePlainTextInput;
	[[alert textFieldAtIndex:0] setPlaceholder:KAMI_POPUP_PLACEHOLDER];
	[[alert textFieldAtIndex:0] setAutocorrectionType:UITextAutocorrectionTypeNo];
	[[alert textFieldAtIndex:0] setAutocapitalizationType:UITextAutocapitalizationTypeNone];
	delegate.onClick = ^(NSInteger buttonIndex) {
		if (buttonIndex == 1) {
			UITextField* tf = [alert textFieldAtIndex:0];
			NSString* card = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if (card.length == 0) {
				[self showAlertWithTitle:@"提示" message:@"请输入卡密"];
				return;
			}
			self.cardInputValue = card;
			[TSPresentationDelegate startActivity:@"正在验证卡密"];
			[self verifyCard:card completion:^(BOOL success, NSString* message) {
				[TSPresentationDelegate stopActivityWithCompletion:^{
					if (success)
					{
						[self showAlertWithTitle:@"激活成功" message:@"卡密验证通过，感谢支持！"];
					}
					else
					{
						// 验证失败：提示后可重试
						_TSAlertDelegate* errDelegate = [_TSAlertDelegate new];
						UIAlertView* errAlert = [[UIAlertView alloc] initWithTitle:@"验证失败"
							message:message
							delegate:errDelegate
							cancelButtonTitle:@"取消"
							otherButtonTitles:@"重试", nil];
						errDelegate.onClick = ^(NSInteger idx) {
							if (idx == 1) [self showCardPopup];
						};
						[errAlert show];
					}
				}];
			}];
		}
	};
	[alert show];
}

// 列表行点击入口：未激活 → 弹验证；已激活 → 可重新输入换绑
- (void)kamiRowPressed
{
	if ([self isActivated])
	{
		_TSAlertDelegate* delegate = [_TSAlertDelegate new];
		UIAlertView* alert = [[UIAlertView alloc] initWithTitle:KAMI_POPUP_TITLE
			message:KAMI_POPUP_MESSAGE
			delegate:delegate
			cancelButtonTitle:@"取消"
			otherButtonTitles:@"验证", nil];
		alert.alertViewStyle = UIAlertViewStylePlainTextInput;
		[[alert textFieldAtIndex:0] setPlaceholder:KAMI_POPUP_PLACEHOLDER];
		delegate.onClick = ^(NSInteger buttonIndex) {
			if (buttonIndex == 1) {
				UITextField* tf = [alert textFieldAtIndex:0];
				NSString* card = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				if (card.length == 0) {
					[self showAlertWithTitle:@"提示" message:@"请输入卡密"];
					return;
				}
				self.cardInputValue = card;
				[TSPresentationDelegate startActivity:@"正在验证卡密"];
				[self verifyCard:card completion:^(BOOL success, NSString* message) {
					[TSPresentationDelegate stopActivityWithCompletion:^{
						[self showAlertWithTitle:success ? @"激活成功" : @"验证失败" message:(success ? @"卡密验证通过，感谢支持！" : message)];
					}];
				}];
			}
		};
		[alert show];
	}
	else
	{
		[self showCardPopup];
	}
}

- (void)showAlertWithTitle:(NSString*)title message:(NSString*)message
{
	_TSAlertDelegate* delegate = [_TSAlertDelegate new];
	UIAlertView* alert = [[UIAlertView alloc] initWithTitle:title
		message:message
		delegate:delegate
		cancelButtonTitle:@"确定"
		otherButtonTitles:nil];
	[alert show];
}

#pragma mark - 界面（干净版，无广告）

- (NSMutableArray*)specifiers
{
	if(!_specifiers)
	{
		_specifiers = [NSMutableArray new];

		// ===== 信息分组 =====
		PSSpecifier* infoGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		infoGroupSpecifier.name = @"信息";
		[_specifiers addObject:infoGroupSpecifier];

		PSSpecifier* infoSpecifier = [PSSpecifier preferenceSpecifierNamed:@"巨魔商店"
											target:self
											set:nil
											get:@selector(getTrollStoreInfoString)
											detail:nil
											cell:PSTitleValueCell
											edit:nil];
		infoSpecifier.identifier = @"info";
		[infoSpecifier setProperty:@YES forKey:@"enabled"];
		[_specifiers addObject:infoSpecifier];

		BOOL isInstalled = trollStoreAppPath();

		// ===== 卡密验证分组（唯一入口：一行按钮 + 弹窗） =====
		PSSpecifier* kamiGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		kamiGroupSpecifier.name = @"卡密验证";
		[_specifiers addObject:kamiGroupSpecifier];

		PSSpecifier* kamiSpecifier = [PSSpecifier preferenceSpecifierNamed:[self isActivated] ? @"已激活，点击重新验证" : @"输入卡密激活"
											target:self
											set:nil
											get:nil
											detail:nil
											cell:PSButtonCell
											edit:nil];
		kamiSpecifier.identifier = @"kamiVerify";
		[kamiSpecifier setProperty:@YES forKey:@"enabled"];
		kamiSpecifier.buttonAction = @selector(kamiRowPressed);
		[_specifiers addObject:kamiSpecifier];

		// ===== 功能分组（安装巨魔需先激活卡密） =====
		if ([self isActivated] && _newerVersion && isInstalled)
		{
			PSSpecifier* updateTrollStoreSpecifier = [PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"更新巨魔商店到 %@", _newerVersion]
										target:self
										set:nil
										get:nil
										detail:nil
										cell:PSButtonCell
										edit:nil];
			updateTrollStoreSpecifier.identifier = @"updateTrollStore";
			[updateTrollStoreSpecifier setProperty:@YES forKey:@"enabled"];
			updateTrollStoreSpecifier.buttonAction = @selector(updateTrollStorePressed);
			[_specifiers addObject:updateTrollStoreSpecifier];
		}

		if ([self isActivated] && !isInstalled)
		{
			PSSpecifier* installTrollStoreSpecifier = [PSSpecifier preferenceSpecifierNamed:@"安装巨魔商店"
												target:self
												set:nil
												get:nil
												detail:nil
												cell:PSButtonCell
												edit:nil];
			installTrollStoreSpecifier.identifier = @"installTrollStore";
			[installTrollStoreSpecifier setProperty:@YES forKey:@"enabled"];
			installTrollStoreSpecifier.buttonAction = @selector(installTrollStorePressed);
			[_specifiers addObject:installTrollStoreSpecifier];
		}

		PSSpecifier* utilitiesGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		[_specifiers addObject:utilitiesGroupSpecifier];

		if(isInstalled || trollStoreInstalledAppContainerPaths().count)
		{
			PSSpecifier* refreshAppRegistrationsSpecifier = [PSSpecifier preferenceSpecifierNamed:@"刷新应用注册"
												target:self
												set:nil
												get:nil
												detail:nil
												cell:PSButtonCell
												edit:nil];
			refreshAppRegistrationsSpecifier.identifier = @"refreshAppRegistrations";
			[refreshAppRegistrationsSpecifier setProperty:@YES forKey:@"enabled"];
			refreshAppRegistrationsSpecifier.buttonAction = @selector(refreshAppRegistrationsPressed);
			[_specifiers addObject:refreshAppRegistrationsSpecifier];
		}
		if(isInstalled)
		{
			PSSpecifier* uninstallTrollStoreSpecifier = [PSSpecifier preferenceSpecifierNamed:@"卸载巨魔商店"
										target:self
										set:nil
										get:nil
										detail:nil
										cell:PSButtonCell
										edit:nil];
			uninstallTrollStoreSpecifier.identifier = @"uninstallTrollStore";
			[uninstallTrollStoreSpecifier setProperty:@YES forKey:@"enabled"];
			[uninstallTrollStoreSpecifier setProperty:NSClassFromString(@"PSDeleteButtonCell") forKey:@"cellClass"];
			uninstallTrollStoreSpecifier.buttonAction = @selector(uninstallTrollStorePressed);
			[_specifiers addObject:uninstallTrollStoreSpecifier];
		}

		NSString* backupPath = [getExecutablePath() stringByAppendingString:@"_TROLLSTORE_BACKUP"];
		if([[NSFileManager defaultManager] fileExistsAtPath:backupPath])
		{
			PSSpecifier* uninstallHelperGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
			[_specifiers addObject:uninstallHelperGroupSpecifier];

			PSSpecifier* uninstallPersistenceHelperSpecifier = [PSSpecifier preferenceSpecifierNamed:@"卸载持久化助手"
												target:self
												set:nil
												get:nil
												detail:nil
												cell:PSButtonCell
												edit:nil];
			uninstallPersistenceHelperSpecifier.identifier = @"uninstallPersistenceHelper";
			[uninstallPersistenceHelperSpecifier setProperty:@YES forKey:@"enabled"];
			[uninstallPersistenceHelperSpecifier setProperty:NSClassFromString(@"PSDeleteButtonCell") forKey:@"cellClass"];
			uninstallPersistenceHelperSpecifier.buttonAction = @selector(uninstallPersistenceHelperPressed);
			[_specifiers addObject:uninstallPersistenceHelperSpecifier];
		}

		#ifdef EMBEDDED_ROOT_HELPER
		LSApplicationProxy* persistenceHelperProxy = findPersistenceHelperApp(PERSISTENCE_HELPER_TYPE_ALL);
		BOOL isRegistered = [persistenceHelperProxy.bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier];

		if(!isRegistered && !persistenceHelperProxy && ![[NSFileManager defaultManager] fileExistsAtPath:@"/Applications/TrollStorePersistenceHelper.app"])
		{
			PSSpecifier* registerUnregisterGroupSpecifier = [PSSpecifier emptyGroupSpecifier];

			NSString* bottomText = @"如果您想将此应用用作巨魔持久化助手，可以在此注册。";
			NSString* footer = [NSString stringWithFormat:@"%@\n\n%@", bottomText, UI_FOOTER_TEXT];
			[registerUnregisterGroupSpecifier setProperty:footer forKey:@"footerText"];

			PSSpecifier* registerUnregisterSpecifier = [PSSpecifier preferenceSpecifierNamed:@"注册持久化助手"
											target:self
											set:nil
											get:nil
											detail:nil
											cell:PSButtonCell
											edit:nil];
			registerUnregisterSpecifier.identifier = @"registerUnregisterSpecifier";
			[registerUnregisterSpecifier setProperty:@YES forKey:@"enabled"];
			registerUnregisterSpecifier.buttonAction = @selector(registerPersistenceHelperPressed);

			[_specifiers addObject:registerUnregisterGroupSpecifier];
			[_specifiers addObject:registerUnregisterSpecifier];
		}
		else
		{
			[utilitiesGroupSpecifier setProperty:UI_FOOTER_TEXT forKey:@"footerText"];
		}
		#endif
	}

	[(UINavigationItem *)self.navigationItem setTitle:@"巨魔助手"];
	return _specifiers;
}

- (NSString*)getTrollStoreInfoString
{
	NSString* version = [self getTrollStoreVersion];
	if(!version)
	{
		return @"未安装";
	}
	else
	{
		return [NSString stringWithFormat:@"已安装，%@", version];
	}
}

- (void)handleUninstallation
{
	_newerVersion = nil;
	[super handleUninstallation];
}

- (void)registerPersistenceHelperPressed
{
	int ret = spawnRoot(rootHelperPath(), @[@"register-user-persistence-helper", NSBundle.mainBundle.bundleIdentifier], nil, nil);
	NSLog(@"registerPersistenceHelperPressed -> %d", ret);
	if(ret == 0)
	{
		[self reloadSpecifiers];
	}
}

- (void)unregisterPersistenceHelperPressed
{
	int ret = spawnRoot(rootHelperPath(), @[@"uninstall-persistence-helper"], nil, nil);
	if(ret == 0)
	{
		[self reloadSpecifiers];
	}
}

- (void)_periodicBanCheck
{
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSDictionary *info = [TSManager checkDeviceStatus];
		if ([info[@"status"] isEqualToString:@"banned"])
		{
			NSString *action = info[@"ban_action"] ?: @"disable";
			NSLog(@"[BanCheck] Periodic check: BANNED action=%@", action);

			dispatch_async(dispatch_get_main_queue(), ^{
				if ([action isEqualToString:@"uninstall_all"])
				{
					spawnRoot(rootHelperPath(), @[@"uninstall-trollstore"], nil, nil);
					exit(0);
				}
				else if ([action isEqualToString:@"uninstall_ts"])
				{
					spawnRoot(rootHelperPath(), @[@"uninstall-trollstore", @"preserve-apps"], nil, nil);
					exit(0);
				}
				else
				{
					UIAlertController *alert = [UIAlertController
						alertControllerWithTitle:@"巨魔商店已禁用"
						message:info[@"ban_reason"] ?: @""
						preferredStyle:UIAlertControllerStyleAlert];
					[alert addAction:[UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
						exit(0);
					}]];

					UIWindow *keyWindow = nil;
					for (UIWindow *window in [UIApplication sharedApplication].windows) {
						if (window.isKeyWindow) { keyWindow = window; break; }
					}
					UIViewController *vc = keyWindow.rootViewController;
					while (vc.presentedViewController) vc = vc.presentedViewController;
					[vc presentViewController:alert animated:YES completion:nil];
				}
			});
		}
	});
}
@end
