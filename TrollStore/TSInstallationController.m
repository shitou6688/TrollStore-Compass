#import "TSInstallationController.h"

#import "TSApplicationsManager.h"
#import "TSAppInfo.h"
#import <TSUtil.h>
#import <TSPresentationDelegate.h>

extern NSUserDefaults* trollStoreUserDefaults(void);

static NSString* TSFormattedByteCount(long long bytes)
{
	if(bytes >= 1024 * 1024 * 1024) return [NSString stringWithFormat:@"%.2f GB", bytes / 1024.0 / 1024.0 / 1024.0];
	if(bytes >= 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes / 1024.0 / 1024.0];
	if(bytes >= 1024) return [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];
	return [NSString stringWithFormat:@"%lld B", bytes];
}

// 兼容旧 SDK 的下载代理：用 delegate 回调拿到实时下载进度，代替 downloadTaskWithRequest:progress: 版本 API
@interface TSRemoteDownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy) void (^onProgress)(long long receivedBytes, long long totalBytes);
@property (nonatomic, copy) void (^onFinish)(NSURL* location);
@property (nonatomic, copy) void (^onError)(NSError* error);
@end

@implementation TSRemoteDownloadDelegate

- (void)URLSession:(NSURLSession*)session downloadTask:(NSURLSessionDownloadTask*)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
	if(self.onProgress)
	{
		self.onProgress(totalBytesWritten, totalBytesExpectedToWrite);
	}
}

- (void)URLSession:(NSURLSession*)session downloadTask:(NSURLSessionDownloadTask*)downloadTask didFinishDownloadingToURL:(NSURL*)location
{
	// 关键：会话的临时下载文件在本回调返回后立即被系统删除，必须在这里同步取出文件
	NSString* stablePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ts_download_%lld.ipa", (long long)([NSDate date].timeIntervalSince1970 * 1000)]];
	[[NSFileManager defaultManager] removeItemAtPath:stablePath error:nil];

	NSError* copyError = nil;
	if(![[NSFileManager defaultManager] copyItemAtPath:location.path toPath:stablePath error:&copyError])
	{
		// copy 失败时尝试 move 兜底
		[[NSFileManager defaultManager] removeItemAtPath:stablePath error:nil];
		[[NSFileManager defaultManager] moveItemAtPath:location.path toPath:stablePath error:nil];
	}

	if(self.onFinish)
	{
		self.onFinish([NSURL fileURLWithPath:stablePath]);
	}
}

- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task didCompleteWithError:(NSError*)error
{
	if(error && self.onError)
	{
		self.onError(error);
	}
}

@end

@implementation TSInstallationController

+ (void)handleAppInstallFromFile:(NSString*)pathToIPA forceInstall:(BOOL)force completion:(void (^)(BOOL, NSError*))completionBlock
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		[TSPresentationDelegate startActivity:@"正在安装"];
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
		{
			// Install IPA
			NSString* log;
			int ret = [[TSApplicationsManager sharedInstance] installIpa:pathToIPA force:force log:&log];

			NSError* error;
			if(ret != 0)
			{
				error = [[TSApplicationsManager sharedInstance] errorForCode:ret];
			}

			NSLog(@"installed app! ret:%d, error: %@", ret, error);

			dispatch_async(dispatch_get_main_queue(), ^
			{
				[TSPresentationDelegate stopActivityWithCompletion:^
				{
					if (ret == 0) {
						// success
						if(completionBlock) completionBlock(YES, nil);
					} else if (ret == 171) {
						// recoverable error
						UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"安装错误 %d", ret] message:[error localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
						UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
						{
							if(completionBlock) completionBlock(NO, error);
						}];
						[errorAlert addAction:closeAction];

						UIAlertAction* forceInstallAction = [UIAlertAction actionWithTitle:@"强制安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
						{
							[self handleAppInstallFromFile:pathToIPA forceInstall:YES completion:completionBlock];
						}];
						[errorAlert addAction:forceInstallAction];

						[TSPresentationDelegate presentViewController:errorAlert animated:YES completion:nil];
					} else if (ret == 182) {
						// non-fatal informative message
						UIAlertController* rebootNotification = [UIAlertController alertControllerWithTitle:@"需要重启" message:[error localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
						UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
						{
							if(completionBlock) completionBlock(YES, nil);
						}];
						[rebootNotification addAction:closeAction];

						UIAlertAction* rebootAction = [UIAlertAction actionWithTitle:@"立即重启" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
						{
							if(completionBlock) completionBlock(YES, nil);
							spawnRoot(rootHelperPath(), @[@"reboot"], nil, nil);
						}];
						[rebootNotification addAction:rebootAction];

						[TSPresentationDelegate presentViewController:rebootNotification animated:YES completion:nil];
					} else if (ret == 184) {
						// warning
						UIAlertController* warningAlert = [UIAlertController alertControllerWithTitle:@"警告" message:[error localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
						UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
						{
							if(completionBlock) completionBlock(YES, nil);
						}];
						[warningAlert addAction:closeAction];

						[TSPresentationDelegate presentViewController:warningAlert animated:YES completion:nil];
					} else {
						// unrecoverable error
						UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"安装错误 %d", ret] message:[error localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
						UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil];
						[errorAlert addAction:closeAction];

						UIAlertAction* copyLogAction = [UIAlertAction actionWithTitle:@"复制调试日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
						{
							UIPasteboard* pasteboard = [UIPasteboard generalPasteboard];
							pasteboard.string = log;
						}];
						[errorAlert addAction:copyLogAction];

						[TSPresentationDelegate presentViewController:errorAlert animated:YES completion:nil];

						if(completionBlock) completionBlock(NO, error);
					}
				}];
			});
		});
	});
}

+ (void)presentInstallationAlertIfEnabledForFile:(NSString*)pathToIPA isRemoteInstall:(BOOL)remoteInstall completion:(void (^)(BOOL, NSError*))completionBlock
{
	NSNumber* installAlertConfigurationNum = [trollStoreUserDefaults() objectForKey:@"installAlertConfiguration"];
	NSUInteger installAlertConfiguration = 0;
	if(installAlertConfigurationNum)
	{
		installAlertConfiguration = installAlertConfigurationNum.unsignedIntegerValue;
		if(installAlertConfiguration > 2)
		{
			// broken pref? revert to 0
			installAlertConfiguration = 0;
		}
	}

	// Check if user disabled alert for this kind of install
	if(installAlertConfiguration > 0)
	{
		if(installAlertConfiguration == 2 || (installAlertConfiguration == 1 && !remoteInstall))
		{
			[self handleAppInstallFromFile:pathToIPA completion:completionBlock];
			return;
		}
	}

	TSAppInfo* appInfo = [[TSAppInfo alloc] initWithIPAPath:pathToIPA];
	[appInfo loadInfoWithCompletion:^(NSError* error)
	{
		dispatch_async(dispatch_get_main_queue(), ^
		{
			if(!error)
			{
				UIAlertController* installAlert = [UIAlertController alertControllerWithTitle:@"" message:@"" preferredStyle:UIAlertControllerStyleAlert];
				installAlert.attributedTitle = [appInfo detailedInfoTitle];
				installAlert.attributedMessage = [appInfo detailedInfoDescription];
				UIAlertAction* installAction = [UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action)
				{
					[self handleAppInstallFromFile:pathToIPA completion:completionBlock];
				}];
				[installAlert addAction:installAction];

				UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
				{
					if(completionBlock) completionBlock(NO, nil);
				}];
				[installAlert addAction:cancelAction];

				[TSPresentationDelegate presentViewController:installAlert animated:YES completion:nil];
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

+ (void)handleAppInstallFromFile:(NSString*)pathToIPA completion:(void (^)(BOOL, NSError*))completionBlock
{
	[self handleAppInstallFromFile:pathToIPA forceInstall:NO completion:completionBlock];
}

+ (void)handleAppInstallFromRemoteURL:(NSURL*)remoteURL completion:(void (^)(BOOL, NSError*))completionBlock
{
	NSURLRequest* downloadRequest = [NSURLRequest requestWithURL:remoteURL];

	dispatch_async(dispatch_get_main_queue(), ^
	{
		__block NSURLSessionDownloadTask* downloadTask = nil;

		TSRemoteDownloadDelegate* downloadDelegate = [TSRemoteDownloadDelegate new];
		NSURLSessionConfiguration* downloadConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
		__block NSURLSession* downloadSession = [NSURLSession sessionWithConfiguration:downloadConfig delegate:downloadDelegate delegateQueue:nil];

		downloadDelegate.onProgress = ^(long long receivedBytes, long long totalBytes)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				NSString* message = nil;
				if(totalBytes > 0)
				{
					double percent = (double)receivedBytes * 100.0 / (double)totalBytes;
					if(percent > 100.0) percent = 100.0;
					message = [NSString stringWithFormat:@"正在下载 %.0f%%（%@ / %@）", percent, TSFormattedByteCount(receivedBytes), TSFormattedByteCount(totalBytes)];
				}
				else
				{
					message = [NSString stringWithFormat:@"正在下载（已下载 %@）", TSFormattedByteCount(receivedBytes)];
				}
				[TSPresentationDelegate updateActivityMessage:message];
			});
		};

		downloadDelegate.onFinish = ^(NSURL* location)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				// 文件已由下载代理同步拷贝到稳定路径，这里直接使用
				NSString* tmpIpaPath = location.path;

				[downloadSession finishTasksAndInvalidate];
				downloadSession = nil;

				[TSPresentationDelegate stopActivityWithCompletion:^
				{
					[self presentInstallationAlertIfEnabledForFile:tmpIpaPath isRemoteInstall:YES completion:^(BOOL success, NSError* error)
					{
						[[NSFileManager defaultManager] removeItemAtPath:tmpIpaPath error:nil];
						if(completionBlock) completionBlock(success, error);
					}];
				}];
			});
		};

		downloadDelegate.onError = ^(NSError* error)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[downloadSession invalidateAndCancel];
				downloadSession = nil;

				NSString* errorMessage = [error localizedDescription] ?: @"";
				if(error.code == NSURLErrorCancelled) errorMessage = @"已取消下载";

				UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:@"错误" message:[NSString stringWithFormat:@"下载应用出错：%@", errorMessage] preferredStyle:UIAlertControllerStyleAlert];
				UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil];
				[errorAlert addAction:closeAction];

				[TSPresentationDelegate stopActivityWithCompletion:^
				{
					[TSPresentationDelegate presentViewController:errorAlert animated:YES completion:^
					{
						if(completionBlock) completionBlock(NO, error);
					}];
				}];
			});
		};

		[TSPresentationDelegate startActivity:@"正在下载" withCancelHandler:^
		{
			[downloadTask cancel];
		}];

		downloadTask = [downloadSession downloadTaskWithRequest:downloadRequest];
		[downloadTask resume];
	});
}

+ (void)installLdid
{
	fetchLatestLdidVersion(^(NSString* latestVersion)
	{
		if(!latestVersion) return;
		dispatch_async(dispatch_get_main_queue(), ^
		{
			NSURL* ldidURL = [NSURL URLWithString:@"https://github.com/opa334/ldid/releases/latest/download/ldid"];
			NSURLRequest* ldidRequest = [NSURLRequest requestWithURL:ldidURL];

			[TSPresentationDelegate startActivity:@"正在安装 ldid"];

			NSURLSessionDownloadTask* downloadTask = [NSURLSession.sharedSession downloadTaskWithRequest:ldidRequest completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error)
			{
				if(error)
				{
					UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:@"错误" message:[NSString stringWithFormat:@"下载 ldid 出错：%@", error] preferredStyle:UIAlertControllerStyleAlert];
					UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil];
					[errorAlert addAction:closeAction];

					dispatch_async(dispatch_get_main_queue(), ^
					{
						[TSPresentationDelegate stopActivityWithCompletion:^
						{
							[TSPresentationDelegate presentViewController:errorAlert animated:YES completion:nil];
						}];
					});
				}
				else if(location)
				{
					spawnRoot(rootHelperPath(), @[@"install-ldid", location.path, latestVersion], nil, nil);
					dispatch_async(dispatch_get_main_queue(), ^
					{
						[TSPresentationDelegate stopActivityWithCompletion:nil];
						[[NSNotificationCenter defaultCenter] postNotificationName:@"TrollStoreReloadSettingsNotification" object:nil userInfo:nil];
					});
				}
			}];

			[downloadTask resume];
		});
	});
}

@end