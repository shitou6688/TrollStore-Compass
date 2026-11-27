#import "TSSettingsAdvancedListController.h"
#import "TSUtil.h"
#import <Preferences/PSSpecifier.h>

extern NSUserDefaults* trollStoreUserDefaults();
@interface PSSpecifier ()
@property (nonatomic,retain) NSArray* values;
@end

@implementation TSSettingsAdvancedListController

- (NSMutableArray*)specifiers
{
	if(!_specifiers)
	{
		_specifiers = [NSMutableArray new];

		PSSpecifier* installationMethodGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		//installationMethodGroupSpecifier.name = @"Installation";
		[installationMethodGroupSpecifier setProperty:@"installd：\n通过 installd 进行占位安装，修复权限后添加到图标缓存。\n优点：在图标缓存重新加载方面可能比自定义方式更持久。\n缺点：某些应用可能会出现一些小问题（例如 Watusi 使用此方式安装时无法保存偏好设置）。\n\n自定义（推荐）：\n使用 MobileContainerManager 手动创建应用包，将应用复制进去并添加到图标缓存。\n优点：没有已知问题。\n缺点：在图标缓存重新加载方面可能不如 installd 方式持久。\n\n注意：如果选择 installd 但占位安装失败，巨魔商店会自动回退到自定义方式。" forKey:@"footerText"];
		[_specifiers addObject:installationMethodGroupSpecifier];

		PSSpecifier* installationMethodSpecifier = [PSSpecifier preferenceSpecifierNamed:@"安装方式"
											target:self
											set:nil
											get:nil
											detail:nil
											cell:PSStaticTextCell
											edit:nil];
		[installationMethodSpecifier setProperty:@YES forKey:@"enabled"];
		installationMethodSpecifier.identifier = @"installationMethodLabel";
		[_specifiers addObject:installationMethodSpecifier];

		PSSpecifier* installationMethodSegmentSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Installation Method Segment"
											target:self
											set:@selector(setPreferenceValue:specifier:)
											get:@selector(readPreferenceValue:)
											detail:nil
											cell:PSSegmentCell
											edit:nil];
		[installationMethodSegmentSpecifier setProperty:@YES forKey:@"enabled"];
		installationMethodSegmentSpecifier.identifier = @"installationMethodSegment";
		[installationMethodSegmentSpecifier setProperty:APP_ID forKey:@"defaults"];
		[installationMethodSegmentSpecifier setProperty:@"installationMethod" forKey:@"key"];
		installationMethodSegmentSpecifier.values = @[@0, @1];
		installationMethodSegmentSpecifier.titleDictionary = @{@0 : @"installd", @1 : @"Custom"};
		[installationMethodSegmentSpecifier setProperty:@1 forKey:@"default"];
		[_specifiers addObject:installationMethodSegmentSpecifier];

		PSSpecifier* uninstallationMethodGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		//uninstallationMethodGroupSpecifier.name = @"Uninstallation";
		[uninstallationMethodGroupSpecifier setProperty:@"installd（推荐）：\n使用与主屏幕卸载相同的 API 来卸载应用。\n\n自定义：\n从图标缓存中移除应用，然后直接删除应用和数据包。\n\n注意：如果选择 installd 但系统卸载失败，巨魔商店会自动回退到自定义方式。" forKey:@"footerText"];
		[_specifiers addObject:uninstallationMethodGroupSpecifier];

		PSSpecifier* uninstallationMethodSpecifier = [PSSpecifier preferenceSpecifierNamed:@"卸载方式"
											target:self
											set:nil
											get:nil
											detail:nil
											cell:PSStaticTextCell
											edit:nil];
		[uninstallationMethodSpecifier setProperty:@YES forKey:@"enabled"];
		uninstallationMethodSpecifier.identifier = @"uninstallationMethodLabel";
		[_specifiers addObject:uninstallationMethodSpecifier];

		PSSpecifier* uninstallationMethodSegmentSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Installation Method Segment"
											target:self
											set:@selector(setPreferenceValue:specifier:)
											get:@selector(readPreferenceValue:)
											detail:nil
											cell:PSSegmentCell
											edit:nil];
		[uninstallationMethodSegmentSpecifier setProperty:@YES forKey:@"enabled"];
		uninstallationMethodSegmentSpecifier.identifier = @"uninstallationMethodSegment";
		[uninstallationMethodSegmentSpecifier setProperty:APP_ID forKey:@"defaults"];
		[uninstallationMethodSegmentSpecifier setProperty:@"uninstallationMethod" forKey:@"key"];
		uninstallationMethodSegmentSpecifier.values = @[@0, @1];
		uninstallationMethodSegmentSpecifier.titleDictionary = @{@0 : @"installd", @1 : @"Custom"};
		[uninstallationMethodSegmentSpecifier setProperty:@0 forKey:@"default"];
		[_specifiers addObject:uninstallationMethodSegmentSpecifier];
	}

	[(UINavigationItem *)self.navigationItem setTitle:@"高级"];
	return _specifiers;
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

@end
