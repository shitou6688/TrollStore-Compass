#import "TSApplicationsManager.h"
#import <TSUtil.h>
extern NSUserDefaults* trollStoreUserDefaults();

@implementation TSApplicationsManager

+ (instancetype)sharedInstance
{
    static TSApplicationsManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[TSApplicationsManager alloc] init];
    });
    return sharedInstance;
}

- (NSArray*)installedAppPaths
{
    return trollStoreInstalledAppBundlePaths();
}

- (NSError*)errorForCode:(int)code
{
    NSString* errorDescription = @"未知错误";
    switch(code)
    {
        // IPA install errors
        case 166:
        errorDescription = @"IPA 文件不存在或无法访问。";
        break;
        case 167:
        errorDescription = @"IPA 文件似乎不包含应用。";
        break;
        case 168:
        errorDescription = @"解压 IPA 文件失败。";
        break;
        case 169:
        errorDescription = @"解压更新 tar 文件失败。";
        break;
        // App install errors
        case 170:
        errorDescription = @"创建应用包容器失败。";
        break;
        case 171:
        errorDescription = @"A non "APP_NAME@" 或一个 "OTHER_APP_NAME@" app with the same identifier is already installed. If you are absolutely sure it is not, you can force install it.";
        break;
        case 172:
        errorDescription = @"The app does not contain an Info.plist file.";
        break;
        case 173:
        errorDescription = @"该应用未使用伪造 CoreTrust 证书签名，且未安装 ldid。请在设置中安装 ldid 后重试。";
        break;
        case 174:
        errorDescription = @"应用的主可执行文件不存在。";
        break;
        case 175: {
            //if (@available(iOS 16, *)) {
            //    errorDescription = @"签名应用失败。";
            //}
            //else {
                errorDescription = @"签名应用失败。ldid 返回了非零状态码。";
            //}
        }
        break;
        case 176:
        errorDescription = @"The app's Info.plist is missing required values.";
        break;
        case 177:
        errorDescription = @"标记应用为巨魔应用失败。";
        break;
        case 178:
        errorDescription = @"复制应用包失败。";
        break;
        case 179:
        errorDescription = @"您尝试安装的应用与设备上已安装的系统应用具有相同的标识符。为防止可能的引导循环或其他问题，安装已被阻止。";
        break;
        case 180:
        errorDescription = @"您尝试安装的应用主二进制文件已加密，无法应用 CoreTrust 绕过。请确保安装已解密的应用。";
        break;
        case 181:
        errorDescription = @"添加应用到图标缓存失败。";
        break;
        case 182:
        errorDescription = @"The app was installed successfully, but requires developer mode to be enabled to run. After rebooting, select \"Turn On\" to enable developer mode.";
        break;
        case 183:
        errorDescription = @"启用开发者模式失败。";
        break;
        case 184:
        errorDescription = @"应用安装成功，但有额外的加密二进制文件（如扩展、插件）。应用本身应该可以正常工作，但可能会遇到功能异常。";
        break;
        case 185:
        errorDescription = @"签名应用失败。CoreTrust 绕过返回了非零状态码。";
    }

    NSError* error = [NSError errorWithDomain:TrollStoreErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : errorDescription}];
    return error;
}

- (int)installIpa:(NSString*)pathToIpa force:(BOOL)force log:(NSString**)logOut
{
    NSMutableArray* args = [NSMutableArray new];
    [args addObject:@"install"];
    if(force)
    {
        [args addObject:@"force"];
    }
    NSNumber* installationMethodToUseNum = [trollStoreUserDefaults() objectForKey:@"installationMethod"];
    int installationMethodToUse = installationMethodToUseNum ? installationMethodToUseNum.intValue : 1;
    if(installationMethodToUse == 1)
    {
        [args addObject:@"custom"];
    }
    else
    {
        [args addObject:@"installd"];
    }
    [args addObject:pathToIpa];

    int ret = spawnRoot(rootHelperPath(), args, nil, logOut);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApplicationsChanged" object:nil];
    return ret;
}

- (int)installIpa:(NSString*)pathToIpa
{
    return [self installIpa:pathToIpa force:NO log:nil];
}

- (int)uninstallApp:(NSString*)appId
{
    if(!appId) return -200;

    NSMutableArray* args = [NSMutableArray new];
    [args addObject:@"uninstall"];

    NSNumber* uninstallationMethodToUseNum = [trollStoreUserDefaults() objectForKey:@"uninstallationMethod"];
    int uninstallationMethodToUse = uninstallationMethodToUseNum ? uninstallationMethodToUseNum.intValue : 0;
    if(uninstallationMethodToUse == 1)
    {
        [args addObject:@"custom"];
    }
    else
    {
        [args addObject:@"installd"];
    }

    [args addObject:appId];

    int ret = spawnRoot(rootHelperPath(), args, nil, nil);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApplicationsChanged" object:nil];
    return ret;
}

- (int)uninstallAppByPath:(NSString*)path
{
    if(!path) return -200;

    NSMutableArray* args = [NSMutableArray new];
    [args addObject:@"uninstall-path"];

    NSNumber* uninstallationMethodToUseNum = [trollStoreUserDefaults() objectForKey:@"uninstallationMethod"];
    int uninstallationMethodToUse = uninstallationMethodToUseNum ? uninstallationMethodToUseNum.intValue : 0;
    if(uninstallationMethodToUse == 1)
    {
        [args addObject:@"custom"];
    }
    else
    {
        [args addObject:@"installd"];
    }

    [args addObject:path];

    int ret = spawnRoot(rootHelperPath(), args, nil, nil);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApplicationsChanged" object:nil];
    return ret;
}

- (BOOL)openApplicationWithBundleID:(NSString *)appId
{
    return [[LSApplicationWorkspace defaultWorkspace] openApplicationWithBundleID:appId];
}

- (int)enableJITForBundleID:(NSString *)appId
{
    return spawnRoot(rootHelperPath(), @[@"enable-jit", appId], nil, nil);
}

- (int)changeAppRegistration:(NSString*)appPath toState:(NSString*)newState
{
    if(!appPath || !newState) return -200;
    return spawnRoot(rootHelperPath(), @[@"modify-registration", appPath, newState], nil, nil);
}

@end