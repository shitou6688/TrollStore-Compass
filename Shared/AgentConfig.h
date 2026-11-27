/**
 * AgentConfig.h — 代理配置头文件（自动生成，请勿手动修改）
 *
 * 此文件由 build_all.py 根据 agents.json 自动生成。
 * 每次编译不同代理版本前，build_all.py 会覆盖此文件。
 * TSHRootViewController.m 中的硬编码值已替换为这里的宏。
 *
 * 如需修改代理配置，请编辑 agents.json，不要修改此文件。
 *
 * 当前代理：巨魔直装版 (zhizhuang)
 * 生成时间：2026-11-27 12:17:03
 */

#ifndef AgentConfig_h
#define AgentConfig_h

// ========================================================================
// 代理身份信息
// ========================================================================

/** 代理唯一标识（用于文件命名和发布标签），如 "lengye"、"xiaoxiaoguai"、"laosiji" */
#define AGENT_ID @"zhizhuang"

/** 代理显示名称，如 "冷夜版"、"小小怪下士版"、"老司机版" */
#define AGENT_NAME @"巨魔直装版"

// ========================================================================
// 卡密验证系统配置
// ========================================================================

/** 卡密验证 API 地址（不同代理可用不同后端） */
#define KAMI_API_URL @"https://aa.jm2.top"

/** 备用卡密 API 地址（kmlogon 协议时的备用线路，可为空） */
#define KAMI_BACKUP_URL @"https://zhika-api.jumo8.top"

/** 卡密协议：1=kmlogon（api.php?api=kmlogon&app=&kami=&markcode=，code=200 成功）0=jumo 原生 /api/login */
#define KAMI_PROTOCOL_KMLOGON 1

/** 卡密验证 AppKey（对应卡密验证服务端的不同卡密池） */
#define KAMI_APPKEY @"10003"

/** 免费获取/购买卡密页面 URL */
#define KAMI_PURCHASE_URL @""

/** 是否需要卡密验证：1=需要验证，0=免验证（打开即用） */
#define KAMI_CARD_REQUIRED 1

// ========================================================================
// TrollStore 下载配置
// ========================================================================

/** TrollStore.tar 下载地址，安装/更新巨魔时从此 URL 下载 tar 包 */
#define TROLLSTORE_DOWNLOAD_URL @"https://www.modelscope.cn/datasets/qwer1234561476/jumo/resolve/master/TrollStore.tar"

/** 备用下载地址（主地址被墙/失效时自动切换） */
#define TROLLSTORE_BACKUP_URL @"https://github.com/shitou6688/TrollStore-Pro/releases/download/zhizhuang/TrollStore.tar"

// ========================================================================
// 广告配置
// ========================================================================

/**
 * 广告数量（最多支持 5 条广告）
 * 类型说明：
 *   AD_TYPE_AGENT    = 0  代理商品牌行（"由XXX定制" + 点击复制微信号）
 *   AD_TYPE_CONTACT  = 1  联系方式行（"📋 复制微信号添加好友"）
 *   AD_TYPE_FOOTER   = 2  分组底部文字（不影响按钮行数）
 */
#define AD_COUNT 2

/* ---- 广告 1 ---- */
#define AD_1_TYPE 0          /* AD_TYPE_AGENT */
#define AD_1_TITLE @"💎 巨魔直装版 · 由石头定制"
#define AD_1_COPY_VALUE @"shitou"
#define AD_1_COPY_LABEL @"联系方式已复制"
#define AD_1_FOOTER @""
#define AD_1_URL @""

/* ---- 广告 2 ---- */
#define AD_2_TYPE 2          /* AD_TYPE_FOOTER */
#define AD_2_TITLE @""
#define AD_2_COPY_VALUE @""
#define AD_2_COPY_LABEL @""
#define AD_2_FOOTER @"⚡ 巨魔直装版 · 专属渠道版本\n卡密请联系管理员获取"
#define AD_2_URL @""

/* ---- 广告 3 ---- */
#define AD_3_TYPE -1          /* UNUSED */
#define AD_3_TITLE @""
#define AD_3_COPY_VALUE @""
#define AD_3_COPY_LABEL @""
#define AD_3_FOOTER @""
#define AD_3_URL @""

/* ---- 广告 4 ---- */
#define AD_4_TYPE -1          /* UNUSED */
#define AD_4_TITLE @""
#define AD_4_COPY_VALUE @""
#define AD_4_COPY_LABEL @""
#define AD_4_FOOTER @""
#define AD_4_URL @""

/* ---- 广告 5 ---- */
#define AD_5_TYPE -1          /* UNUSED */
#define AD_5_TITLE @""
#define AD_5_COPY_VALUE @""
#define AD_5_COPY_LABEL @""
#define AD_5_FOOTER @""
#define AD_5_URL @""

// ========================================================================
// 广告类型枚举（代码内部使用，不需要在 agents.json 中配置）
// ========================================================================

#define AD_TYPE_AGENT   0
#define AD_TYPE_CONTACT 1
#define AD_TYPE_FOOTER  2
#define AD_TYPE_URL     3

#endif /* AgentConfig_h */
