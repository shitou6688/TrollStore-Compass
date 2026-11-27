/**
 * RemoteConfig.h — 远程配置管理（热更新）
 *
 * 优先级：远程 API 下发 → NSUserDefaults 本地缓存 → AgentConfig.h 编译时默认值
 * 用户完全无感，后台静默拉取，网络失败自动 fallback
 */

#ifndef RemoteConfig_h
#define RemoteConfig_h

#import <Foundation/Foundation.h>

@interface RemoteConfig : NSObject

/** 单例 */
+ (instancetype)sharedInstance;

/** 从 API 响应更新配置（silentVerifyDevice 回调中调用） */
- (void)updateFromAPI:(NSDictionary*)config;

/** 从 NSUserDefaults 恢复缓存（App 启动时调用） */
- (void)loadCachedConfig;

// ========================================================================
// 远程配置字段（每个都有三级 fallback）
// ========================================================================

/** TrollStore.tar 下载地址 */
- (NSString*)trollstoreDownloadUrl;

/** 最新版本号（为空则不提示更新） */
- (NSString*)latestVersion;

/** 是否强制更新 */
- (BOOL)forceUpdate;

/** 强制更新弹窗自定义文案（为空则用默认文案） */
- (NSString*)forceUpdateMessage;

/** 卡密购买链接 */
- (NSString*)kamiPurchaseUrl;

/** 是否需要卡密验证（三级 fallback：远程 → 缓存 → 编译时 KAMI_CARD_REQUIRED） */
- (BOOL)cardRequired;

/** 卡密验证 AppKey（三级 fallback：远程 → 缓存 → 编译时 KAMI_APPKEY） */
- (NSString*)kamiAppkey;

/** 广告配置数组（元素为 NSDictionary） */
- (NSArray*)ads;

/** 显示名称（热更新覆盖 AGENT_NAME，留空则用编译时值） */
- (NSString*)displayName;

/** 免验证版标题（如"✅ 免验证版"，留空则用默认） */
- (NSString*)freeVersionTitle;

/** 免验证版底部文案（如"🎉 冷夜免费版·无需卡密验证"，留空则默认拼接 AGENT_NAME） */
- (NSString*)freeVersionFooter;

/** 已激活状态标题（如"✅ 卡密已激活"，留空则用默认） */
- (NSString*)verifiedTitle;

/** 操作按钮数组（元素含 title + url，远程可配多个按钮） */
- (NSArray*)actionButtons;

@end

#endif /* RemoteConfig_h */
