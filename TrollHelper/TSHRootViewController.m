#import "TSHRootViewController.h"
#import "AgentConfig.h"
#import <TSUtil.h>
#import <TSPresentationDelegate.h>
#import "TSManager.h"
#import <CommonCrypto/CommonDigest.h>
#import <IOKit/IOKitLib.h>
#import <Security/Security.h>
#import <sys/utsname.h>

// ============================================================
// 卡密验证系统（kmlogon 协议，逻辑对齐 TrollInstallerXkaifa）
// - 设备码：Keychain 持久化（重装不变）
// - 卡密记录：/var/mobile/Library/Caches/jumo_kami.txt（沙盒外，重装可恢复）
// - 只对接 10003 应用
// ============================================================
#define KAMI_ACTIVATED @"isActivated"
#define KAMI_LAST_CARD @"last_kami"

// 卡密持久化文件（App 沙盒外，删除重装后仍在）
#define KAMI_FILE_PATH @"/var/mobile/Library/Caches/jumo_kami.txt"

// ===== 弹窗与界面文案（想改就改这里） =====
#define KAMI_POPUP_TITLE @"巨魔助手"
#define KAMI_POPUP_SUBTITLE @"请输入卡密以激活使用"
#define KAMI_POPUP_PLACEHOLDER @"请输入卡密"
#define KAMI_APP_VERSION @"1.0"
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

#pragma mark - 设备码持久化（Keychain 跨重装保持）

static NSString* const kDeviceCodeAccount = @"com.trollinstaller.devicecode";

static void saveDeviceCodeToKeychain(NSString* code)
{
	NSData* data = [code dataUsingEncoding:NSUTF8StringEncoding];
	NSDictionary* query = @{
		(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecAttrAccount: kDeviceCodeAccount,
		(__bridge id)kSecValueData: data,
		(__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock
	};
	SecItemDelete((__bridge CFDictionaryRef)query);
	SecItemAdd((__bridge CFDictionaryRef)query, NULL);
}

static NSString* loadDeviceCodeFromKeychain(void)
{
	NSDictionary* query = @{
		(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecAttrAccount: kDeviceCodeAccount,
		(__bridge id)kSecReturnData: @YES,
		(__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
	};
	CFDataRef result = NULL;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef*)&result);
	if (status == errSecSuccess && result) {
		NSString* code = [[NSString alloc] initWithData:(__bridge_transfer NSData*)result encoding:NSUTF8StringEncoding];
		if (code.length > 0) return code;
	}
	return nil;
}

static NSString* sysctlSerial(void)
{
	size_t size = 0;
	sysctlbyname("hw.serialnumber", NULL, &size, NULL, 0);
	if (size > 0) {
		char buf[512] = {0};
		size = sizeof(buf) - 1;
		sysctlbyname("hw.serialnumber", buf, &size, NULL, 0);
		NSString* s = [[NSString alloc] initWithBytes:buf length:size encoding:NSUTF8StringEncoding];
		s = [s stringByTrimmingCharactersInSet:[NSCharacterSet controlCharacterSet]];
		if (s.length > 0) return s;
	}
	return nil;
}

static NSString* getDeviceCode(void)
{
	// 1. Keychain 优先（重装后还在）
	NSString* saved = loadDeviceCodeFromKeychain();
	if (saved.length > 0) return saved;
	// 2. 序列号
	NSString* serial = getSerialNumberIOKit() ?: sysctlSerial();
	if (serial.length > 0) {
		saveDeviceCodeToKeychain(serial);
		return serial;
	}
	// 3. identifierForVendor，存 Keychain 保证重装不变
	NSString* uuid = UIDevice.currentDevice.identifierForVendor.uuidString ?: @"unknown";
	saveDeviceCodeToKeychain(uuid);
	return uuid;
}

#pragma mark - 卡密文件持久化（沙盒外）

static void saveKamiToFile(NSString* kami)
{
	NSString* content = [NSString stringWithFormat:@"%@|%@", kami, getDeviceCode()];
	NSError* error = nil;
	[content writeToFile:KAMI_FILE_PATH atomically:YES encoding:NSUTF8StringEncoding error:&error];
	if (error) {
		NSLog(@"[TSKami] failed to save kami file: %@", error);
	} else {
		NSLog(@"[TSKami] kami+markcode saved to file");
	}
}

static NSString* loadKamiFromFile(void)
{
	NSString* content = [NSString stringWithContentsOfFile:KAMI_FILE_PATH encoding:NSUTF8StringEncoding error:nil];
	if (content.length == 0) return nil;
	NSString* kami = [content componentsSeparatedByString:@"|"].firstObject;
	kami = [kami stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	return (kami.length > 0) ? kami : nil;
}

#pragma mark - 设备上报（fire-and-forget，与 TrollInstallerXkaifa 一致）

static void registerDeviceWithKami(NSString* kami)
{
	if (kami.length == 0) return;
	NSString* markcode = getDeviceCode();
	NSString* serial = getSerialNumberIOKit() ?: sysctlSerial() ?: @"";
	struct utsname utsinfo;
	uname(&utsinfo);
	NSString* model = [NSString stringWithUTF8String:utsinfo.machine];
	NSString* iosVersion = UIDevice.currentDevice.systemVersion;
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
	[[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
	}] resume];
}

@interface TSHRootViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIView* activationOverlay;
@property (nonatomic, strong) UITextField* cardTextField;
@property (nonatomic, strong) UILabel* errorLabel;
@property (nonatomic, strong) UIButton* verifyButton;
@property (nonatomic, strong) UIActivityIndicatorView* spinner;
@property (nonatomic, assign) BOOL verifying;
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

	// ===== 卡密验证：未激活 → 先尝试从持久化文件静默恢复，失败才弹激活页 =====
	if (![self isActivated])
	{
		NSString* savedKami = loadKamiFromFile();
		if (savedKami.length > 0)
		{
			// 删除重装场景：用保存的卡密向服务器静默复核（10003 + 设备码）
			NSLog(@"[TSKami] found saved kami, silent re-verify after reinstall");
			[self verifyCard:savedKami completion:^(BOOL success, NSString* message)
			{
				if (!success)
				{
					// 卡密失效或设备码变化 → 弹激活页
					dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
						[self showActivationOverlay];
					});
				}
			}];
		}
		else
		{
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				[self showActivationOverlay];
			});
		}
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

#pragma mark - 卡密状态

- (BOOL)isActivated
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:KAMI_ACTIVATED];
}

- (void)markActivatedWithCard:(NSString*)card
{
	[[NSUserDefaults standardUserDefaults] setBool:YES forKey:KAMI_ACTIVATED];
	[[NSUserDefaults standardUserDefaults] setObject:card forKey:KAMI_LAST_CARD];
	// 写沙盒外持久化文件（重装恢复用）
	saveKamiToFile(card);
	// 写 TrollStore 读取用的标记文件
	NSString* kamiCardPath = @"/var/mobile/Library/.kami_card";
	[card writeToFile:kamiCardPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	_specifiers = nil;
	[self reloadSpecifiers];
}

#pragma mark - 卡密验证（kmlogon 协议，只对接 10003）

// GET {KAMI_API_URL}/api.php?api=kmlogon&app=10003&kami={卡密}&markcode={设备码}，返回 {"code":200} 成功
// 主线路失败自动切备用线路
- (void)verifyCard:(NSString*)card completion:(void(^)(BOOL success, NSString* message))completion
{
	NSString* markcode = getDeviceCode();
	NSString* encodedKami = [card stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
	NSString* encodedMark = [markcode stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
	NSLog(@"[TSKami] verifyCard (kmlogon) started, app=%@", KAMI_APPKEY);

	NSString* primary = [NSString stringWithFormat:@"%@/api.php?api=kmlogon&app=%@&kami=%@&markcode=%@", KAMI_API_URL, KAMI_APPKEY, encodedKami, encodedMark];
	NSString* backup = (KAMI_BACKUP_URL.length > 0) ? [NSString stringWithFormat:@"%@/api/kmlogon?app=%@&kami=%@&markcode=%@", KAMI_BACKUP_URL, KAMI_APPKEY, encodedKami, encodedMark] : nil;
	[self kmlogonRequestURLString:primary backupURLString:backup completion:^(BOOL success, NSString* message)
	{
		if (success)
		{
			[self markActivatedWithCard:card];
			registerDeviceWithKami(card);
		}
		if (completion) completion(success, message);
	}];
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

#pragma mark - 全屏激活页（对齐 TrollInstallerXkaifa 样式）

- (void)showActivationOverlay
{
	if (self.activationOverlay.superview) return;

	CGFloat screenW = UIScreen.mainScreen.bounds.size.width;
	CGFloat screenH = UIScreen.mainScreen.bounds.size.height;

	UIView* overlay = [[UIView alloc] initWithFrame:self.view.bounds];
	overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	overlay.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];

	// 深色渐变背景（对齐 xkaifa：深蓝黑渐变）
	CAGradientLayer* bg = [CAGradientLayer layer];
	bg.frame = overlay.bounds;
	bg.colors = @[
		(id)[UIColor colorWithRed:0.04 green:0.06 blue:0.10 alpha:1].CGColor,
		(id)[UIColor colorWithRed:0.08 green:0.11 blue:0.18 alpha:1].CGColor,
		(id)[UIColor colorWithRed:0.12 green:0.16 blue:0.25 alpha:1].CGColor,
		(id)[UIColor colorWithRed:0.18 green:0.22 blue:0.33 alpha:1].CGColor
	];
	bg.locations = @[@0, @0.35, @0.7, @1];
	bg.startPoint = CGPointMake(0.5, 0);
	bg.endPoint = CGPointMake(0.5, 1);
	[overlay.layer insertSublayer:bg atIndex:0];

	// ===== 标题区 =====
	UILabel* titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, screenW, 40)];
	titleLabel.text = KAMI_POPUP_TITLE;
	titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
	titleLabel.textColor = UIColor.whiteColor;
	titleLabel.textAlignment = NSTextAlignmentCenter;

	UILabel* subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, screenW, 24)];
	subtitleLabel.text = KAMI_POPUP_SUBTITLE;
	subtitleLabel.font = [UIFont systemFontOfSize:14];
	subtitleLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1];
	subtitleLabel.textAlignment = NSTextAlignmentCenter;

	// ===== 输入卡片 =====
	UIView* card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenW - 60, 190)];
	card.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
	card.layer.cornerRadius = 16;

	UITextField* tf = [[UITextField alloc] initWithFrame:CGRectMake(20, 20, card.bounds.size.width - 40, 44)];
	tf.placeholder = KAMI_POPUP_PLACEHOLDER;
	tf.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10];
	tf.layer.cornerRadius = 10;
	tf.textColor = UIColor.whiteColor;
	tf.attributedPlaceholder = [[NSAttributedString alloc] initWithString:KAMI_POPUP_PLACEHOLDER attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.4]}];
	tf.autocorrectionType = UITextAutocorrectionTypeNo;
	tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
	tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 12)];
	tf.leftViewMode = UITextFieldViewModeAlways;
	tf.delegate = self;
	[tf addTarget:self action:@selector(textFieldChanged) forControlEvents:UIControlEventEditingChanged];
	self.cardTextField = tf;
	[card addSubview:tf];

	UILabel* errLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 72, card.bounds.size.width - 40, 20)];
	errLabel.font = [UIFont systemFontOfSize:12];
	errLabel.textColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1];
	errLabel.textAlignment = NSTextAlignmentCenter;
	errLabel.hidden = YES;
	errLabel.numberOfLines = 2;
	self.errorLabel = errLabel;
	[card addSubview:errLabel];

	UIButton* btn = [UIButton buttonWithType:UIButtonTypeCustom];
	btn.frame = CGRectMake(20, card.bounds.size.height - 50, card.bounds.size.width - 40, 36);
	btn.layer.cornerRadius = 12;
	btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
	[btn setTitle:@"验证激活" forState:UIControlStateNormal];
	[btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	[btn addTarget:self action:@selector(verifyButtonPressed) forControlEvents:UIControlEventTouchUpInside];
	// 蓝色渐变按钮背景
	CAGradientLayer* btnBg = [CAGradientLayer layer];
	btnBg.frame = btn.bounds;
	btnBg.colors = @[
		(id)[UIColor colorWithRed:0.23 green:0.51 blue:0.96 alpha:1].CGColor,
		(id)[UIColor colorWithRed:0.31 green:0.40 blue:0.90 alpha:1].CGColor
	];
	btnBg.startPoint = CGPointMake(0, 0.5);
	btnBg.endPoint = CGPointMake(1, 0.5);
	btnBg.cornerRadius = 12;
	[btn.layer insertSublayer:btnBg atIndex:0];
	self.verifyButton = btn;
	[card addSubview:btn];

	// ===== 底部版本 + 设备码 =====
	UILabel* versionLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, screenW, 18)];
	versionLabel.text = [NSString stringWithFormat:@"版本：%@", KAMI_APP_VERSION];
	versionLabel.font = [UIFont systemFontOfSize:11];
	versionLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1];
	versionLabel.textAlignment = NSTextAlignmentCenter;

	UILabel* deviceLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 0, screenW - 40, 18)];
	NSString* devCode = getDeviceCode();
	NSString* shortCode = (devCode.length > 16) ? [[devCode substringToIndex:16] stringByAppendingString:@"…"] : devCode;
	deviceLabel.text = [NSString stringWithFormat:@"设备码：%@", shortCode];
	deviceLabel.font = [UIFont systemFontOfSize:11];
	deviceLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1];
	deviceLabel.textAlignment = NSTextAlignmentCenter;

	// ===== Spinner =====
	UIActivityIndicatorView* spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
	spinner.hidesWhenStopped = YES;
	self.spinner = spinner;
	[btn addSubview:spinner];

	// ===== 布局（用 frame + autoresizing，转屏/键盘安全） =====
	CGFloat cardTop = screenH / 2.0 - 150;
	titleLabel.frame = CGRectMake(0, cardTop - 80, screenW, 40);
	subtitleLabel.frame = CGRectMake(0, cardTop - 36, screenW, 24);
	card.center = CGPointMake(screenW / 2.0, screenH / 2.0 - 20);
	versionLabel.frame = CGRectMake(0, screenH - 60, screenW, 18);
	deviceLabel.frame = CGRectMake(20, screenH - 38, screenW - 40, 18);
	spinner.center = CGPointMake(btn.bounds.size.width / 2.0, btn.bounds.size.height / 2.0);

	[overlay addSubview:titleLabel];
	[overlay addSubview:subtitleLabel];
	[overlay addSubview:card];
	[overlay addSubview:versionLabel];
	[overlay addSubview:deviceLabel];

	self.activationOverlay = overlay;
	[self.view addSubview:overlay];

	// 键盘：点背景收起
	UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_overlayDismissKeyboard)];
	[overlay addGestureRecognizer:tap];

	// 首次弹出自动聚焦
	[tf becomeFirstResponder];
}

- (void)_overlayDismissKeyboard
{
	[self.view endEditing:YES];
}

- (void)textFieldChanged
{
	self.errorLabel.hidden = YES;
}

- (BOOL)textFieldShouldReturn:(UITextField*)textField
{
	[self verifyButtonPressed];
	return YES;
}

- (void)verifyButtonPressed
{
	if (self.verifying) return;
	NSString* card = [self.cardTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (card.length == 0) {
		self.errorLabel.text = @"请输入卡密";
		self.errorLabel.hidden = NO;
		return;
	}

	self.verifying = YES;
	self.errorLabel.hidden = YES;
	self.verifyButton.enabled = NO;
	self.verifyButton.alpha = 0.7;
	[self.spinner startAnimating];

	[self verifyCard:card completion:^(BOOL success, NSString* message)
	{
		self.verifying = NO;
		self.verifyButton.enabled = YES;
		self.verifyButton.alpha = 1.0;
		[self.spinner stopAnimating];

		if (success)
		{
			// 激活成功：移除激活页
			[UIView animateWithDuration:0.25 animations:^{
				self.activationOverlay.alpha = 0;
			} completion:^(BOOL finished) {
				[self.activationOverlay removeFromSuperview];
				self.activationOverlay = nil;
			}];
			[self showAlertWithTitle:@"激活成功" message:@"卡密验证通过，感谢支持！"];
		}
		else
		{
			self.errorLabel.text = message ?: @"验证失败";
			self.errorLabel.hidden = NO;
		}
	}];
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

// 列表行点击入口：弹出全屏激活页（已激活时可用于换绑）
- (void)kamiRowPressed
{
	[self showActivationOverlay];
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

		// ===== 卡密验证分组 =====
		PSSpecifier* kamiGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		kamiGroupSpecifier.name = @"卡密验证";
		[_specifiers addObject:kamiGroupSpecifier];

		PSSpecifier* kamiSpecifier = [PSSpecifier preferenceSpecifierNamed:[self isActivated] ? @"已激活，点击重新验证" : @"未激活，点击激活"
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
