#import "TSHRootViewController.h"
#import "AgentConfig.h"
#import <TSUtil.h>
#import <TSPresentationDelegate.h>
#import "TSManager.h"
#import <CommonCrypto/CommonDigest.h>
#import <IOKit/IOKitLib.h>
#import <Security/Security.h>
#import <sys/utsname.h>
#import <sys/sysctl.h>

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
	NSString* uuid = UIDevice.currentDevice.identifierForVendor ? [UIDevice.currentDevice.identifierForVendor UUIDString] : @"unknown";
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
@property (nonatomic, strong) UIView* activationOverlay; // KamiActivationView
@end

#pragma mark - 激活页视图（毛玻璃 + 白卡片，自适应布局，转屏/键盘不变形）

@interface KamiActivationView : UIView
@property (nonatomic, strong) UIView* contentView;
@property (nonatomic, strong) UIView* iconBadge;
@property (nonatomic, strong) UILabel* titleLabel;
@property (nonatomic, strong) UILabel* subtitleLabel;
@property (nonatomic, strong) UIView* card;
@property (nonatomic, strong) UITextField* cardTextField;
@property (nonatomic, strong) UILabel* errorLabel;
@property (nonatomic, strong) UIButton* verifyButton;
@property (nonatomic, strong) UIActivityIndicatorView* spinner;
@property (nonatomic, strong) UILabel* versionLabel;
@property (nonatomic, strong) UILabel* deviceLabel;
@property (nonatomic, copy) void(^onVerify)(NSString* card);
@property (nonatomic, assign) CGFloat keyboardOffset; // 键盘弹出时整体上移量
@end

@implementation KamiActivationView

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (self)
	{
		// 底层：系统毛玻璃（永远原生渲染，不会拉伸扭曲）
		UIVisualEffectView* blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
		blur.frame = self.bounds;
		blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self addSubview:blur];

		// 淡淡压暗一层，让白色卡片更突出
		UIView* dim = [[UIView alloc] initWithFrame:self.bounds];
		dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		dim.backgroundColor = [UIColor colorWithWhite:0.02 alpha:0.35];
		[self addSubview:dim];

		_contentView = [[UIView alloc] initWithFrame:CGRectZero];
		[self addSubview:_contentView];

		// 应用图标徽章（蓝底 + 白色钥匙）
		_iconBadge = [[UIView alloc] initWithFrame:CGRectZero];
		_iconBadge.backgroundColor = [UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1];
		_iconBadge.layer.cornerRadius = 18;
		_iconBadge.layer.shadowColor = [UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1].CGColor;
		_iconBadge.layer.shadowOffset = CGSizeMake(0, 6);
		_iconBadge.layer.shadowRadius = 14;
		_iconBadge.layer.shadowOpacity = 0.35;
		UIImageView* glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"key.fill"]];
		glyph.tintColor = UIColor.whiteColor;
		glyph.contentMode = UIViewContentModeScaleAspectFit;
		glyph.frame = CGRectInset(_iconBadge.bounds, 20, 20);
		glyph.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[_iconBadge addSubview:glyph];
		[_contentView addSubview:_iconBadge];

		// 标题
		_titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		_titleLabel.text = KAMI_POPUP_TITLE;
		_titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
		_titleLabel.textColor = UIColor.whiteColor;
		_titleLabel.textAlignment = NSTextAlignmentCenter;
		[_contentView addSubview:_titleLabel];

		// 副标题
		_subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		_subtitleLabel.text = KAMI_POPUP_SUBTITLE;
		_subtitleLabel.font = [UIFont systemFontOfSize:14];
		_subtitleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.65];
		_subtitleLabel.textAlignment = NSTextAlignmentCenter;
		[_contentView addSubview:_subtitleLabel];

		// 白色悬浮卡片
		_card = [[UIView alloc] initWithFrame:CGRectZero];
		_card.backgroundColor = UIColor.whiteColor;
		_card.layer.cornerRadius = 20;
		_card.layer.shadowColor = UIColor.blackColor.CGColor;
		_card.layer.shadowOffset = CGSizeMake(0, 8);
		_card.layer.shadowRadius = 20;
		_card.layer.shadowOpacity = 0.18;
		[_contentView addSubview:_card];

		// 输入框（iOS 灰底风格）
		_cardTextField = [[UITextField alloc] initWithFrame:CGRectZero];
		_cardTextField.backgroundColor = [UIColor colorWithRed:0.949 green:0.949 blue:0.969 alpha:1]; // #F2F2F7
		_cardTextField.layer.cornerRadius = 12;
		_cardTextField.textColor = [UIColor colorWithWhite:0.1 alpha:1];
		_cardTextField.font = [UIFont systemFontOfSize:16];
		_cardTextField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:KAMI_POPUP_PLACEHOLDER
			attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.4 alpha:1]}];
		_cardTextField.autocorrectionType = UITextAutocorrectionTypeNo;
		_cardTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
		_cardTextField.keyboardType = UIKeyboardTypeAlphabet;
		_cardTextField.returnKeyType = UIReturnKeyDone;
		_cardTextField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 14)];
		_cardTextField.leftViewMode = UITextFieldViewModeAlways;
		[_card addSubview:_cardTextField];

		// 错误提示
		_errorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		_errorLabel.font = [UIFont systemFontOfSize:13];
		_errorLabel.textColor = [UIColor colorWithRed:0.9 green:0.24 blue:0.24 alpha:1];
		_errorLabel.textAlignment = NSTextAlignmentCenter;
		_errorLabel.numberOfLines = 2;
		_errorLabel.hidden = YES;
		[_card addSubview:_errorLabel];

		// 验证按钮（iOS 系统蓝，实色，无渐变）
		_verifyButton = [UIButton buttonWithType:UIButtonTypeCustom];
		_verifyButton.backgroundColor = [UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1];
		_verifyButton.layer.cornerRadius = 12;
		_verifyButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
		[_verifyButton setTitle:@"验证激活" forState:UIControlStateNormal];
		[_verifyButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
		[_verifyButton addTarget:self action:@selector(_buttonPressed) forControlEvents:UIControlEventTouchUpInside];
		[_card addSubview:_verifyButton];

		// 菊花
		_spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
		_spinner.hidesWhenStopped = YES;
		[_verifyButton addSubview:_spinner];

		// 底部信息
		_versionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		_versionLabel.font = [UIFont systemFontOfSize:11];
		_versionLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
		_versionLabel.textAlignment = NSTextAlignmentCenter;
		[self addSubview:_versionLabel];

		_deviceLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		_deviceLabel.font = [UIFont systemFontOfSize:11];
		_deviceLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
		_deviceLabel.textAlignment = NSTextAlignmentCenter;
		[self addSubview:_deviceLabel];
	}
	return self;
}

- (void)_buttonPressed
{
	NSString* card = [self.cardTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (self.onVerify) self.onVerify(card);
}

- (void)layoutSubviews
{
	[super layoutSubviews];

	CGFloat w = self.bounds.size.width;
	CGFloat h = self.bounds.size.height;
	if (w <= 0 || h <= 0) return;

	CGFloat cardW = MIN(w - 56, 320);
	CGFloat cardH = 210;
	CGFloat centerX = w / 2.0;
	CGFloat left = centerX - cardW / 2.0;

	// 内容整体垂直居中，键盘弹出时按比例上移
	CGFloat contentH = 72 + 14 + 30 + 20 + 20 + cardH;
	CGFloat topY = (h - contentH) / 2.0 - self.keyboardOffset;
	if (topY < 70) topY = 70;

	_iconBadge.frame = CGRectMake(centerX - 36, topY, 72, 72);
	((UIImageView*)_iconBadge.subviews.firstObject).frame = CGRectInset(_iconBadge.bounds, 20, 20);
	_titleLabel.frame = CGRectMake(16, topY + 86, w - 32, 28);
	_subtitleLabel.frame = CGRectMake(16, topY + 118, w - 32, 18);

	CGFloat cardTop = topY + 150;
	_card.frame = CGRectMake(left, cardTop, cardW, cardH);

	CGFloat pad = 16;
	_cardTextField.frame = CGRectMake(pad, pad, cardW - pad * 2, 46);
	_errorLabel.frame = CGRectMake(pad, pad + 52, cardW - pad * 2, 18);
	_verifyButton.frame = CGRectMake(pad, cardH - pad - 48, cardW - pad * 2, 48);
	_spinner.center = CGPointMake(_verifyButton.bounds.size.width / 2.0, _verifyButton.bounds.size.height / 2.0);

	CGFloat bottomSafe = self.safeAreaInsets.bottom;
	_versionLabel.frame = CGRectMake(0, h - 56 - bottomSafe, w, 16);
	_deviceLabel.frame = CGRectMake(16, h - 34 - bottomSafe, w - 32, 16);
}

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

#pragma mark - 全屏激活页（新版：毛玻璃 + 白卡片）

- (void)showActivationOverlay
{
	if (self.activationOverlay.superview) return;

	KamiActivationView* overlay = [[KamiActivationView alloc] initWithFrame:self.view.bounds];
	overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	NSString* devCode = getDeviceCode();
	NSString* shortCode = (devCode.length > 16) ? [[devCode substringToIndex:16] stringByAppendingString:@"…"] : devCode;
	overlay.deviceLabel.text = [NSString stringWithFormat:@"设备码：%@", shortCode];
	overlay.versionLabel.text = [NSString stringWithFormat:@"版本：%@", KAMI_APP_VERSION];
	overlay.cardTextField.delegate = self;
	[overlay.cardTextField addTarget:self action:@selector(textFieldChanged) forControlEvents:UIControlEventEditingChanged];
	__weak typeof(self) weakSelf = self;
	overlay.onVerify = ^(NSString* card)
	{
		[weakSelf _submitCard:card];
	};

	self.activationOverlay = overlay;

	// 弹入动画：淡入 + 卡片弹性放大
	overlay.alpha = 0;
	overlay.contentView.transform = CGAffineTransformMakeScale(0.92, 0.92);
	[self.view addSubview:overlay];
	[UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
		overlay.alpha = 1;
		overlay.contentView.transform = CGAffineTransformIdentity;
	} completion:nil];

	// 键盘监听 + 点背景收起
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
	UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_overlayDismissKeyboard)];
	[overlay addGestureRecognizer:tap];

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[overlay.cardTextField becomeFirstResponder];
	});
}

- (void)_submitCard:(NSString*)card
{
	KamiActivationView* overlay = (KamiActivationView*)self.activationOverlay;
	if (!overlay || overlay.spinner.isAnimating) return;

	card = [card stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (card.length == 0)
	{
		overlay.errorLabel.text = @"请输入卡密";
		overlay.errorLabel.hidden = NO;
		[overlay setNeedsLayout];
		return;
	}

	overlay.errorLabel.hidden = YES;
	overlay.verifyButton.enabled = NO;
	overlay.verifyButton.alpha = 0.6;
	[overlay.spinner startAnimating];

	__weak typeof(self) weakSelf = self;
	[self verifyCard:card completion:^(BOOL success, NSString* message)
	{
		__strong typeof(weakSelf) strongSelf = weakSelf;
		KamiActivationView* ov = (KamiActivationView*)strongSelf.activationOverlay;
		if (!ov) return;

		[ov.spinner stopAnimating];
		ov.verifyButton.enabled = YES;
		ov.verifyButton.alpha = 1.0;

		if (success)
		{
			[[NSNotificationCenter defaultCenter] removeObserver:strongSelf name:UIKeyboardWillChangeFrameNotification object:nil];
			[strongSelf.view endEditing:YES];
			[UIView animateWithDuration:0.25 animations:^{
				ov.alpha = 0;
				ov.contentView.transform = CGAffineTransformMakeScale(0.94, 0.94);
			} completion:^(BOOL finished) {
				[ov removeFromSuperview];
				strongSelf.activationOverlay = nil;
			}];
			[strongSelf showAlertWithTitle:@"激活成功" message:@"卡密验证通过，感谢支持！"];
		}
		else
		{
			ov.errorLabel.text = message ?: @"验证失败";
			ov.errorLabel.hidden = NO;
			// 卡片轻抖一下提示错误
			CABasicAnimation* shake = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
			shake.fromValue = @-8;
			shake.toValue = @8;
			shake.duration = 0.07;
			shake.autoreverses = YES;
			shake.repeatCount = 2;
			[ov.card.layer addAnimation:shake forKey:@"shake"];
		}
	}];
}

- (void)_overlayDismissKeyboard
{
	[self.view endEditing:YES];
}

- (void)_keyboardWillChange:(NSNotification*)note
{
	KamiActivationView* overlay = (KamiActivationView*)self.activationOverlay;
	if (!overlay) return;

	CGRect kbEnd = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
	CGFloat duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
	if (duration <= 0) duration = 0.25;

	// 键盘顶部（窗口坐标 ≈ 全屏视图坐标）
	CGFloat kbTop = self.view.bounds.size.height - kbEnd.size.height;
	CGFloat cardBottom = overlay.card.frame.origin.y + overlay.card.frame.size.height;
	CGFloat offset = 0;
	if (kbTop < self.view.bounds.size.height && cardBottom + 16 > kbTop)
	{
		offset = cardBottom + 16 - kbTop;
	}

	[UIView animateWithDuration:duration animations:^{
		overlay.keyboardOffset = offset;
		[overlay setNeedsLayout];
		[overlay layoutIfNeeded];
	}];
}

- (void)textFieldChanged
{
	KamiActivationView* overlay = (KamiActivationView*)self.activationOverlay;
	if (overlay) overlay.errorLabel.hidden = YES;
}

- (BOOL)textFieldShouldReturn:(UITextField*)textField
{
	NSString* card = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	[self _submitCard:card];
	return YES;
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
