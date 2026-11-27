/**
 * RemoteConfig.m — 远程配置管理实现
 *
 * 三级 fallback：远程值 → NSUserDefaults 缓存 → AgentConfig.h 编译时宏
 */

#import "RemoteConfig.h"
#import "AgentConfig.h"

// NSUserDefaults 缓存 key 前缀
#define RC_PREFIX @"rc_"
#define RC_KEY_DOWNLOAD_URL   RC_PREFIX @"trollstore_download_url"
#define RC_KEY_LATEST_VERSION RC_PREFIX @"latest_version"
#define RC_KEY_FORCE_UPDATE   RC_PREFIX @"force_update"
#define RC_KEY_PURCHASE_URL   RC_PREFIX @"kami_purchase_url"
#define RC_KEY_CARD_REQUIRED  RC_PREFIX @"card_required"
#define RC_KEY_ADS            RC_PREFIX @"ads"
#define RC_KEY_FORCE_MSG      RC_PREFIX @"force_update_message"
#define RC_KEY_APPKEY         RC_PREFIX @"kami_appkey"
#define RC_KEY_CARD_SET       RC_PREFIX @"card_required_set"
#define RC_KEY_DISPLAY_NAME   RC_PREFIX @"display_name"
#define RC_KEY_FREE_TITLE     RC_PREFIX @"free_version_title"
#define RC_KEY_FREE_FOOTER    RC_PREFIX @"free_version_footer"
#define RC_KEY_VERIFIED_TITLE RC_PREFIX @"verified_title"
#define RC_KEY_ACTION_BUTTONS RC_PREFIX @"action_buttons"

@interface RemoteConfig ()
@property (nonatomic, copy) NSString* remoteDownloadUrl;
@property (nonatomic, copy) NSString* remoteLatestVersion;
@property (nonatomic) BOOL remoteForceUpdate;
@property (nonatomic, copy) NSString* remotePurchaseUrl;
@property (nonatomic) BOOL remoteCardRequired;
@property (nonatomic, strong) NSArray* remoteAds;
@property (nonatomic, copy) NSString* remoteForceUpdateMessage;
@property (nonatomic, copy) NSString* remoteAppkey;
@property (nonatomic) BOOL hasCardRequiredConfig;
@property (nonatomic, copy) NSString* remoteDisplayName;
@property (nonatomic, copy) NSString* remoteFreeVersionTitle;
@property (nonatomic, copy) NSString* remoteFreeVersionFooter;
@property (nonatomic, copy) NSString* remoteVerifiedTitle;
@property (nonatomic, strong) NSArray* remoteActionButtons;
@end

@implementation RemoteConfig

+ (instancetype)sharedInstance
{
	static RemoteConfig* instance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		instance = [[RemoteConfig alloc] init];
	});
	return instance;
}

- (instancetype)init
{
	self = [super init];
	if (self) {
		[self loadCachedConfig];
	}
	return self;
}

#pragma mark - 从 API 更新

- (void)updateFromAPI:(NSDictionary*)config
{
	if (!config || ![config isKindOfClass:[NSDictionary class]]) return;

	NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];

	// trollstore_download_url
	if (config[@"trollstore_download_url"]) {
		_remoteDownloadUrl = config[@"trollstore_download_url"];
		[ud setObject:_remoteDownloadUrl forKey:RC_KEY_DOWNLOAD_URL];
	}

	// latest_version
	if (config[@"latest_version"]) {
		_remoteLatestVersion = config[@"latest_version"];
		[ud setObject:_remoteLatestVersion forKey:RC_KEY_LATEST_VERSION];
	} else {
		_remoteLatestVersion = nil;
		[ud removeObjectForKey:RC_KEY_LATEST_VERSION];
	}

	// force_update
	if (config[@"force_update"] != nil) {
		_remoteForceUpdate = [config[@"force_update"] boolValue];
		[ud setBool:_remoteForceUpdate forKey:RC_KEY_FORCE_UPDATE];
	}

	// kami_purchase_url（保留兼容，但 UI 已改用 action_buttons）
	if (config[@"kami_purchase_url"]) {
		_remotePurchaseUrl = config[@"kami_purchase_url"];
		[ud setObject:_remotePurchaseUrl forKey:RC_KEY_PURCHASE_URL];
	}

	// card_required
	if (config[@"card_required"] != nil) {
		_remoteCardRequired = [config[@"card_required"] boolValue];
		_hasCardRequiredConfig = YES;
		[ud setBool:_remoteCardRequired forKey:RC_KEY_CARD_REQUIRED];
		[ud setBool:YES forKey:RC_KEY_CARD_SET];
	}

	// kami_appkey
	if (config[@"kami_appkey"] && [config[@"kami_appkey"] length] > 0) {
		_remoteAppkey = config[@"kami_appkey"];
		[ud setObject:_remoteAppkey forKey:RC_KEY_APPKEY];
	}

	// ads
	if (config[@"ads"]) {
		_remoteAds = config[@"ads"];
		NSData* adsData = [NSJSONSerialization dataWithJSONObject:_remoteAds options:0 error:nil];
		if (adsData) {
			[ud setObject:adsData forKey:RC_KEY_ADS];
		}
	}

	// force_update_message
	if (config[@"force_update_message"]) {
		_remoteForceUpdateMessage = config[@"force_update_message"];
		[ud setObject:_remoteForceUpdateMessage forKey:RC_KEY_FORCE_MSG];
	} else {
		_remoteForceUpdateMessage = nil;
		[ud removeObjectForKey:RC_KEY_FORCE_MSG];
	}

	// display_name
	if (config[@"display_name"] && [config[@"display_name"] length] > 0) {
		_remoteDisplayName = config[@"display_name"];
		[ud setObject:_remoteDisplayName forKey:RC_KEY_DISPLAY_NAME];
	} else {
		_remoteDisplayName = nil;
		[ud removeObjectForKey:RC_KEY_DISPLAY_NAME];
	}

	// free_version_title
	if (config[@"free_version_title"] && [config[@"free_version_title"] length] > 0) {
		_remoteFreeVersionTitle = config[@"free_version_title"];
		[ud setObject:_remoteFreeVersionTitle forKey:RC_KEY_FREE_TITLE];
	} else {
		_remoteFreeVersionTitle = nil;
		[ud removeObjectForKey:RC_KEY_FREE_TITLE];
	}

	// free_version_footer
	if (config[@"free_version_footer"] && [config[@"free_version_footer"] length] > 0) {
		_remoteFreeVersionFooter = config[@"free_version_footer"];
		[ud setObject:_remoteFreeVersionFooter forKey:RC_KEY_FREE_FOOTER];
	} else {
		_remoteFreeVersionFooter = nil;
		[ud removeObjectForKey:RC_KEY_FREE_FOOTER];
	}

	// verified_title
	if (config[@"verified_title"] && [config[@"verified_title"] length] > 0) {
		_remoteVerifiedTitle = config[@"verified_title"];
		[ud setObject:_remoteVerifiedTitle forKey:RC_KEY_VERIFIED_TITLE];
	} else {
		_remoteVerifiedTitle = nil;
		[ud removeObjectForKey:RC_KEY_VERIFIED_TITLE];
	}

	// action_buttons（操作按钮数组，每个元素含 title + url）
	if (config[@"action_buttons"]) {
		id abVal = config[@"action_buttons"];
		if ([abVal isKindOfClass:[NSArray class]] && [(NSArray*)abVal count] > 0) {
			_remoteActionButtons = abVal;
			NSData* abData = [NSJSONSerialization dataWithJSONObject:_remoteActionButtons options:0 error:nil];
			if (abData) {
				[ud setObject:abData forKey:RC_KEY_ACTION_BUTTONS];
			}
		} else {
			_remoteActionButtons = nil;
			[ud removeObjectForKey:RC_KEY_ACTION_BUTTONS];
		}
	} else {
		_remoteActionButtons = nil;
		[ud removeObjectForKey:RC_KEY_ACTION_BUTTONS];
	}

	[ud synchronize];

	NSLog(@"[RemoteConfig] updated from API: version=%@, force=%d, url=%@", _remoteLatestVersion, _remoteForceUpdate, _remoteDownloadUrl);
}

#pragma mark - 从缓存恢复

- (void)loadCachedConfig
{
	NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];

	_remoteDownloadUrl = [ud stringForKey:RC_KEY_DOWNLOAD_URL];
	_remoteLatestVersion = [ud stringForKey:RC_KEY_LATEST_VERSION];
	_remoteForceUpdate = [ud boolForKey:RC_KEY_FORCE_UPDATE];
	_remotePurchaseUrl = [ud stringForKey:RC_KEY_PURCHASE_URL];
	_hasCardRequiredConfig = [ud boolForKey:RC_KEY_CARD_SET];
	_remoteCardRequired = [ud boolForKey:RC_KEY_CARD_REQUIRED];
	_remoteAppkey = [ud stringForKey:RC_KEY_APPKEY];

	NSData* adsData = [ud dataForKey:RC_KEY_ADS];
	if (adsData) {
		_remoteAds = [NSJSONSerialization JSONObjectWithData:adsData options:0 error:nil];
	}

	_remoteForceUpdateMessage = [ud stringForKey:RC_KEY_FORCE_MSG];

	_remoteDisplayName = [ud stringForKey:RC_KEY_DISPLAY_NAME];
	_remoteFreeVersionTitle = [ud stringForKey:RC_KEY_FREE_TITLE];
	_remoteFreeVersionFooter = [ud stringForKey:RC_KEY_FREE_FOOTER];
	_remoteVerifiedTitle = [ud stringForKey:RC_KEY_VERIFIED_TITLE];

	NSData* abData = [ud dataForKey:RC_KEY_ACTION_BUTTONS];
	if (abData) {
		_remoteActionButtons = [NSJSONSerialization JSONObjectWithData:abData options:0 error:nil];
	}

	NSLog(@"[RemoteConfig] loaded cache: version=%@, url=%@", _remoteLatestVersion, _remoteDownloadUrl);
}

#pragma mark - 三级 Fallback 取值

- (NSString*)trollstoreDownloadUrl
{
	if (_remoteDownloadUrl.length > 0) return _remoteDownloadUrl;
	return TROLLSTORE_DOWNLOAD_URL;
}

- (NSString*)latestVersion
{
	return _remoteLatestVersion;
}

- (BOOL)forceUpdate
{
	return _remoteForceUpdate;
}

- (NSString*)kamiPurchaseUrl
{
	if (_remotePurchaseUrl.length > 0) return _remotePurchaseUrl;
	return KAMI_PURCHASE_URL;
}

- (BOOL)cardRequired
{
	if (_hasCardRequiredConfig) {
		return _remoteCardRequired;
	}
	return KAMI_CARD_REQUIRED;
}

- (NSString*)kamiAppkey
{
	if (_remoteAppkey.length > 0) return _remoteAppkey;
	return KAMI_APPKEY;
}

- (NSArray*)ads
{
	if (_remoteAds && [_remoteAds isKindOfClass:[NSArray class]] && _remoteAds.count > 0) {
		return _remoteAds;
	}
	return nil;
}

- (NSString*)forceUpdateMessage
{
	return _remoteForceUpdateMessage;
}

- (NSString*)displayName
{
	if (_remoteDisplayName.length > 0) return _remoteDisplayName;
	return AGENT_NAME;
}

- (NSString*)freeVersionTitle
{
	if (_remoteFreeVersionTitle.length > 0) return _remoteFreeVersionTitle;
	return @"✅ 免验证版";
}

- (NSString*)freeVersionFooter
{
	if (_remoteFreeVersionFooter.length > 0) return _remoteFreeVersionFooter;
	return [NSString stringWithFormat:@"🎉 %@ · 无需卡密验证", [self displayName]];
}

- (NSString*)verifiedTitle
{
	if (_remoteVerifiedTitle.length > 0) return _remoteVerifiedTitle;
	return @"✅ 卡密已激活";
}

- (NSArray*)actionButtons
{
	if (_remoteActionButtons && [_remoteActionButtons isKindOfClass:[NSArray class]] && _remoteActionButtons.count > 0) {
		return _remoteActionButtons;
	}
	return nil;
}

@end
