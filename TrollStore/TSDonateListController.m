#import "TSDonateListController.h"
#import <Preferences/PSSpecifier.h>

@implementation TSDonateListController


- (void)donateToAlfiePressed
{
	[[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://ko-fi.com/alfiecg_dev"] options:@{} completionHandler:^(BOOL success){}];
}

- (void)donateToOpaPressed
{
	[[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://www.paypal.com/cgi-bin/webscr?cmd=_donations&business=opa334@protonmail.com&item_name=TrollStore"] options:@{} completionHandler:^(BOOL success){}];
}

- (NSMutableArray*)specifiers
{
	if(!_specifiers)
	{
		_specifiers = [NSMutableArray new];
		
		PSSpecifier* alfieGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		alfieGroupSpecifier.name = @"Alfie";
		[alfieGroupSpecifier setProperty:@"Alfie 通过补丁对比发现了新的 CoreTrust 漏洞（CVE-2023-41991），制作了 POC 并在 ChOma 库的帮助下实现了自动化利用，同时也为该库做出了贡献。" forKey:@"footerText"];
		[_specifiers addObject:alfieGroupSpecifier];

		PSSpecifier* alfieDonateSpecifier = [PSSpecifier preferenceSpecifierNamed:@"捐赠给 alfiecg_dev"
									target:self
									set:nil
									get:nil
									detail:nil
									cell:PSButtonCell
									edit:nil];
		alfieDonateSpecifier.identifier = @"donateToAlfie";
		[alfieDonateSpecifier setProperty:@YES forKey:@"enabled"];
		alfieDonateSpecifier.buttonAction = @selector(donateToAlfiePressed);
		[_specifiers addObject:alfieDonateSpecifier];

		PSSpecifier* opaGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
		opaGroupSpecifier.name = @"Opa";
		[opaGroupSpecifier setProperty:@"Opa 开发了 ChOma 库，帮助实现了漏洞自动化利用，并将其集成到巨魔商店中。" forKey:@"footerText"];
		[_specifiers addObject:opaGroupSpecifier];

		PSSpecifier* opaDonateSpecifier = [PSSpecifier preferenceSpecifierNamed:@"捐赠给 opa334"
									target:self
									set:nil
									get:nil
									detail:nil
									cell:PSButtonCell
									edit:nil];
		opaDonateSpecifier.identifier = @"donateToOpa";
		[opaDonateSpecifier setProperty:@YES forKey:@"enabled"];
		opaDonateSpecifier.buttonAction = @selector(donateToOpaPressed);
		[_specifiers addObject:opaDonateSpecifier];
	}
	[(UINavigationItem *)self.navigationItem setTitle:@"捐赠"];
	return _specifiers;
}

@end