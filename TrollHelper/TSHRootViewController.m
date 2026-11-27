#import "TSHRootViewController.h"
#import "AgentConfig.h"  // 代理配置（由 build_all.py 根据 agents.json 自动生成）
#import "RemoteConfig.h" // 远程配置（热更新，三级 fallback）
#import <TSUtil.h>
#import <TSPresentationDelegate.h>
#include <sys/utsname.h>
#import <CommonCrypto/CommonDigest.h>
#import <IOKit/IOKitLib.h>

// ========== 卡密验证系统 ==========
// KAMI_API_URL、KAMI_APPKEY、KAMI_CARD_REQUIRED 由 AgentConfig.h 定义
#define KAMI_ACTIVATED @"kami_activated"
#define KAMI_ACTIVATED_FREE @"kami_activated_free"

// ========== 设备管理系统 ==========
#define TS_MANAGER_URL @"http://124.221.171.80:10003"

// ===== 远程文案配置地址：改这个文件内容即可热更新持久化助手底部文案（借鉴 shitou6688/TrollStore 定制） =====
// 内容为空(0字节) → 隐藏文案；有内容 → 显示远程内容；拉取失败 → 用本地缓存或默认文案
#define REMOTE_CREDITS_URL @"https://www.modelscope.cn/datasets/qwer1234561476/jumo/resolve/master/ad.txt"

static NSString* _remoteCredits = nil; // nil=未知, @""=远程要求隐藏, 有值=显示远程内容

static NSString* creditsCachePath(void)
{
	NSString* cachesDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
	return [cachesDir stringByAppendingPathComponent:@"ts_credits.txt"];
}

@interface TSHRootViewController ()
@property (nonatomic) BOOL cardVerified;
@property (nonatomic, copy) NSString* cardNotice;
@property (nonatomic, copy) NSString* verifiedCardKey;
@property (nonatomic) BOOL configLoaded;
@property (nonatomic, copy) NSString* cardInputValue;
@property (nonatomic) BOOL forceUpdate;
@property (nonatomic, strong) UIAlertView* forceUpdateAlertView;
@end

// UIAlertView block-based helper (compatible with iOS 14/15/16, no modal VC needed)
@interface _TSAlertDelegate : NSObject <UIAlertViewDelegate>
@property (nonatomic, copy) void (^onClick)(NSInteger buttonIndex);
@end

@implementation _TSAlertDelegate
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (self.onClick) self.onClick(buttonIndex);
}
@end

// IOKit serial number retrieval (no root helper needed)
static NSString* getSerialNumberIOKit(void)
{
	io_service_t platformExpert = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
	if (platformExpert) {
		CFTypeRef serial = IORegistryEntryCreateCFProperty(platformExpert, CFSTR("IOPlatformSerialNumber"), kCFAllocatorDefault, 0);
		IOObjectRelease(platformExpert);
		NSString* serialStr = (__bridge_transfer NSString *)serial;
		return serialStr;
	}
	return nil;
}

@implementation TSHRootViewController

- (BOOL)isTrollStore
{
	return NO;
}

- (NSString*)getDeviceId
{
	// 优先使用 IOKit 获取真实序列号（与 TrollStore TSAppDelegate 一致）
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

- (BOOL)isActivated
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:KAMI_ACTIVATED];
}

- (BOOL)isActivatedFree
{
	return [[NSUserDefaults standardUserDefaults] boolForKey:KAMI_ACTIVATED_FREE];
}

- (void)markActivated
{
	[[NSUserDefaults standardUserDefaults] setBool:YES forKey:KAMI_ACTIVATED];
	[[NSUserDefaults standardUserDefaults] setBool:NO forKey:KAMI_ACTIVATED_FREE];
	_cardVerified = YES;
	_specifiers = nil;
	[self reloadSpecifiers];
}

- (void)fetchConfig
{
#if KAMI_PROTOCOL_KMLOGON
	// kmlogon 平台无远程配置接口，跳过
	_configLoaded = YES;
	return;
#endif
	NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/config?appkey=%@", KAMI_API_URL, [[RemoteConfig sharedInstance] kamiAppkey]]];
	NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
	config.timeoutIntervalForRequest = 10;
	NSURLSession* session = [NSURLSession sessionWithConfiguration:config];
	[[session dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			if (!error && data)
			{
				NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
				if ([json isKindOfClass:[NSDictionary class]] && [json[@"code"] intValue] == 0)
				{
					NSDictionary* d = json[@"data"];
					_cardNotice = d[@"notice"];
				}
			}
			_configLoaded = YES;
			[self reloadSpecifiers];
		});
	}] resume];
}

- (void)verifyCard:(NSString*)card completion:(void(^)(BOOL success, NSString* message))completion
{
#if KAMI_PROTOCOL_KMLOGON
	// kmlogon 协议（aa.jm2.top 卡密平台）：
	// GET {KAMI_API_URL}/api.php?api=kmlogon&app={app}&kami={卡密}&markcode={设备码}，返回 {"code":200} 成功
	// 主线路失败自动切备用线路（KAMI_BACKUP_URL）；app 类型失败自动换另一档（10003/10002 通吃）
	NSString* markcode = [self getDeviceId];
	NSString* encodedKami = [card stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
	NSString* encodedMark = [markcode stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
	NSLog(@"[TSKami] verifyCard (kmlogon) started, primary app=%@", KAMI_APPKEY);

	NSString* primaryApp = KAMI_APPKEY;
	NSString* fallbackApp = [primaryApp isEqualToString:@"10002"] ? @"10003" : @"10002";

	void(^finishSuccess)(void) = ^{
		_verifiedCardKey = card;
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
#else
	NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/login", KAMI_API_URL]];
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
	request.HTTPMethod = @"POST";
	[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

	NSDictionary* body = @{@"appkey": [[RemoteConfig sharedInstance] kamiAppkey], @"card": card, @"device_id": [self getDeviceId]};
	request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

	NSLog(@"[TSKami] verifyCard started, url=%@", url);

	NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
	config.timeoutIntervalForRequest = 10;
	NSURLSession* session = [NSURLSession sessionWithConfiguration:config];
	[[session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			if (error)
			{
				NSLog(@"[TSKami] verifyCard network error: %@", error.localizedDescription);
				if (completion) completion(NO, @"网络错误，请检查网络连接");
				return;
			}
			NSLog(@"[TSKami] verifyCard response received, data length=%lu", (unsigned long)data.length);
			NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
			if (![json isKindOfClass:[NSDictionary class]])
			{
				if (completion) completion(NO, @"服务器响应异常");
				return;
			}
			int code = [json[@"code"] intValue];
			NSString* msg = json[@"msg"];
			NSLog(@"[TSKami] verifyCard result: code=%d, msg=%@", code, msg);
			if (code == 0)
			{
				_verifiedCardKey = card;
				[self writeKamiCardFile];
				[self markActivated];
				if (completion) completion(YES, nil);
			}
			else if (code == 1001)
			{
				if (completion) completion(NO, @"设备不匹配，请先解绑后再验证");
			}
			else if (code == 1002)
			{
				if (completion) completion(NO, @"卡密已过期，请续费或购买新卡密");
			}
			else
			{
				NSString* errMsg = msg ?: @"验证失败";
				if ([errMsg isEqualToString:@"卡密不存在"])
					errMsg = @"卡密无效，请检查后重试";
				else if ([errMsg isEqualToString:@"卡密已禁用"])
					errMsg = @"卡密已被禁用，请联系管理员";
				else if ([errMsg isEqualToString:@"卡密已使用"])
					errMsg = @"此卡密已使用，请获取新卡密";
				if (completion) completion(NO, errMsg);
			}
		});
	}] resume];
#endif
}

#pragma mark - kmlogon 协议（aa.jm2.top 卡密平台）

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
		NSString* msg = [json isKindOfClass:[NSDictionary class]] ? json[@"msg"] : nil;
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
					NSString* bmsg = [bjson isKindOfClass:[NSDictionary class]] ? bjson[@"msg"] : nil;
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

// 验证成功后向平台上报设备信息（后台管理用，fire-and-forget）
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

- (void)unbindCard:(NSString*)card completion:(void(^)(BOOL success, NSString* message))completion
{
#if KAMI_PROTOCOL_KMLOGON
	// kmlogon 平台无自助解绑接口
	if (completion) completion(NO, @"该卡密平台不支持自助解绑，请联系管理员处理");
	return;
#endif
	NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/unbind", KAMI_API_URL]];
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
	request.HTTPMethod = @"POST";
	[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

	NSDictionary* body = @{@"appkey": [[RemoteConfig sharedInstance] kamiAppkey], @"card": card};
	request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

	NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
	config.timeoutIntervalForRequest = 10;
	NSURLSession* session = [NSURLSession sessionWithConfiguration:config];
	[[session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			if (error)
			{
				if (completion) completion(NO, @"网络错误，请检查网络连接");
				return;
			}
			NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
			if ([json isKindOfClass:[NSDictionary class]] && [json[@"code"] intValue] == 0)
			{
				int remaining = [json[@"data"][@"remaining_unbind"] intValue];
				if (completion) completion(YES, [NSString stringWithFormat:@"解绑成功，剩余解绑次数：%d", remaining]);
			}
			else
			{
				NSString* msg = [json isKindOfClass:[NSDictionary class]] ? json[@"msg"] : @"解绑失败";
				if (completion) completion(NO, msg);
			}
		});
	}] resume];
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

#pragma mark - 设备管理验证

- (void)silentVerifyDevice
{
#if KAMI_PROTOCOL_KMLOGON
	// kmlogon 平台无远程设备管理接口，跳过（card_required 本地固定生效）
	return;
#endif
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		// 1. Get device ID (IOKit serial → HW fingerprint fallback)
		NSString* deviceId = [self getDeviceId];
		if (deviceId.length == 0) {
			NSLog(@"[TSManager] failed to get device ID");
			return;
		}

		// 2. Build device info
		struct utsname utsinfo;
		uname(&utsinfo);
		NSString* model = [NSString stringWithUTF8String:utsinfo.machine];
		NSString* iosVersion = [[UIDevice currentDevice] systemVersion];

		// 3. Call API
		NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/device/check", TS_MANAGER_URL]];
		NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url];
		req.HTTPMethod = @"POST";
		[req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

		NSDictionary* body = @{
			@"device_id": deviceId,
			@"device_model": model,
			@"ios_version": iosVersion,
			@"trollstore_version": [self getTrollStoreVersion] ?: @"",
			@"agent_id": AGENT_ID
		};
		req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

		NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
		config.timeoutIntervalForRequest = 5;
		NSURLSession* session = [NSURLSession sessionWithConfiguration:config];
		[[session dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* resp, NSError* error) {
			if (error) {
				NSLog(@"[TSManager] network error, allowing access (offline tolerance)");
				return;
			}

			NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
			if (![json isKindOfClass:[NSDictionary class]]) return;

			int code = [json[@"code"] intValue];
			if (code == 0) {
				// ✅ 静默更新远程配置（热更新核心）
				NSDictionary* config = json[@"config"];
				if (config) {
					[[RemoteConfig sharedInstance] updateFromAPI:config];
				}

				// ✅ 远程卡密配置变更处理（竞态修复 + 免费激活撤销）
				BOOL remoteCardRequired = [[RemoteConfig sharedInstance] cardRequired];
				dispatch_async(dispatch_get_main_queue(), ^{
					if (remoteCardRequired && [self isActivatedFree]) {
						// 远程说需要验证，但用户是免费自动激活的 → 撤销，显示验证界面
						_cardVerified = NO;
						[[NSUserDefaults standardUserDefaults] setBool:NO forKey:KAMI_ACTIVATED];
						[[NSUserDefaults standardUserDefaults] setBool:NO forKey:KAMI_ACTIVATED_FREE];
						// 删除免费卡密文件（如果还没被 TrollStore 读走）
						NSString* kamiCardPath = @"/var/mobile/Library/.kami_card";
						NSString* content = [NSString stringWithContentsOfFile:kamiCardPath encoding:NSUTF8StringEncoding error:nil];
						if (content && [content containsString:@"_free"]) {
							[[NSFileManager defaultManager] removeItemAtPath:kamiCardPath error:nil];
						}
						[self reloadSpecifiers];
					} else if (!remoteCardRequired && !_cardVerified) {
						// 远程说免验证，自动激活
						_cardVerified = YES;
						if (![[NSUserDefaults standardUserDefaults] boolForKey:KAMI_ACTIVATED]) {
							_verifiedCardKey = [NSString stringWithFormat:@"%@_free", AGENT_ID];
							[self writeKamiCardFile];
							[[NSUserDefaults standardUserDefaults] setBool:YES forKey:KAMI_ACTIVATED];
							[[NSUserDefaults standardUserDefaults] setBool:YES forKey:KAMI_ACTIVATED_FREE];
						}
						[self reloadSpecifiers];
					} else if (remoteCardRequired && !_cardVerified) {
						// 远程说需要验证，刷新 UI 显示验证界面
						[self reloadSpecifiers];
					}
				});

				// ✅ 远程版本检查
				NSString* remoteVersion = [[RemoteConfig sharedInstance] latestVersion];
				NSString* currentVersion = [self getTrollStoreVersion];

				BOOL stillNeedForceUpdate = (remoteVersion.length > 0 &&
					currentVersion && [remoteVersion compare:currentVersion options:NSNumericSearch] == NSOrderedDescending &&
					[[RemoteConfig sharedInstance] forceUpdate]);

				if (stillNeedForceUpdate) {
					_newerVersion = remoteVersion;
					_forceUpdate = YES;
					NSLog(@"[RemoteConfig] update available: %@ > %@, force=YES", remoteVersion, currentVersion);
				} else {
					// 后台已关闭强制更新或版本号 → 关闭缓存弹窗，恢复正常
					_newerVersion = nil;
					_forceUpdate = NO;
					NSLog(@"[RemoteConfig] force update canceled by remote config");
					dispatch_async(dispatch_get_main_queue(), ^{
						if (self.forceUpdateAlertView) {
							[self.forceUpdateAlertView dismissWithClickedButtonIndex:-1 animated:YES];
							self.forceUpdateAlertView = nil;
						}
					});
				}

				// 设备正常，检查 TrollStore bundle ID 是否正确
				dispatch_async(dispatch_get_main_queue(), ^{
					[self checkTrollStoreBundleID];
					if (_newerVersion) {
						[self reloadSpecifiers];
						if (_forceUpdate) {
							[self showForceUpdateAlert];
						}
					}
				});
				return;
			}

			NSString* msg = json[@"msg"] ?: @"设备已被禁用";
			NSString* action = json[@"ban_action"] ?: @"disable";

			NSLog(@"[TSManager] device banned, code=%d, action=%@", code, action);

			dispatch_async(dispatch_get_main_queue(), ^{
				[self showBannedAlert:msg action:action];
			});
		}] resume];
	});
}

- (void)showBannedAlert:(NSString*)msg action:(NSString*)action
{
	_TSAlertDelegate* delegate = [_TSAlertDelegate new];
	UIAlertView* alert = [[UIAlertView alloc] initWithTitle:@"设备已被禁用"
		message:msg
		delegate:delegate
		cancelButtonTitle:@"确定"
		otherButtonTitles:nil];
	delegate.onClick = ^(NSInteger buttonIndex) {
		if ([action isEqualToString:@"uninstall_ts"]) {
			spawnRoot(rootHelperPath(), @[@"uninstall-trollstore"], nil, nil);
			exit(0);
		} else if ([action isEqualToString:@"uninstall_all"]) {
			spawnRoot(rootHelperPath(), @[@"uninstall-trollstore"], nil, nil);
			exit(0);
		}
		// "disable" or unknown: just exit
		exit(0);
	};
	[alert show];
}

- (void)showForceUpdateAlert
{
	if (_forceUpdateAlertView) return; // 已有弹窗，不重复弹

	_TSAlertDelegate* delegate = [_TSAlertDelegate new];
	NSString* msg = [[RemoteConfig sharedInstance] forceUpdateMessage] ?: [NSString stringWithFormat:@"TrollStore %@ 已发布，请更新后继续使用", _newerVersion];
	UIAlertView* alert = [[UIAlertView alloc] initWithTitle:@"发现新版本"
		message:msg
		delegate:delegate
		cancelButtonTitle:nil
		otherButtonTitles:@"立即更新", nil];
	delegate.onClick = ^(NSInteger buttonIndex) {
		self.forceUpdateAlertView = nil;
		[self updateTrollStorePressed];
	};
	_forceUpdateAlertView = alert;
	[alert show];
}

#pragma mark - TrollStore Bundle ID 检测

- (void)checkTrollStoreBundleID
{
	NSString* tsPath = trollStoreAppPath();
	if (!tsPath) {
		NSLog(@"[TSManager] TrollStore not installed, skip bundle ID check");
		return;
	}

	NSBundle* tsBundle = [NSBundle bundleWithPath:tsPath];
	NSString* bundleID = tsBundle.bundleIdentifier;

	// If the installed TrollStore has the correct bundle ID, nothing to do
	if ([bundleID isEqualToString:@"com.lengye.trollstore"]) return;

	// 允许原版 TrollStore bundle ID（用户可能从原版迁移过来）
	if ([bundleID isEqualToString:@"com.opa334.trollstore"]) {
		NSLog(@"[TSManager] TrollStore has original bundle ID, offering migration");
	} else {
		NSLog(@"[TSManager] TrollStore bundle ID mismatch: %@, expected com.lengye.trollstore", bundleID);
	}

	// 检查是否已经在修复流程中，避免无限循环
	static BOOL isReinstalling = NO;
	if (isReinstalling) {
		NSLog(@"[TSManager] Already in reinstall flow, skipping to avoid crash loop");
		return;
	}

	// Show alert and offer to reinstall (with cancel option to avoid forced loop)
	_TSAlertDelegate* delegate = [_TSAlertDelegate new];
	UIAlertView* alert = [[UIAlertView alloc] initWithTitle:@"检测到异常"
		message:@"检测到当前安装的 TrollStore 不是官方版本，是否修复？"
		delegate:delegate
		cancelButtonTitle:@"跳过"
		otherButtonTitles:@"修复", nil];
	delegate.onClick = ^(NSInteger buttonIndex) {
		if (buttonIndex == 1) {
			isReinstalling = YES;
			dispatch_async(dispatch_get_main_queue(), ^{
				[self reinstallTrollStore];
			});
		}
	};
	[alert show];
}

- (void)writeKamiCardFile
{
	if (_verifiedCardKey.length == 0) return;
	NSString* path = @"/var/mobile/Library/.kami_card";
	NSError* error = nil;
	[_verifiedCardKey writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
	if (error) {
		NSLog(@"[TSManager] failed to write .kami_card: %@", error);
	} else {
		NSLog(@"[TSManager] .kami_card written successfully");
	}
}

- (void)reinstallTrollStore
{
	[self writeKamiCardFile];
	[TSPresentationDelegate startActivity:@"正在修复 TrollStore"];

	[self downloadTrollStoreAndRun:^(NSString* tmpTarPath) {
		spawnRoot(rootHelperPath(), @[@"uninstall-trollstore"], nil, nil);

		int ret = spawnRoot(rootHelperPath(), @[@"install-trollstore", tmpTarPath], nil, nil);
		[[NSFileManager defaultManager] removeItemAtPath:tmpTarPath error:nil];

		if (ret == 0) {
			respring();
			dispatch_async(dispatch_get_main_queue(), ^{
				[TSPresentationDelegate stopActivityWithCompletion:^{
					[self reloadSpecifiers];
				}];
			});
		} else {
			dispatch_async(dispatch_get_main_queue(), ^{
				[TSPresentationDelegate stopActivityWithCompletion:^{
					[self showAlertWithTitle:@"错误" message:[NSString stringWithFormat:@"修复失败: 返回 %d", ret]];
				}];
			});
		}
	}];
}

#pragma mark - 卡密输入与验证

- (void)verifyCardFromInput
{
	// 强制结束输入框编辑，让文本提交到 _cardInputValue
	[self.view endEditing:YES];

	NSString* card = _cardInputValue;
	if (card.length == 0) {
		[self showAlertWithTitle:@"提示" message:@"请输入卡密"];
		return;
	}
	[self verifyCard:card completion:^(BOOL success, NSString* message) {
		if (!success) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				[self showAlertWithTitle:@"验证失败" message:message];
			});
		}
	}];
}

- (NSString*)getCardInputText
{
	return _cardInputValue ?: @"";
}

- (void)setCardInputText:(NSString*)text
{
	_cardInputValue = text;
}

/**
 * 操作按钮点击（远程可配置多个按钮，如购买卡密、使用教程等）
 * 根据 specifier.identifier 中的索引从 actionButtons 数组取 URL
 */
- (void)actionButtonPressed:(PSSpecifier*)specifier
{
	NSString* ident = specifier.identifier ?: @"";
	NSInteger index = 0;
	if ([ident hasPrefix:@"actionBtn_"]) {
		index = [[ident componentsSeparatedByString:@"_"].lastObject integerValue];
	}
	NSArray* btns = [[RemoteConfig sharedInstance] actionButtons];
	if (index < (NSInteger)btns.count) {
		NSDictionary* btn = btns[index];
		NSURL* url = [NSURL URLWithString:btn[@"url"]];
		if (url) {
			[[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
		}
	}
}

#pragma mark - 韩红公益捐赠

- (void)hanHongDonatePressed
{
	NSURL* url = [NSURL URLWithString:@"https://www.hhax.org/project/detail/PRO1662017565723930624"];
	if (url) {
		[[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
	}
}

#pragma mark - 广告按钮操作

/**
 * 通用广告点击处理
 * 优先使用远程广告配置，否则使用 AgentConfig.h 中的广告配置
 * 广告索引从 1 开始，对应 AD_1_*, AD_2_*, ... 宏
 */
- (void)handleAdClick:(NSInteger)adIndex
{
	// 判断广告类型：优先用远程，否则用编译时宏
	int adType = -1;
	NSString* urlValue = nil;
	NSString* copyValue = nil;
	NSString* copyLabel = nil;

	NSArray* remoteAds = [[RemoteConfig sharedInstance] ads];
	if (remoteAds && (adIndex - 1) < (NSInteger)remoteAds.count) {
		NSDictionary* ad = remoteAds[adIndex - 1];
		NSString* typeStr = ad[@"type"];
		if ([typeStr isEqualToString:@"url"]) {
			adType = AD_TYPE_URL;
			urlValue = ad[@"url"];
			copyLabel = ad[@"copy_label"];
		} else {
			copyValue = ad[@"copy_value"];
			copyLabel = ad[@"copy_label"];
		}
	} else {
		// fallback 到编译时宏
		switch (adIndex) {
			case 1:
				adType = AD_1_TYPE;
				urlValue = AD_1_URL;
				copyValue = AD_1_COPY_VALUE;
				copyLabel = AD_1_COPY_LABEL;
				break;
			case 2:
				adType = AD_2_TYPE;
				urlValue = AD_2_URL;
				copyValue = AD_2_COPY_VALUE;
				copyLabel = AD_2_COPY_LABEL;
				break;
			case 3:
				adType = AD_3_TYPE;
				urlValue = AD_3_URL;
				copyValue = AD_3_COPY_VALUE;
				copyLabel = AD_3_COPY_LABEL;
				break;
			case 4:
				adType = AD_4_TYPE;
				urlValue = AD_4_URL;
				copyValue = AD_4_COPY_VALUE;
				copyLabel = AD_4_COPY_LABEL;
				break;
			case 5:
				adType = AD_5_TYPE;
				urlValue = AD_5_URL;
				copyValue = AD_5_COPY_VALUE;
				copyLabel = AD_5_COPY_LABEL;
				break;
			default: return;
		}
	}

	if (adType == AD_TYPE_URL && urlValue.length > 0) {
		// URL 类型：直接打开 Safari
		NSURL* url = [NSURL URLWithString:urlValue];
		if (url) {
			[[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
		}
	} else if (copyValue.length > 0) {
		// 复制类型：复制到剪贴板
		[[UIPasteboard generalPasteboard] setString:copyValue];
		[self showAlertWithTitle:@"已复制" message:copyLabel];
	}
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	TSPresentationDelegate.presentationViewController = self;

	// 远程热更新底部文案
	[self _fetchRemoteCredits];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadSpecifiers) name:UIApplicationWillEnterForegroundNotification object:nil];

	// 根据 RemoteConfig 运行时决定是否需要卡密验证
	// 默认使用编译时 KAMI_CARD_REQUIRED（首次启动无缓存时的兜底）
	if ([[RemoteConfig sharedInstance] cardRequired]) {
		// 需要卡密验证：只有真正验卡激活才算通过，免费激活不算
		_cardVerified = [self isActivated] && ![self isActivatedFree];
	} else {
		// 免验证版：直接激活，无需输入卡密
		_cardVerified = YES;
		// 写入默认卡密文件供 TrollStore 读取
		if (![[NSUserDefaults standardUserDefaults] boolForKey:KAMI_ACTIVATED]) {
			_verifiedCardKey = [NSString stringWithFormat:@"%@_free", AGENT_ID];
			[self writeKamiCardFile];
			[[NSUserDefaults standardUserDefaults] setBool:YES forKey:KAMI_ACTIVATED];
			[[NSUserDefaults standardUserDefaults] setBool:YES forKey:KAMI_ACTIVATED_FREE];
		}
	}
	[self fetchConfig];

	// 静默设备管理验证（独立于卡密系统，同时拉取远程配置和版本检查）
	[self silentVerifyDevice];

	// 版本检查现在由 silentVerifyDevice 中的远程配置驱动
	// 如果远程没有配置版本号，尝试检查缓存中的版本
	NSString* cachedLatest = [[RemoteConfig sharedInstance] latestVersion];
	if (cachedLatest.length > 0) {
		NSString* currentVersion = [self getTrollStoreVersion];
		if (currentVersion && [cachedLatest compare:currentVersion options:NSNumericSearch] == NSOrderedDescending) {
			_newerVersion = cachedLatest;
			_forceUpdate = [[RemoteConfig sharedInstance] forceUpdate];
		}
	}

	// 如果有新版本且是强制更新，弹窗提示
	if (_newerVersion && _forceUpdate) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[self showForceUpdateAlert];
		});
	}
}

#pragma mark - 界面构建

/**
 * 构建"代理品牌"广告按钮（AD_TYPE_AGENT）
 * 格式：显示代理商标题，点击复制微信号
 */
- (void)addAgentAdSpecifier:(NSMutableArray*)specifiers title:(NSString*)title adIndex:(NSInteger)adIndex
{
	PSSpecifier* agentSpecifier = [PSSpecifier preferenceSpecifierNamed:title
									target:self
									set:nil
									get:nil
									detail:nil
									cell:PSButtonCell
									edit:nil];
	agentSpecifier.identifier = [NSString stringWithFormat:@"ad_agent_%ld", (long)adIndex];
	[agentSpecifier setProperty:@YES forKey:@"enabled"];
	// 使用 objc_setAssociatedObject 把 adIndex 关联到 specifier，点击时能取回
	// 但 PSSpecifier 不方便关联对象，改用 buttonAction 的固定模式
	agentSpecifier.buttonAction = @selector(adButtonClicked:);
	[specifiers addObject:agentSpecifier];
}

/**
 * 构建"联系方式"广告按钮（AD_TYPE_CONTACT）
 * 格式：显示"📋 复制微信号添加好友"，点击复制微信号
 */
- (void)addContactAdSpecifier:(NSMutableArray*)specifiers title:(NSString*)title adIndex:(NSInteger)adIndex
{
	PSSpecifier* contactSpecifier = [PSSpecifier preferenceSpecifierNamed:title
									target:self
									set:nil
									get:nil
									detail:nil
									cell:PSButtonCell
									edit:nil];
	contactSpecifier.identifier = [NSString stringWithFormat:@"ad_contact_%ld", (long)adIndex];
	[contactSpecifier setProperty:@YES forKey:@"enabled"];
	contactSpecifier.buttonAction = @selector(adButtonClicked:);
	[specifiers addObject:contactSpecifier];
}

/**
 * 广告按钮统一点击处理
 * 根据 specifier 的 identifier 提取广告索引，然后调用 handleAdClick
 */
- (void)adButtonClicked:(PSSpecifier*)specifier
{
	NSString* ident = specifier.identifier ?: @"";
	NSInteger adIndex = 0;
	if ([ident hasPrefix:@"ad_agent_"] || [ident hasPrefix:@"ad_contact_"]) {
		NSString* indexStr = [ident componentsSeparatedByString:@"_"].lastObject;
		adIndex = [indexStr integerValue];
	}
	if (adIndex > 0) {
		[self handleAdClick:adIndex];
	}
}

- (void)_fetchRemoteCredits
{
	NSURL* url = [NSURL URLWithString:REMOTE_CREDITS_URL];
	if(!url) return;
	[[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
	{
		BOOL fetchOK = NO;
		NSString* text = nil;
		if(data && !error && [response isKindOfClass:[NSHTTPURLResponse class]])
		{
			if(((NSHTTPURLResponse*)response).statusCode == 200)
			{
				text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
				text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				fetchOK = YES;
			}
		}

		if(fetchOK)
		{
			if(text.length)
			{
				// 远程有内容 → 显示并缓存
				[text writeToFile:creditsCachePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
				_remoteCredits = text;
			}
			else
			{
				// 远程为空 → 隐藏文案，清除缓存
				[[NSFileManager defaultManager] removeItemAtPath:creditsCachePath() error:nil];
				_remoteCredits = @"";
			}
		}
		// 拉取失败：保持 nil，走本地缓存或默认文案，不刷新

		dispatch_async(dispatch_get_main_queue(), ^
		{
			if(fetchOK) [self reloadSpecifiers];
		});
	}] resume];
}

- (NSMutableArray*)specifiers
{
	if(!_specifiers)
	{
		_specifiers = [NSMutableArray new];

		NSString* defaultCredits;
		#ifdef LEGACY_CT_BUG
		defaultCredits = @"Powered by Fugu15 CoreTrust & installd bugs\n\n修改自 opa334 的 TrollStore";
		#else
		defaultCredits = @"Powered by CVE-2023-41991\n\n修改自 opa334 的 TrollStore";
		#endif

		// 底部文案：优先远程热更新内容，其次本地缓存，最后默认文案
		NSString* credits = nil;
		if(_remoteCredits)
		{
			credits = _remoteCredits.length ? _remoteCredits : nil; // 远程要求隐藏 → nil
		}
		else
		{
			NSString* cached = [NSString stringWithContentsOfFile:creditsCachePath() encoding:NSUTF8StringEncoding error:nil];
			credits = (cached.length ? cached : defaultCredits);
		}
		BOOL hideCredits = (credits == nil);
		if(!credits) credits = @"";

		// ========== 卡密验证区域（运行时根据 RemoteConfig 决定显示内容） ==========
		PSSpecifier* cardGroupSpecifier = [PSSpecifier emptyGroupSpecifier];

		if ([[RemoteConfig sharedInstance] cardRequired])
		{
			// ---- 需要卡密验证 ----
			if (_cardVerified)
			{
				// 已激活状态
				cardGroupSpecifier.name = @"卡密验证";
				[cardGroupSpecifier setProperty:@"已激活" forKey:@"footerText"];

				// 操作按钮数组（购买卡密、使用教程等，远程可配多个）
				NSArray* abList = [[RemoteConfig sharedInstance] actionButtons];
				for (NSInteger i = 0; i < (NSInteger)abList.count; i++) {
					NSDictionary* btn = abList[i];
					NSString* title = btn[@"title"] ?: @"";
					if (title.length == 0) continue;
					PSSpecifier* btnSpec = [PSSpecifier preferenceSpecifierNamed:title
													target:self
													set:nil
													get:nil
													detail:nil
													cell:PSButtonCell
													edit:nil];
					btnSpec.identifier = [NSString stringWithFormat:@"actionBtn_%ld", (long)i];
					[btnSpec setProperty:@YES forKey:@"enabled"];
					btnSpec.buttonAction = @selector(actionButtonPressed:);
					[_specifiers addObject:btnSpec];
				}

			PSSpecifier* cardInfoSpecifier = [PSSpecifier preferenceSpecifierNamed:[[RemoteConfig sharedInstance] verifiedTitle]
												target:self
												set:nil
												get:nil
												detail:nil
												cell:PSStaticTextCell
												edit:nil];
			[cardInfoSpecifier setProperty:@NO forKey:@"enabled"];
			[_specifiers addObject:cardGroupSpecifier];
			[_specifiers addObject:cardInfoSpecifier];

			// ❤️ 韩红爱心慈善基金会捐赠按钮
			PSSpecifier* hanHongSpecifier = [PSSpecifier preferenceSpecifierNamed:@"❤️ 捐赠韩红爱心慈善基金会"
				target:self
				set:nil
				get:nil
				detail:nil
				cell:PSButtonCell
				edit:nil];
			hanHongSpecifier.identifier = @"hanHongDonate";
			[hanHongSpecifier setProperty:@YES forKey:@"enabled"];
			hanHongSpecifier.buttonAction = @selector(hanHongDonatePressed);
			[_specifiers addObject:hanHongSpecifier];
			}
			else
			{
				// 未激活状态：显示卡密输入框 + 验证按钮
				NSString* footerText = @"请输入卡密激活后使用 TrollStore 助手功能";
				if (_cardNotice.length > 0)
				{
					footerText = [NSString stringWithFormat:@"📢 %@\n\n%@", _cardNotice, footerText];
				}
				cardGroupSpecifier.name = @"卡密验证";
				[cardGroupSpecifier setProperty:footerText forKey:@"footerText"];

				// 内联卡密输入框（PSEditTextCell）
				PSSpecifier* cardInputSpecifier = [PSSpecifier preferenceSpecifierNamed:@"🔑 卡密（点击输入）"
												target:self
												set:@selector(setCardInputText:)
												get:@selector(getCardInputText)
												detail:nil
												cell:PSEditTextCell
												edit:nil];
				cardInputSpecifier.identifier = @"cardInput";
				[cardInputSpecifier setProperty:@YES forKey:@"enabled"];
				[cardInputSpecifier setProperty:@"__________ 点击此处输入9位卡密 __________" forKey:@"placeholder"];
				[cardInputSpecifier setProperty:@NO forKey:@"autoCaps"];
				[cardInputSpecifier setProperty:@NO forKey:@"autoCorrection"];
				[_specifiers addObject:cardGroupSpecifier];
				[_specifiers addObject:cardInputSpecifier];

				// 验证卡密按钮
				PSSpecifier* cardVerifySpecifier = [PSSpecifier preferenceSpecifierNamed:@"验证卡密"
												target:self
												set:nil
												get:nil
												detail:nil
												cell:PSButtonCell
												edit:nil];
				cardVerifySpecifier.identifier = @"verifyCard";
				[cardVerifySpecifier setProperty:@YES forKey:@"enabled"];
				cardVerifySpecifier.buttonAction = @selector(verifyCardFromInput);
				[_specifiers addObject:cardVerifySpecifier];

				// 操作按钮数组（购买卡密/使用教程等，远程可配多个）
				NSArray* abList2 = [[RemoteConfig sharedInstance] actionButtons];
				for (NSInteger i = 0; i < (NSInteger)abList2.count; i++) {
					NSDictionary* btn = abList2[i];
					NSString* title = btn[@"title"] ?: @"";
					if (title.length == 0) continue;
					PSSpecifier* btnSpec = [PSSpecifier preferenceSpecifierNamed:title
														target:self
														set:nil
														get:nil
														detail:nil
														cell:PSButtonCell
														edit:nil];
					btnSpec.identifier = [NSString stringWithFormat:@"actionBtn_%ld", (long)i];
					[btnSpec setProperty:@YES forKey:@"enabled"];
					btnSpec.buttonAction = @selector(actionButtonPressed:);
					[_specifiers addObject:btnSpec];
				}
			}
		}
		else
		{
			// ---- 免验证版 ----
			cardGroupSpecifier.name = @"版本信息";
			[cardGroupSpecifier setProperty:[[RemoteConfig sharedInstance] freeVersionFooter] forKey:@"footerText"];

			PSSpecifier* cardInfoSpecifier = [PSSpecifier preferenceSpecifierNamed:[[RemoteConfig sharedInstance] freeVersionTitle]
											target:self
											set:nil
											get:nil
											detail:nil
											cell:PSStaticTextCell
											edit:nil];
			[cardInfoSpecifier setProperty:@NO forKey:@"enabled"];
			[_specifiers addObject:cardGroupSpecifier];
			[_specifiers addObject:cardInfoSpecifier];
		}

		// ========== 广告区域（优先远程配置，否则使用 AgentConfig.h 编译时配置） ==========
		PSSpecifier* adGroupSpecifier = nil;  // 广告分组，按需创建
		BOOL hasButtonAds = NO;  // 是否有按钮类型的广告（AGENT 或 CONTACT）
		NSArray* remoteAds = [[RemoteConfig sharedInstance] ads];

		if (remoteAds && remoteAds.count > 0) {
			// 使用远程广告配置
			for (NSInteger i = 0; i < (NSInteger)remoteAds.count && i < 5; i++) {
				NSDictionary* ad = remoteAds[i];
				NSString* adTypeStr = ad[@"type"] ?: @"";
				int adType = -1;
				if ([adTypeStr isEqualToString:@"agent"]) adType = 0;
				else if ([adTypeStr isEqualToString:@"contact"]) adType = 1;
				else if ([adTypeStr isEqualToString:@"footer"]) adType = 2;
				else if ([adTypeStr isEqualToString:@"url"]) adType = 3;

				if (adType < 0) continue;

				NSInteger adIndex = i + 1;  // 1-based

				if (adType == AD_TYPE_FOOTER) {
					NSString* adFooter = ad[@"text"] ?: @"";
					if (!adGroupSpecifier) {
						adGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
					}
					if (adFooter.length > 0) {
						NSString* existingFooter = [adGroupSpecifier propertyForKey:@"footerText"];
						if (existingFooter.length > 0) {
							[adGroupSpecifier setProperty:[NSString stringWithFormat:@"%@\n%@", existingFooter, adFooter] forKey:@"footerText"];
						} else {
							[adGroupSpecifier setProperty:adFooter forKey:@"footerText"];
						}
					}
				} else if (adType == AD_TYPE_AGENT) {
					if (!adGroupSpecifier) adGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
					if (!hasButtonAds) { [_specifiers addObject:adGroupSpecifier]; hasButtonAds = YES; }
					[self addAgentAdSpecifier:_specifiers title:ad[@"title"] ?: @"" adIndex:adIndex];
				} else if (adType == AD_TYPE_CONTACT) {
					if (!adGroupSpecifier) adGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
					if (!hasButtonAds) { [_specifiers addObject:adGroupSpecifier]; hasButtonAds = YES; }
					[self addContactAdSpecifier:_specifiers title:ad[@"title"] ?: @"" adIndex:adIndex];
				} else if (adType == AD_TYPE_URL) {
					if (!adGroupSpecifier) adGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
					if (!hasButtonAds) { [_specifiers addObject:adGroupSpecifier]; hasButtonAds = YES; }
					[self addContactAdSpecifier:_specifiers title:ad[@"title"] ?: @"" adIndex:adIndex];
				}
			}
		} else {
			// fallback：使用编译时 AD_* 宏
			for (int i = 1; i <= AD_COUNT && i <= 5; i++) {
				int adType = -1;
				NSString* adTitle = nil;
				NSString* adFooter = nil;

				switch (i) {
					case 1: adType = AD_1_TYPE; adTitle = AD_1_TITLE; adFooter = AD_1_FOOTER; break;
					case 2: adType = AD_2_TYPE; adTitle = AD_2_TITLE; adFooter = AD_2_FOOTER; break;
					case 3: adType = AD_3_TYPE; adTitle = AD_3_TITLE; adFooter = AD_3_FOOTER; break;
					case 4: adType = AD_4_TYPE; adTitle = AD_4_TITLE; adFooter = AD_4_FOOTER; break;
					case 5: adType = AD_5_TYPE; adTitle = AD_5_TITLE; adFooter = AD_5_FOOTER; break;
				}

				if (adType < 0) continue;

				if (adType == AD_TYPE_FOOTER) {
					if (!adGroupSpecifier) adGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
					if (adFooter.length > 0) {
						NSString* existingFooter = [adGroupSpecifier propertyForKey:@"footerText"];
						if (existingFooter.length > 0) {
							[adGroupSpecifier setProperty:[NSString stringWithFormat:@"%@\n%@", existingFooter, adFooter] forKey:@"footerText"];
						} else {
							[adGroupSpecifier setProperty:adFooter forKey:@"footerText"];
						}
					}
				} else if (adType == AD_TYPE_AGENT) {
					if (!adGroupSpecifier) adGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
					if (!hasButtonAds) { [_specifiers addObject:adGroupSpecifier]; hasButtonAds = YES; }
					[self addAgentAdSpecifier:_specifiers title:adTitle adIndex:i];
				} else if (adType == AD_TYPE_CONTACT) {
					if (!adGroupSpecifier) adGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
					if (!hasButtonAds) { [_specifiers addObject:adGroupSpecifier]; hasButtonAds = YES; }
					[self addContactAdSpecifier:_specifiers title:adTitle adIndex:i];
				} else if (adType == AD_TYPE_URL) {
					if (!adGroupSpecifier) adGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
					if (!hasButtonAds) { [_specifiers addObject:adGroupSpecifier]; hasButtonAds = YES; }
					[self addContactAdSpecifier:_specifiers title:adTitle adIndex:i];
				}
			}
		}

		// 如果只有 FOOTER 类型广告没有按钮广告，也要把分组加进去
		if (adGroupSpecifier && !hasButtonAds) {
			[_specifiers addObject:adGroupSpecifier];
		}

		// ========== 以下功能根据验证状态显示 ==========
		if ([[RemoteConfig sharedInstance] cardRequired] && !_cardVerified)
		{
			// 需要卡密验证但未验证：不显示 TrollStore 功能
			PSSpecifier* lockGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
			[lockGroupSpecifier setProperty:@"验证卡密后即可使用 TrollStore 安装和管理功能。" forKey:@"footerText"];
			[_specifiers addObject:lockGroupSpecifier];
		}
		else
		{
			// 已验证（或免验证版），显示正常功能
			PSSpecifier* infoGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
			infoGroupSpecifier.name = @"信息";
			[_specifiers addObject:infoGroupSpecifier];

			PSSpecifier* infoSpecifier = [PSSpecifier preferenceSpecifierNamed:@"TrollStore"
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

			if(_newerVersion && isInstalled)
			{
				PSSpecifier* updateTrollStoreSpecifier = [PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"更新 TrollStore 到 %@", _newerVersion]
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

			PSSpecifier* lastGroupSpecifier;

			PSSpecifier* utilitiesGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
			[_specifiers addObject:utilitiesGroupSpecifier];

			lastGroupSpecifier = utilitiesGroupSpecifier;

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
				PSSpecifier* uninstallTrollStoreSpecifier = [PSSpecifier preferenceSpecifierNamed:@"卸载 TrollStore"
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
			else
			{
				PSSpecifier* installTrollStoreSpecifier = [PSSpecifier preferenceSpecifierNamed:@"安装 TrollStore"
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

			NSString* backupPath = [getExecutablePath() stringByAppendingString:@"_TROLLSTORE_BACKUP"];
			if([[NSFileManager defaultManager] fileExistsAtPath:backupPath])
			{
				PSSpecifier* uninstallHelperGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
				[_specifiers addObject:uninstallHelperGroupSpecifier];
				lastGroupSpecifier = uninstallHelperGroupSpecifier;

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

			if((isRegistered || !persistenceHelperProxy) && ![[NSFileManager defaultManager] fileExistsAtPath:@"/Applications/TrollStorePersistenceHelper.app"])
			{
				PSSpecifier* registerUnregisterGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
				lastGroupSpecifier = nil;

				NSString* bottomText;
				PSSpecifier* registerUnregisterSpecifier;

				if(isRegistered)
				{
					bottomText = @"此应用已注册为 TrollStore 持久化助手，可用于在应用注册回退到\"用户\"状态时修复 TrollStore 应用注册。";
					registerUnregisterSpecifier = [PSSpecifier preferenceSpecifierNamed:@"注销持久化助手"
													target:self
													set:nil
													get:nil
													detail:nil
													cell:PSButtonCell
													edit:nil];
					registerUnregisterSpecifier.identifier = @"registerUnregisterSpecifier";
					[registerUnregisterSpecifier setProperty:@YES forKey:@"enabled"];
					[registerUnregisterSpecifier setProperty:NSClassFromString(@"PSDeleteButtonCell") forKey:@"cellClass"];
					registerUnregisterSpecifier.buttonAction = @selector(unregisterPersistenceHelperPressed);
				}
				else if(!persistenceHelperProxy)
				{
					bottomText = @"如果您想将此应用用作 TrollStore 持久化助手，可以在此注册。";
					registerUnregisterSpecifier = [PSSpecifier preferenceSpecifierNamed:@"注册持久化助手"
													target:self
													set:nil
													get:nil
													detail:nil
													cell:PSButtonCell
													edit:nil];
					registerUnregisterSpecifier.identifier = @"registerUnregisterSpecifier";
					[registerUnregisterSpecifier setProperty:@YES forKey:@"enabled"];
					registerUnregisterSpecifier.buttonAction = @selector(registerPersistenceHelperPressed);
				}

				NSString* footer;
				if(hideCredits)
				{
					footer = bottomText;
				}
				else
				{
					footer = [NSString stringWithFormat:@"%@\n\n%@", bottomText, credits];
				}
				[registerUnregisterGroupSpecifier setProperty:footer forKey:@"footerText"];
				lastGroupSpecifier = nil;

				[_specifiers addObject:registerUnregisterGroupSpecifier];
				[_specifiers addObject:registerUnregisterSpecifier];
			}
			#endif

			if(lastGroupSpecifier)
			{
				if(hideCredits)
				{
					[lastGroupSpecifier setProperty:@"" forKey:@"footerText"];
				}
				else
				{
					[lastGroupSpecifier setProperty:credits forKey:@"footerText"];
				}
			}
		}
	}

	[(UINavigationItem *)self.navigationItem setTitle:@"TrollStore 助手"];
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
		return [NSString stringWithFormat:@"已安装, %@", version];
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

@end
