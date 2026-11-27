#import "TSAppTableViewController.h"

#import "TSApplicationsManager.h"
#import <TSPresentationDelegate.h>
#import "TSInstallationController.h"
#import "TSQRScannerViewController.h"
#import "TSLinkBrowserViewController.h"
#import "TSUtil.h"
@import UniformTypeIdentifiers;

#define ICON_FORMAT_IPAD 8
#define ICON_FORMAT_IPHONE 10

NSInteger iconFormatToUse(void)
{
	if(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad)
	{
		return ICON_FORMAT_IPAD;
	}
	else
	{
		return ICON_FORMAT_IPHONE;
	}
}

UIImage* imageWithSize(UIImage* image, CGSize size)
{
	if(CGSizeEqualToSize(image.size, size)) return image;
	UIGraphicsBeginImageContextWithOptions(size, NO, UIScreen.mainScreen.scale);
	CGRect imageRect = CGRectMake(0.0, 0.0, size.width, size.height);
	[image drawInRect:imageRect];
	UIImage* outImage = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return outImage;
}

@interface UIImage ()
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)id format:(NSInteger)format scale:(double)scale;
@end

@implementation TSAppTableViewController

- (void)loadAppInfos
{
	NSArray* appPaths = [[TSApplicationsManager sharedInstance] installedAppPaths];
	NSMutableArray<TSAppInfo*>* appInfos = [NSMutableArray new];

	for(NSString* appPath in appPaths)
	{
		TSAppInfo* appInfo = [[TSAppInfo alloc] initWithAppBundlePath:appPath];
		[appInfo sync_loadBasicInfo];
		[appInfos addObject:appInfo];
	}

	if(_searchKey && ![_searchKey isEqualToString:@""])
	{
		[appInfos enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(TSAppInfo* appInfo, NSUInteger idx, BOOL* stop)
		{
			NSString* appName = [appInfo displayName];
			BOOL nameMatch = [appName rangeOfString:_searchKey options:NSCaseInsensitiveSearch range:NSMakeRange(0, [appName length]) locale:[NSLocale currentLocale]].location != NSNotFound;
			if(!nameMatch)
			{
				[appInfos removeObjectAtIndex:idx];
			}
		}];
	}

	[appInfos sortUsingComparator:^(TSAppInfo* appInfoA, TSAppInfo* appInfoB)
	{
		return [[appInfoA displayName] localizedStandardCompare:[appInfoB displayName]];
	}];

	_cachedAppInfos = appInfos.copy;
}

- (instancetype)init
{
	self = [super init];
	if(self)
	{
		[self loadAppInfos];
		_placeholderIcon = [UIImage _applicationIconImageForBundleIdentifier:@"com.apple.WebSheet" format:iconFormatToUse() scale:[UIScreen mainScreen].scale];
		_cachedIcons = [NSMutableDictionary new];
		[[LSApplicationWorkspace defaultWorkspace] addObserver:self];
	}
	return self;
}

- (void)dealloc
{
	[[LSApplicationWorkspace defaultWorkspace] removeObserver:self];
}

- (void)reloadTable
{
	[self loadAppInfos];
	dispatch_async(dispatch_get_main_queue(), ^
	{
		[self.tableView reloadData];
	});
}

- (void)loadView
{
	[super loadView];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadTable) name:@"ApplicationsChanged" object:nil];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	
	self.tableView.allowsMultipleSelectionDuringEditing = NO;
	self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];

	[self _setUpNavigationBar];
	[self _setUpSearchBar];
}

- (void)_setUpNavigationBar
{
	UIAction* installFromFileAction = [UIAction actionWithTitle:@"安装 IPA 文件" image:[UIImage systemImageNamed:@"doc.badge.plus"] identifier:@"InstallIPAFile" handler:^(__kindof UIAction *action)
	{
		dispatch_async(dispatch_get_main_queue(), ^
		{
			UTType* ipaType = [UTType typeWithFilenameExtension:@"ipa" conformingToType:UTTypeData];
			UTType* tipaType = [UTType typeWithFilenameExtension:@"tipa" conformingToType:UTTypeData];

			UIDocumentPickerViewController* documentPickerVC = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ipaType, tipaType]];
			documentPickerVC.allowsMultipleSelection = NO;
			documentPickerVC.delegate = self;

			[TSPresentationDelegate presentViewController:documentPickerVC animated:YES completion:nil];
		});
	}];

	UIAction* installFromURLAction = [UIAction actionWithTitle:@"复制网址安装" image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:@"从URL安装" handler:^(__kindof UIAction *action)
	{
		dispatch_async(dispatch_get_main_queue(), ^
		{
			UIAlertController* installURLController = [UIAlertController alertControllerWithTitle:@"复制网址安装" message:@"" preferredStyle:UIAlertControllerStyleAlert];

			[installURLController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
				textField.placeholder = @"粘贴或输入应用下载网址";
				// 剪贴板里已有网址时自动填入，省去手动粘贴
				NSString* clip = [UIPasteboard generalPasteboard].string ?: @"";
				clip = [clip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				if(clip.length > 0 && clip.length < 2048
					&& ([clip.lowercaseString hasPrefix:@"http://"] || [clip.lowercaseString hasPrefix:@"https://"] || [clip.lowercaseString hasPrefix:@"ftp://"]))
				{
					textField.text = clip;
				}
			}];

			UIAlertAction* installAction = [UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
			{
				NSString* URLString = installURLController.textFields.firstObject.text;
				[self handleParsedURLString:URLString fromScanner:NO];
			}];
			[installURLController addAction:installAction];

			UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
			[installURLController addAction:cancelAction];

			[TSPresentationDelegate presentViewController:installURLController animated:YES completion:nil];
		});
	}];

	UIAction* installFromScanAction = [UIAction actionWithTitle:@"扫码安装" image:[UIImage systemImageNamed:@"qrcode.viewfinder"] identifier:@"ScanToInstall" handler:^(__kindof UIAction *action)
	{
		dispatch_async(dispatch_get_main_queue(), ^
		{
			TSQRScannerViewController* scannerVC = [[TSQRScannerViewController alloc] init];
			scannerVC.delegate = self;
			[TSPresentationDelegate presentViewController:scannerVC animated:YES completion:nil];
		});
	}];

	UIMenu* installMenu = [UIMenu menuWithChildren:@[installFromFileAction, installFromURLAction, installFromScanAction]];

	UIBarButtonItem* installBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"] menu:installMenu];
	
	self.navigationItem.rightBarButtonItems = @[installBarButtonItem];
}

- (void)_setUpSearchBar
{
	_searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
	_searchController.searchResultsUpdater = self;
	_searchController.obscuresBackgroundDuringPresentation = NO;
	self.navigationItem.searchController = _searchController;
	self.navigationItem.hidesSearchBarWhenScrolling = YES;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		_searchKey = searchController.searchBar.text;
		[self reloadTable];
	});
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	NSString* pathToIPA = urls.firstObject.path;
	[TSInstallationController presentInstallationAlertIfEnabledForFile:pathToIPA isRemoteInstall:NO completion:nil];
}

#pragma mark - TSQRScannerViewControllerDelegate

- (void)qrScannerController:(TSQRScannerViewController*)scanner didScanResult:(NSString*)result
{
	NSString* trimmed = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

	// 先关闭扫码界面，避免与其上方的弹窗产生 present 冲突
	[scanner dismissViewControllerAnimated:YES completion:^
	{
		[self handleParsedURLString:trimmed fromScanner:YES];
	}];
}

// 统一处理扫到的/输入的链接：直链直接安装；非直链（蓝奏云等分享页）自动解析出真实直链再安装
- (void)handleParsedURLString:(NSString*)URLString fromScanner:(BOOL)fromScanner
{
	NSString* trimmed = [URLString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

	NSURL* parsedURL = [NSURL URLWithString:trimmed];
	if(!parsedURL)
	{
		// 链接含中文/空格等未转义字符时 NSURL 解析失败，自动补百分号转义后重试
		NSString* encoded = [trimmed stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLFragmentAllowedCharacterSet]];
		if(encoded) parsedURL = [NSURL URLWithString:encoded];
	}

	BOOL isValidURL = parsedURL && parsedURL.scheme.length > 0 && parsedURL.host.length > 0
		&& ([parsedURL.scheme.lowercaseString isEqualToString:@"http"]
			|| [parsedURL.scheme.lowercaseString isEqualToString:@"https"]
			|| [parsedURL.scheme.lowercaseString isEqualToString:@"ftp"]);

	if(!isValidURL)
	{
		NSString* previewText = trimmed.length > 200 ? [trimmed substringToIndex:200] : trimmed;
		UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"无效的链接"
			message:[NSString stringWithFormat:@"二维码内容不是有效的应用下载链接：\n%@", previewText]
			preferredStyle:UIAlertControllerStyleAlert];

		if(fromScanner)
		{
			[alert addAction:[UIAlertAction actionWithTitle:@"重新扫码" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
			{
				TSQRScannerViewController* newScanner = [[TSQRScannerViewController alloc] init];
				newScanner.delegate = self;
				[TSPresentationDelegate presentViewController:newScanner animated:YES completion:nil];
			}]];
		}

		[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

		[TSPresentationDelegate presentViewController:alert animated:YES completion:nil];
		return;
	}

	NSString* path = parsedURL.path.lowercaseString;
	BOOL isDirectFile = [path hasSuffix:@".ipa"] || [path hasSuffix:@".tipa"];

	if(isDirectFile)
	{
		UIAlertController* confirmController = [UIAlertController alertControllerWithTitle:@"安装应用"
			message:[NSString stringWithFormat:@"应用下载链接：\n%@\n\n确定要安装该应用吗？", trimmed]
			preferredStyle:UIAlertControllerStyleAlert];

		[confirmController addAction:[UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			[TSInstallationController handleAppInstallFromRemoteURL:parsedURL completion:nil];
		}]];

		[confirmController addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

		[TSPresentationDelegate presentViewController:confirmController animated:YES completion:nil];
	}
	else
	{
		// 非直链：打开内置浏览器（同 IPA提取器），用户在页面中点击下载后自动提取并弹出安装
		TSLinkBrowserViewController* browser = [[TSLinkBrowserViewController alloc] initWithURL:parsedURL];
		browser.delegate = self;
		[TSPresentationDelegate presentViewController:browser animated:YES completion:nil];
	}
}

#pragma mark - TSLinkBrowserViewControllerDelegate

- (void)linkBrowser:(TSLinkBrowserViewController*)browser didDetectFileURL:(NSURL*)fileURL
{
	// 只展示文件名，不暴露真实下载地址
	NSString* fileName = fileURL.lastPathComponent ?: @"";
	fileName = [fileName stringByRemovingPercentEncoding] ?: fileName;
	if(fileName.length == 0) fileName = @"应用安装包";

	UIAlertController* confirmController = [UIAlertController alertControllerWithTitle:@"提取成功"
		message:[NSString stringWithFormat:@"已提取到应用文件：%@ \n\n确定要安装该应用吗？", fileName]
		preferredStyle:UIAlertControllerStyleAlert];

	[confirmController addAction:[UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		[TSInstallationController handleAppInstallFromRemoteURL:fileURL completion:nil];
	}]];

	[confirmController addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

	[TSPresentationDelegate presentViewController:confirmController animated:YES completion:nil];
}

- (void)linkBrowserDidCancel:(TSLinkBrowserViewController*)browser
{
	// 用户主动关闭浏览器，无需处理
}

- (void)qrScannerControllerDidCancel:(TSQRScannerViewController*)scanner
{
	// 用户主动关闭扫码界面，无需处理
}

- (void)openAppPressedForRowAtIndexPath:(NSIndexPath*)indexPath enableJIT:(BOOL)enableJIT
{
	TSApplicationsManager* appsManager = [TSApplicationsManager sharedInstance];

	TSAppInfo* appInfo = _cachedAppInfos[indexPath.row];
	NSString* appId = [appInfo bundleIdentifier];
	BOOL didOpen = [appsManager openApplicationWithBundleID:appId];

	// if we failed to open the app, show an alert
	if(!didOpen)
	{
		NSString* failMessage = @"";
		if([[appInfo registrationState] isEqualToString:@"User"])
		{
			failMessage = @"此应用无法启动，因为它有一个\"User\" registration state, register it as \"System\" and try again.";
		}

		NSString* failTitle = [NSString stringWithFormat:@"无法打开 %@", appId];
		UIAlertController* didFailController = [UIAlertController alertControllerWithTitle:failTitle message:failMessage preferredStyle:UIAlertControllerStyleAlert];
		UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];

		[didFailController addAction:cancelAction];
		[TSPresentationDelegate presentViewController:didFailController animated:YES completion:nil];
	}
	else if (enableJIT)
	{
		int ret = [appsManager enableJITForBundleID:appId];
		if (ret != 0)
		{
			UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:@"错误" message:[NSString stringWithFormat:@"Error enabling JIT: trollstorehelper returned %d", ret] preferredStyle:UIAlertControllerStyleAlert];
			UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil];
			[errorAlert addAction:closeAction];
			[TSPresentationDelegate presentViewController:errorAlert animated:YES completion:nil];
		}
	}
}

- (void)showDetailsPressedForRowAtIndexPath:(NSIndexPath*)indexPath
{
	TSAppInfo* appInfo = _cachedAppInfos[indexPath.row];

	[appInfo loadInfoWithCompletion:^(NSError* error)
	{
		dispatch_async(dispatch_get_main_queue(), ^
		{
			if(!error)
			{
				UIAlertController* detailsAlert = [UIAlertController alertControllerWithTitle:@"" message:@"" preferredStyle:UIAlertControllerStyleAlert];
				detailsAlert.attributedTitle = [appInfo detailedInfoTitle];
				detailsAlert.attributedMessage = [appInfo detailedInfoDescription];

				UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil];
				[detailsAlert addAction:closeAction];

				[TSPresentationDelegate presentViewController:detailsAlert animated:YES completion:nil];
			}
			else
			{
				UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"解析错误 %ld", error.code] message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
				UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil];
				[errorAlert addAction:closeAction];

				[TSPresentationDelegate presentViewController:errorAlert animated:YES completion:nil];
			}
		});
	}];
}

- (void)changeAppRegistrationForRowAtIndexPath:(NSIndexPath*)indexPath toState:(NSString*)newState
{
	TSAppInfo* appInfo = _cachedAppInfos[indexPath.row];

	if([newState isEqualToString:@"User"])
	{
		NSString* title = [NSString stringWithFormat:@"正在将 '%@' 切换为 \"User\" Registration", [appInfo displayName]];
		UIAlertController* confirmationAlert = [UIAlertController alertControllerWithTitle:title message:@"将此应用切换为\"User\" registration will make it unlaunchable after the next respring because the bugs exploited in TrollStore only affect apps registered as \"System\".\nThe purpose of this option is to make the app temporarily show up in settings, so you can adjust the settings and then switch it back to a \"System\" registration (TrollStore installed apps do not show up in settings otherwise). Additionally, the \"User\" registration state is also useful to temporarily fix iTunes file sharing, which also doesn't work for TrollStore installed apps otherwise.\nWhen you're done making the changes you need and want the app to become launchable again, you will need to switch it back to \"System\" state in TrollStore." preferredStyle:UIAlertControllerStyleAlert];

		UIAlertAction* switchToUserAction = [UIAlertAction actionWithTitle:@"切换到 \"User\"" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action)
		{
			[[TSApplicationsManager sharedInstance] changeAppRegistration:[appInfo bundlePath] toState:newState];
			[appInfo sync_loadBasicInfo];
		}];

		[confirmationAlert addAction:switchToUserAction];

		UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];

		[confirmationAlert addAction:cancelAction];

		[TSPresentationDelegate presentViewController:confirmationAlert animated:YES completion:nil];
	}
	else
	{
		[[TSApplicationsManager sharedInstance] changeAppRegistration:[appInfo bundlePath] toState:newState];
		[appInfo sync_loadBasicInfo];

		NSString* title = [NSString stringWithFormat:@"已将 '%@' 切换为 \"System\" Registration", [appInfo displayName]];

		UIAlertController* infoAlert = [UIAlertController alertControllerWithTitle:title message:@"应用已切换为\"System\" registration state and will become launchable again after a respring." preferredStyle:UIAlertControllerStyleAlert];

		UIAlertAction* respringAction = [UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			respring();
		}];

		[infoAlert addAction:respringAction];

		UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil];

		[infoAlert addAction:closeAction];

		[TSPresentationDelegate presentViewController:infoAlert animated:YES completion:nil];
	}
}

- (void)uninstallPressedForRowAtIndexPath:(NSIndexPath*)indexPath
{
	TSApplicationsManager* appsManager = [TSApplicationsManager sharedInstance];

	TSAppInfo* appInfo = _cachedAppInfos[indexPath.row];

	NSString* appPath = [appInfo bundlePath];
	NSString* appId = [appInfo bundleIdentifier];
	NSString* appName = [appInfo displayName];

	UIAlertController* confirmAlert = [UIAlertController alertControllerWithTitle:@"确认卸载" message:[NSString stringWithFormat:@"卸载应用 '%@' 将删除该应用及其所有数据。", appName] preferredStyle:UIAlertControllerStyleAlert];

	UIAlertAction* uninstallAction = [UIAlertAction actionWithTitle:@"卸载" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action)
	{
		if(appId)
		{
			[appsManager uninstallApp:appId];
		}
		else
		{
			[appsManager uninstallAppByPath:appPath];
		}
	}];
	[confirmAlert addAction:uninstallAction];

	UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
	[confirmAlert addAction:cancelAction];

	[TSPresentationDelegate presentViewController:confirmAlert animated:YES completion:nil];
}

- (void)deselectRow
{
	[self.tableView deselectRowAtIndexPath:[self.tableView indexPathForSelectedRow] animated:YES];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	return _cachedAppInfos.count;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
	[self reloadTable];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ApplicationCell"];
	if(!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ApplicationCell"];
	}

	if(!indexPath || indexPath.row > (_cachedAppInfos.count - 1)) return cell;

	TSAppInfo* appInfo = _cachedAppInfos[indexPath.row];
	NSString* appId = [appInfo bundleIdentifier];
	NSString* appVersion = [appInfo versionString];

	// Configure the cell...
	cell.textLabel.text = [appInfo displayName];
	cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@", appVersion, appId];
	cell.imageView.layer.borderWidth = 1;
	cell.imageView.layer.borderColor = [UIColor.labelColor colorWithAlphaComponent:0.1].CGColor;
	cell.imageView.layer.cornerRadius = 13.5;
	cell.imageView.layer.masksToBounds = YES;
	cell.imageView.layer.cornerCurve = kCACornerCurveContinuous;

	if(appId)
	{
		UIImage* cachedIcon = _cachedIcons[appId];
		if(cachedIcon)
		{
			cell.imageView.image = cachedIcon;
		}
		else
		{
			cell.imageView.image = _placeholderIcon;
			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
			{
				UIImage* iconImage = imageWithSize([UIImage _applicationIconImageForBundleIdentifier:appId format:iconFormatToUse() scale:[UIScreen mainScreen].scale], _placeholderIcon.size);
				_cachedIcons[appId] = iconImage;
				dispatch_async(dispatch_get_main_queue(), ^{
					NSIndexPath *curIndexPath = [NSIndexPath indexPathForRow:[_cachedAppInfos indexOfObject:appInfo] inSection:0];
					UITableViewCell *curCell = [tableView cellForRowAtIndexPath:curIndexPath];
					if(curCell)
					{
						curCell.imageView.image = iconImage;
						[curCell setNeedsLayout];
					}
				});
			});
		}
	}
	else
	{
		cell.imageView.image = _placeholderIcon;
	}

	cell.preservesSuperviewLayoutMargins = NO;
	cell.separatorInset = UIEdgeInsetsZero;
	cell.layoutMargins = UIEdgeInsetsZero;

	return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
	return 80.0f;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
	if(editingStyle == UITableViewCellEditingStyleDelete)
	{
		[self uninstallPressedForRowAtIndexPath:indexPath];
	}
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	TSAppInfo* appInfo = _cachedAppInfos[indexPath.row];

	NSString* appId = [appInfo bundleIdentifier];
	NSString* appName = [appInfo displayName];

	UIAlertController* appSelectAlert = [UIAlertController alertControllerWithTitle:appName?:@"" message:appId?:@"" preferredStyle:UIAlertControllerStyleActionSheet];

	UIAlertAction* openAction = [UIAlertAction actionWithTitle:@"打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		[self openAppPressedForRowAtIndexPath:indexPath enableJIT:NO];
		[self deselectRow];
	}];
	[appSelectAlert addAction:openAction];

	if ([appInfo isDebuggable])
	{
		UIAlertAction* openWithJITAction = [UIAlertAction actionWithTitle:@"使用 JIT 打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
		{
			[self openAppPressedForRowAtIndexPath:indexPath enableJIT:YES];
			[self deselectRow];
		}];
		[appSelectAlert addAction:openWithJITAction];
	}

	UIAlertAction* showDetailsAction = [UIAlertAction actionWithTitle:@"显示详情" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		[self showDetailsPressedForRowAtIndexPath:indexPath];
		[self deselectRow];
	}];
	[appSelectAlert addAction:showDetailsAction];

	NSString* switchState;
	NSString* registrationState = [appInfo registrationState];
	UIAlertActionStyle switchActionStyle = 0;
	if([registrationState isEqualToString:@"System"])
	{
		switchState = @"用户";
		switchActionStyle = UIAlertActionStyleDestructive;
	}
	else if([registrationState isEqualToString:@"User"])
	{
		switchState = @"系统";
		switchActionStyle = UIAlertActionStyleDefault;
	}

	UIAlertAction* switchRegistrationAction = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"切换到 \"%@\" Registration", switchState] style:switchActionStyle handler:^(UIAlertAction* action)
	{
		[self changeAppRegistrationForRowAtIndexPath:indexPath toState:switchState];
		[self deselectRow];
	}];
	[appSelectAlert addAction:switchRegistrationAction];

	UIAlertAction* uninstallAction = [UIAlertAction actionWithTitle:@"卸载应用" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action)
	{
		[self uninstallPressedForRowAtIndexPath:indexPath];
		[self deselectRow];
	}];
	[appSelectAlert addAction:uninstallAction];

	UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
	{
		[self deselectRow];
	}];
	[appSelectAlert addAction:cancelAction];

	appSelectAlert.popoverPresentationController.sourceView = tableView;
	appSelectAlert.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];

	[TSPresentationDelegate presentViewController:appSelectAlert animated:YES completion:nil];
}

- (void)purgeCachedIconsForApps:(NSArray <LSApplicationProxy *>*)apps
{
	for (LSApplicationProxy *appProxy in apps) {
		NSString *appId = appProxy.bundleIdentifier;
		if (_cachedIcons[appId]) {
			[_cachedIcons removeObjectForKey:appId];
		}
	}
}

- (void)applicationsDidInstall:(NSArray <LSApplicationProxy *>*)apps
{
	[self purgeCachedIconsForApps:apps];
	[self reloadTable];
}

- (void)applicationsDidUninstall:(NSArray <LSApplicationProxy *>*)apps
{
	[self purgeCachedIconsForApps:apps];
	[self reloadTable];
}

@end
