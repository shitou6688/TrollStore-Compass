#import "TSSettingsListController.h"
#import <TSUtil.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSListItemsController.h>
#import <TSPresentationDelegate.h>
@import UIKit;
#import "TSInstallationController.h"
#import "TSSettingsAdvancedListController.h"
#import "TSDonateListController.h"

@interface NSUserDefaults (Private)
- (instancetype)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container;
@end
extern NSUserDefaults* trollStoreUserDefaults(void);


#pragma mark - _TSPersistenceAppSelector (iPad scrollable app picker)

@interface _TSPersistenceAppSelector : UITableViewController
@property (nonatomic, copy) void(^onSelect)(LSApplicationProxy*);
@end


static NSString* localizeAppName(NSString* name) {
    static NSDictionary* nameMap = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        nameMap = @{
            @"AppleTV": @"电视",
            @"Files": @"文件",
            @"Maps": @"地图",
            @"Calendar": @"日历",
            @"Music": @"音乐",
            @"Translate": @"翻译",
            @"VoiceMemos": @"语音备忘录",
            @"Shortcuts": @"快捷指令",
            @"Notes": @"备忘录",
            @"FindMy": @"查找",
            @"Reminders": @"提醒事项",
            @"Clock": @"时钟",
            @"Contacts": @"通讯录",
            @"Stocks": @"股票",
            @"Weather": @"天气",
            @"Compass": @"指南针",
            @"Measure": @"测距仪",
            @"Calculator": @"计算器",
            @"FaceTime": @"FaceTime",
            @"Books": @"图书",
            @"Podcasts": @"播客",
            @"News": @"新闻",
            @"Health": @"健康",
            @"Wallet": @"钱包",
            @"Tips": @"提示",
            @"App Store": @"App Store",
            @"iTunes Store": @"iTunes Store",
            @"Home": @"家庭",
            @"Settings": @"设置",
            @"Photos": @"照片",
            @"Camera": @"相机",
            @"Photo Booth": @"照片亭",
            @"Mail": @"邮件",
            @"Safari": @"Safari浏览器",
            @"Messages": @"信息",
            @"Phone": @"电话",
            @"FaceTime Audio": @"FaceTime音频",
            @"iTunes U": @"iTunes U",
            @" Videos": @"视频",
            @"Freeform": @"无边记",
            @"Journal": @"日志",
            @" magnifier": @"放大器",
        };
    });
    NSString* mapped = nameMap[name];
    return mapped ?: name;
}

@implementation _TSPersistenceAppSelector {
    NSArray<LSApplicationProxy*>* _candidates;
}

- (instancetype)initWithCandidates:(NSArray<LSApplicationProxy*>*)candidates onSelect:(void(^)(LSApplicationProxy*))onSelect {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _candidates = [candidates copy];
        _onSelect = [onSelect copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 44;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return _candidates.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    LSApplicationProxy* app = _candidates[indexPath.row];
    cell.textLabel.text = localizeAppName([app localizedName]);
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    LSApplicationProxy* app = _candidates[indexPath.row];
    if (_onSelect) _onSelect(app);
}

@end

@implementation TSSettingsListController

- (void)viewDidLoad
{
	[super viewDidLoad];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadSpecifiers) name:UIApplicationWillEnterForegroundNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadSpecifiers) name:@"TrollStoreReloadSettingsNotification" object:nil];

#ifndef TROLLSTORE_LITE
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

	//if (@available(iOS 16, *)) {} else {
		fetchLatestLdidVersion(^(NSString* latestVersion)
		{
			NSString* ldidVersionPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ldid.version"];
			NSString* ldidVersion = nil;
			NSData* ldidVersionData = [NSData dataWithContentsOfFile:ldidVersionPath];
			if(ldidVersionData)
			{
				ldidVersion = [[NSString alloc] initWithData:ldidVersionData encoding:NSUTF8StringEncoding];
			}
			
			if(![latestVersion isEqualToString:ldidVersion])
			{
				_newerLdidVersion = latestVersion;
				dispatch_async(dispatch_get_main_queue(), ^
				{
					[self reloadSpecifiers];
				});
			}
		});
	//}

	if (@available(iOS 16, *))
	{
		_devModeEnabled = spawnRoot(rootHelperPath(), @[@"check-dev-mode"], nil, nil) == 0;
	}
	else
	{
		_devModeEnabled = YES;
	}
#endif
	[self reloadSpecifiers];
}

- (NSMutableArray*)specifiers
{
	if(!_specifiers)
	{
		_specifiers = [NSMutableArray new];

#ifndef TROLLSTORE_LITE
		if(_newerVersion)
		{
			PSSpecifier* updateTrollStoreGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
			updateTrollStoreGroupSpecifier.name = @"有可用更新";
			[_specifiers addObject:updateTrollStoreGroupSpecifier];

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

		if(!_devModeEnabled)
		{
			PSSpecifier* enableDevModeGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
			enableDevModeGroupSpecifier.name = @"开发者模式";
			[enableDevModeGroupSpecifier setProperty:@"部分应用需要启用开发者模式才能启动。这需要重启才能生效。" forKey:@"footerText"];
			[_specifiers addObject:enableDevModeGroupSpecifier];

			PSSpecifier* enableDevModeSpecifier = [PSSpecifier preferenceSpecifierNamed:@"启用开发者模式"
										target:self
										set:nil
										get:nil
										detail:nil
										cell:PSButtonCell
										edit:nil];
			enableDevModeSpecifier.identifier = @"enableDevMode";
			[enableDevModeSpecifier setProperty:@YES forKey:@"enabled"];
			enableDevModeSpecifier.buttonAction = @selector(enableDevModePressed);
			[_specifiers addObject:enableDevModeSpecifier];
		}
#endif

		PSSpecifier* utilitiesGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		utilitiesGroupSpecifier.name = @"工具";

		NSString *utilitiesDescription = @"";
#ifdef TROLLSTORE_LITE
		if (shouldRegisterAsUserByDefault()) {
			utilitiesDescription = @"Apps will be registered as User by default since AppSync Unified is installed.\n\n";
		}
		else {
			utilitiesDescription = @"Apps will be registered as System by default since AppSync Unified is not installed. When apps loose their System registration and stop working, press \"Refresh App Registrations\" here to fix them.\n\n";
		}
#endif
		utilitiesDescription = [utilitiesDescription stringByAppendingString:@"如果应用安装后没有立即出现，请点击此处注销，之后应该就能看到了。"];

		[utilitiesGroupSpecifier setProperty:utilitiesDescription forKey:@"footerText"];
		[_specifiers addObject:utilitiesGroupSpecifier];

		PSSpecifier* respringButtonSpecifier = [PSSpecifier preferenceSpecifierNamed:@"注销"
											target:self
											set:nil
											get:nil
											detail:nil
											cell:PSButtonCell
											edit:nil];
		 respringButtonSpecifier.identifier = @"respring";
		[respringButtonSpecifier setProperty:@YES forKey:@"enabled"];
		respringButtonSpecifier.buttonAction = @selector(respringButtonPressed);

		[_specifiers addObject:respringButtonSpecifier];

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

		PSSpecifier* rebuildIconCacheSpecifier = [PSSpecifier preferenceSpecifierNamed:@"重建图标缓存"
											target:self
											set:nil
											get:nil
											detail:nil
											cell:PSButtonCell
											edit:nil];
		 rebuildIconCacheSpecifier.identifier = @"uicache";
		[rebuildIconCacheSpecifier setProperty:@YES forKey:@"enabled"];
		rebuildIconCacheSpecifier.buttonAction = @selector(rebuildIconCachePressed);

		[_specifiers addObject:rebuildIconCacheSpecifier];

		NSArray *inactiveBundlePaths = trollStoreInactiveInstalledAppBundlePaths();
		if (inactiveBundlePaths.count > 0) {
			PSSpecifier* transferAppsSpecifier = [PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"Transfer %zu "OTHER_APP_NAME@" %@", inactiveBundlePaths.count, inactiveBundlePaths.count > 1 ? @"应用" : @"应用"]
											target:self
											set:nil
											get:nil
											detail:nil
											cell:PSButtonCell
											edit:nil];
			transferAppsSpecifier.identifier = @"transferApps";
			[transferAppsSpecifier setProperty:@YES forKey:@"enabled"];
			transferAppsSpecifier.buttonAction = @selector(transferAppsPressed);

			[_specifiers addObject:transferAppsSpecifier];
		}

#ifndef TROLLSTORE_LITE
		//if (@available(iOS 16, *)) { } else {
			NSString* ldidPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ldid"];
			NSString* ldidVersionPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ldid.version"];
			BOOL ldidInstalled = [[NSFileManager defaultManager] fileExistsAtPath:ldidPath];

			NSString* ldidVersion = nil;
			NSData* ldidVersionData = [NSData dataWithContentsOfFile:ldidVersionPath];
			if(ldidVersionData)
			{
				ldidVersion = [[NSString alloc] initWithData:ldidVersionData encoding:NSUTF8StringEncoding];
			}

			PSSpecifier* signingGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
			signingGroupSpecifier.name = @"签名";

			if(ldidInstalled)
			{
				[signingGroupSpecifier setProperty:@"ldid 已安装，允许巨魔商店安装未签名的 IPA 文件。" forKey:@"footerText"];
			}
			else
			{
				[signingGroupSpecifier setProperty:@"为了让巨魔商店能够安装未签名的 IPA，需要使用此按钮安装 ldid。由于许可证问题，它无法直接包含在巨魔商店中。" forKey:@"footerText"];
			}

			[_specifiers addObject:signingGroupSpecifier];

			if(ldidInstalled)
			{
				NSString* installedTitle = @"ldid：已安装";
				if(ldidVersion)
				{
					installedTitle = [NSString stringWithFormat:@"%@ (%@)", installedTitle, ldidVersion];
				}

				PSSpecifier* ldidInstalledSpecifier = [PSSpecifier preferenceSpecifierNamed:installedTitle
												target:self
												set:nil
												get:nil
												detail:nil
												cell:PSStaticTextCell
												edit:nil];
				[ldidInstalledSpecifier setProperty:@NO forKey:@"enabled"];
				ldidInstalledSpecifier.identifier = @"ldidInstalled";
				[_specifiers addObject:ldidInstalledSpecifier];

				if(_newerLdidVersion && ![_newerLdidVersion isEqualToString:ldidVersion])
				{
					NSString* updateTitle = [NSString stringWithFormat:@"更新到 %@", _newerLdidVersion];
					PSSpecifier* ldidUpdateSpecifier = [PSSpecifier preferenceSpecifierNamed:updateTitle
												target:self
												set:nil
												get:nil
												detail:nil
												cell:PSButtonCell
												edit:nil];
					ldidUpdateSpecifier.identifier = @"updateLdid";
					[ldidUpdateSpecifier setProperty:@YES forKey:@"enabled"];
					ldidUpdateSpecifier.buttonAction = @selector(installOrUpdateLdidPressed);
					[_specifiers addObject:ldidUpdateSpecifier];
				}
			}
			else
			{
				PSSpecifier* installLdidSpecifier = [PSSpecifier preferenceSpecifierNamed:@"安装 ldid"
												target:self
												set:nil
												get:nil
												detail:nil
												cell:PSButtonCell
												edit:nil];
				installLdidSpecifier.identifier = @"installLdid";
				[installLdidSpecifier setProperty:@YES forKey:@"enabled"];
				installLdidSpecifier.buttonAction = @selector(installOrUpdateLdidPressed);
				[_specifiers addObject:installLdidSpecifier];
			}
		//}

		PSSpecifier* persistenceGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		persistenceGroupSpecifier.name = @"持久化";
		[_specifiers addObject:persistenceGroupSpecifier];

		if([[NSFileManager defaultManager] fileExistsAtPath:@"/Applications/TrollStorePersistenceHelper.app"])
		{
			[persistenceGroupSpecifier setProperty:@"当 iOS 重建图标缓存时，所有巨魔应用（包括巨魔商店本身）都将还原为\"用户\"状态并消失或无法启动。如果发生这种情况，请使用主屏幕上的巨魔助手来刷新应用注册，使其恢复正常。" forKey:@"footerText"];
			PSSpecifier* installedPersistenceHelperSpecifier = [PSSpecifier preferenceSpecifierNamed:@"助手已安装为独立应用"
											target:self
											set:nil
											get:nil
											detail:nil
											cell:PSStaticTextCell
											edit:nil];
			[installedPersistenceHelperSpecifier setProperty:@NO forKey:@"enabled"];
			installedPersistenceHelperSpecifier.identifier = @"persistenceHelperInstalled";
			[_specifiers addObject:installedPersistenceHelperSpecifier];
		}
		else
		{
			LSApplicationProxy* persistenceApp = findPersistenceHelperApp(PERSISTENCE_HELPER_TYPE_ALL);
			if(persistenceApp)
			{
				NSString* appName = [persistenceApp localizedName];

				[persistenceGroupSpecifier setProperty:[NSString stringWithFormat:@"当 iOS 重建图标缓存时，所有巨魔应用（包括巨魔商店本身）都将还原为\"用户\"状态并消失或无法启动。如果发生这种情况，请使用安装到 %@ 的持久化助手来刷新应用注册，使其恢复正常。", appName] forKey:@"footerText"];
				PSSpecifier* installedPersistenceHelperSpecifier = [PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"助手已安装到 %@", appName]
												target:self
												set:nil
												get:nil
												detail:nil
												cell:PSStaticTextCell
												edit:nil];
				[installedPersistenceHelperSpecifier setProperty:@NO forKey:@"enabled"];
				installedPersistenceHelperSpecifier.identifier = @"persistenceHelperInstalled";
				[_specifiers addObject:installedPersistenceHelperSpecifier];

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
			else
			{
				[persistenceGroupSpecifier setProperty:@"当 iOS 重建图标缓存时，所有巨魔应用（包括巨魔商店本身）都将还原为\"用户\"状态并消失或无法启动。在无根环境中实现持久化的唯一方法是替换系统应用，在此您可以选择一个系统应用，用持久化助手替换它，以便在巨魔相关应用消失或无法启动时刷新其注册信息。" forKey:@"footerText"];

				_installPersistenceHelperSpecifier = [PSSpecifier preferenceSpecifierNamed:@"安装持久化助手"
												target:self
												set:nil
												get:nil
												detail:nil
												cell:PSButtonCell
												edit:nil];
				_installPersistenceHelperSpecifier.identifier = @"installPersistenceHelper";
				[_installPersistenceHelperSpecifier setProperty:@YES forKey:@"enabled"];
				_installPersistenceHelperSpecifier.buttonAction = @selector(installPersistenceHelperPressed);
				[_specifiers addObject:_installPersistenceHelperSpecifier];
			}
		}
#endif

		PSSpecifier* installationSettingsGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		installationSettingsGroupSpecifier.name = @"安全";
		[installationSettingsGroupSpecifier setProperty:@"启用 URL Scheme 后，应用和网站可以通过 apple-magnifier://install?url=<IPA_URL> 触发巨魔商店安装，并通过 apple-magnifier://enable-jit?bundle-id=<BUNDLE_ID> 启用 JIT。" forKey:@"footerText"];

		[_specifiers addObject:installationSettingsGroupSpecifier];

		PSSpecifier* URLSchemeToggle = [PSSpecifier preferenceSpecifierNamed:@"URL Scheme 已启用"
										target:self
										set:@selector(setURLSchemeEnabled:forSpecifier:)
										get:@selector(getURLSchemeEnabledForSpecifier:)
										detail:nil
										cell:PSSwitchCell
										edit:nil];

		[_specifiers addObject:URLSchemeToggle];

		PSSpecifier* installAlertConfigurationSpecifier = [PSSpecifier preferenceSpecifierNamed:@"显示安装确认弹窗"
										target:self
										set:@selector(setPreferenceValue:specifier:)
										get:@selector(readPreferenceValue:)
										detail:nil
										cell:PSLinkListCell
										edit:nil];

		installAlertConfigurationSpecifier.detailControllerClass = [PSListItemsController class];
		[installAlertConfigurationSpecifier setProperty:@"installationConfirmationValues" forKey:@"valuesDataSource"];
        [installAlertConfigurationSpecifier setProperty:@"installationConfirmationNames" forKey:@"titlesDataSource"];
		[installAlertConfigurationSpecifier setProperty:APP_ID forKey:@"defaults"];
		[installAlertConfigurationSpecifier setProperty:@"installAlertConfiguration" forKey:@"key"];
        [_specifiers addObject:installAlertConfigurationSpecifier];

		PSSpecifier* otherGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		[otherGroupSpecifier setProperty:@"" forKey:@"footerText"];
		[_specifiers addObject:otherGroupSpecifier];

		PSSpecifier* advancedLinkSpecifier = [PSSpecifier preferenceSpecifierNamed:@"高级"
										target:self
										set:nil
										get:nil
										detail:nil
										cell:PSLinkListCell
										edit:nil];
		advancedLinkSpecifier.detailControllerClass = [TSSettingsAdvancedListController class];
		[advancedLinkSpecifier setProperty:@YES forKey:@"enabled"];
		[_specifiers addObject:advancedLinkSpecifier];

		PSSpecifier* donateSpecifier = [PSSpecifier preferenceSpecifierNamed:@"捐赠"
										target:self
										set:nil
										get:nil
										detail:nil
										cell:PSLinkListCell
										edit:nil];
		donateSpecifier.detailControllerClass = [TSDonateListController class];
		[donateSpecifier setProperty:@YES forKey:@"enabled"];
		[_specifiers addObject:donateSpecifier];

#ifndef TROLLSTORE_LITE
		// Uninstall TrollStore
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
#endif
		/*PSSpecifier* doTheDashSpecifier = [PSSpecifier preferenceSpecifierNamed:@"执行开发者模式"
										target:self
										set:nil
										get:nil
										detail:nil
										cell:PSButtonCell
										edit:nil];
		doTheDashSpecifier.identifier = @"doTheDash";
		[doTheDashSpecifier setProperty:@YES forKey:@"enabled"];
		uninstallTrollStoreSpecifier.buttonAction = @selector(doTheDashPressed);
		[_specifiers addObject:doTheDashSpecifier];*/
	}

	[(UINavigationItem *)self.navigationItem setTitle:@"设置"];
	return _specifiers;
}

- (NSArray*)installationConfirmationValues
{
	return @[@0, @1, @2];
}

- (NSArray*)installationConfirmationNames
{
	return @[@"始终（推荐）", @"仅在远程 URL 安装时", @"从不（不推荐）"];
}

- (void)respringButtonPressed
{
	respring();
}

- (void)installOrUpdateLdidPressed
{
	[TSInstallationController installLdid];
}

- (void)enableDevModePressed
{
	int ret = spawnRoot(rootHelperPath(), @[@"arm-dev-mode"], nil, nil);

	if (ret == 0) {
		UIAlertController* rebootNotification = [UIAlertController alertControllerWithTitle:@"需要重启"
			message:@"After rebooting, select \"Turn On\" to enable developer mode."
			preferredStyle:UIAlertControllerStyleAlert
		];
		UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
		{
			[self reloadSpecifiers];
		}];
		[rebootNotification addAction:closeAction];

		UIAlertAction* rebootAction = [UIAlertAction actionWithTitle:@"立即重启" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			spawnRoot(rootHelperPath(), @[@"reboot"], nil, nil);
		}];
		[rebootNotification addAction:rebootAction];

		[TSPresentationDelegate presentViewController:rebootNotification animated:YES completion:nil];
	} else {
		UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"错误 %d", ret] message:@"启用开发者模式失败。" preferredStyle:UIAlertControllerStyleAlert];
		UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil];
		[errorAlert addAction:closeAction];

		[TSPresentationDelegate presentViewController:errorAlert animated:YES completion:nil];
	}
}

- (void)installPersistenceHelperPressed
{
	NSMutableArray* appCandidates = [NSMutableArray new];
	[[LSApplicationWorkspace defaultWorkspace] enumerateApplicationsOfType:1 block:^(LSApplicationProxy* appProxy)
	{
		if(appProxy.installed && !appProxy.restricted)
		{
			if([[NSFileManager defaultManager] fileExistsAtPath:[@"/System/Library/AppSignatures" stringByAppendingPathComponent:appProxy.bundleIdentifier]])
			{
				NSURL* trollStoreMarkURL = [appProxy.bundleURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:TS_ACTIVE_MARKER];
				if(![trollStoreMarkURL checkResourceIsReachableAndReturnError:nil])
				{
					[appCandidates addObject:appProxy];
				}
			}
		}
	}];

	if(appCandidates.count == 0)
	{
		UIAlertController* noAppAlert = [UIAlertController alertControllerWithTitle:@"提示" message:@"未找到可用的系统应用。" preferredStyle:UIAlertControllerStyleAlert];
		UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil];
		[noAppAlert addAction:closeAction];
		[TSPresentationDelegate presentViewController:noAppAlert animated:YES completion:nil];
		return;
	}

	if([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad)
	{
		// iPad: use custom UITableViewController in popover for proper scrolling
		_TSPersistenceAppSelector* selector = [[_TSPersistenceAppSelector alloc] initWithCandidates:appCandidates onSelect:^(LSApplicationProxy* selectedApp) {
			[TSPresentationDelegate.presentationViewController dismissViewControllerAnimated:YES completion:^{
				spawnRoot(rootHelperPath(), @[@"install-persistence-helper", selectedApp.bundleIdentifier], nil, nil);
				[self reloadSpecifiers];
			}];
		}];

		CGFloat contentHeight = MIN(appCandidates.count * 44.0 + 44.0, 500.0);
		selector.preferredContentSize = CGSizeMake(300, contentHeight);
		selector.title = @"选择应用";

		UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:selector];
		nav.modalPresentationStyle = UIModalPresentationPopover;

		UIPopoverPresentationController* popover = nav.popoverPresentationController;
		NSIndexPath* indexPath = [self indexPathForSpecifier:_installPersistenceHelperSpecifier];
		UITableView* tableView = [self valueForKey:@"_table"];
		popover.sourceView = tableView;
		popover.sourceRect = [tableView rectForRowAtIndexPath:indexPath];

		[TSPresentationDelegate presentViewController:nav animated:YES completion:nil];
	}
	else
	{
		// iPhone: ActionSheet works fine, supports scrolling natively
		UIAlertController* selectAppAlert = [UIAlertController alertControllerWithTitle:@"选择应用" message:@"选择一个系统应用来安装巨魔持久化助手。该应用的原有功能将不可用，请选择一个不常用的应用。" preferredStyle:UIAlertControllerStyleActionSheet];

		for(LSApplicationProxy* appProxy in appCandidates)
		{
			UIAlertAction* installAction = [UIAlertAction actionWithTitle:localizeAppName([appProxy localizedName]) style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
			{
				spawnRoot(rootHelperPath(), @[@"install-persistence-helper", appProxy.bundleIdentifier], nil, nil);
				[self reloadSpecifiers];
			}];
			[selectAppAlert addAction:installAction];
		}

		UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
		[selectAppAlert addAction:cancelAction];

		[TSPresentationDelegate presentViewController:selectAppAlert animated:YES completion:nil];
	}
}
- (void)transferAppsPressed
{
	UIAlertController *confirmationAlert = [UIAlertController alertControllerWithTitle:@"传输应用" message:[NSString stringWithFormat:@"此选项将传输 %zu 个应用，从 " OTHER_APP_NAME @" 到 " APP_NAME @"。是否继续？", trollStoreInactiveInstalledAppBundlePaths().count] preferredStyle:UIAlertControllerStyleAlert];
	
	UIAlertAction* transferAction = [UIAlertAction actionWithTitle:@"传输" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		[TSPresentationDelegate startActivity:@"正在传输"];
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
		{
			NSString *log;
			int transferRet = spawnRoot(rootHelperPath(), @[@"transfer-apps"], nil, &log);

			dispatch_async(dispatch_get_main_queue(), ^
			{
				[TSPresentationDelegate stopActivityWithCompletion:^
				{
					[self reloadSpecifiers];

					if (transferRet != 0) {
						NSArray *remainingApps = trollStoreInactiveInstalledAppBundlePaths();
						UIAlertController *errorAlert = [UIAlertController alertControllerWithTitle:@"传输失败" message:[NSString stringWithFormat:@"传输 %zu %@ 失败", remainingApps.count, remainingApps.count > 1 ? @"apps" : @"app"] preferredStyle:UIAlertControllerStyleAlert];

						UIAlertAction* copyLogAction = [UIAlertAction actionWithTitle:@"复制调试日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
						{
							UIPasteboard* pasteboard = [UIPasteboard generalPasteboard];
							pasteboard.string = log;
						}];
						[errorAlert addAction:copyLogAction];

						UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil];
						[errorAlert addAction:closeAction];

						[TSPresentationDelegate presentViewController:errorAlert animated:YES completion:nil];
					}
				}];
			});
		});
	}];
	[confirmationAlert addAction:transferAction];

	UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
	[confirmationAlert addAction:cancelAction];

	[TSPresentationDelegate presentViewController:confirmationAlert animated:YES completion:nil];
}

- (id)getURLSchemeEnabledForSpecifier:(PSSpecifier*)specifier
{
	BOOL URLSchemeActive = (BOOL)[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleURLTypes"];
	return @(URLSchemeActive);
}

- (void)setURLSchemeEnabled:(id)value forSpecifier:(PSSpecifier*)specifier
{
	NSNumber* newValue = value;
	NSString* newStateString = [newValue boolValue] ? @"enable" : @"disable";
	spawnRoot(rootHelperPath(), @[@"url-scheme", newStateString], nil, nil);

	UIAlertController* rebuildNoticeAlert = [UIAlertController alertControllerWithTitle:@"URL Scheme 已更改" message:@"为了正确应用 URL Scheme 设置的更改，需要重建图标缓存。" preferredStyle:UIAlertControllerStyleAlert];
	UIAlertAction* rebuildNowAction = [UIAlertAction actionWithTitle:@"立即重建" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		[self rebuildIconCachePressed];
	}];
	[rebuildNoticeAlert addAction:rebuildNowAction];

	UIAlertAction* rebuildLaterAction = [UIAlertAction actionWithTitle:@"稍后重建" style:UIAlertActionStyleCancel handler:nil];
	[rebuildNoticeAlert addAction:rebuildLaterAction];

	[TSPresentationDelegate presentViewController:rebuildNoticeAlert animated:YES completion:nil];
}

- (void)doTheDashPressed
{
	spawnRoot(rootHelperPath(), @[@"dash"], nil, nil);
}

- (void)setPreferenceValue:(NSObject*)value specifier:(PSSpecifier*)specifier
{
	NSUserDefaults* tsDefaults = trollStoreUserDefaults();
	[tsDefaults setObject:value forKey:[specifier propertyForKey:@"key"]];
}

- (NSObject*)readPreferenceValue:(PSSpecifier*)specifier
{
	NSUserDefaults* tsDefaults = trollStoreUserDefaults();
	NSObject* toReturn = [tsDefaults objectForKey:[specifier propertyForKey:@"key"]];
	if(!toReturn)
	{
		toReturn = [specifier propertyForKey:@"default"];
	}
	return toReturn;
}

- (NSMutableArray*)argsForUninstallingTrollStore
{
	NSMutableArray* args = @[@"uninstall-trollstore"].mutableCopy;

	NSNumber* uninstallationMethodToUseNum = [trollStoreUserDefaults() objectForKey:@"uninstallationMethod"];
    int uninstallationMethodToUse = uninstallationMethodToUseNum ? uninstallationMethodToUseNum.intValue : 0;
    if(uninstallationMethodToUse == 1)
    {
        [args addObject:@"custom"];
    }

	return args;
}

@end