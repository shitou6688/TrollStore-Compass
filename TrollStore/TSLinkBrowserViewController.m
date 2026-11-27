#import "TSLinkBrowserViewController.h"

@import WebKit;

@interface TSLinkBrowserViewController () <WKNavigationDelegate, WKUIDelegate>
{
	NSURL* _startURL;
	BOOL _didEmit;
}

@property (nonatomic, strong) WKWebView* webView;
@property (nonatomic, strong) UIView* topBar;
@property (nonatomic, strong) UIProgressView* progressView;

@end

@implementation TSLinkBrowserViewController

- (instancetype)initWithURL:(NSURL*)url
{
	self = [super init];
	if(self)
	{
		_startURL = url;
		self.modalPresentationStyle = UIModalPresentationFullScreen;
	}
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];

	self.view.backgroundColor = [UIColor whiteColor];

	// 顶部栏
	_topBar = [[UIView alloc] init];
	_topBar.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1.0];
	_topBar.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:_topBar];

	UIButton* closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
	UIImage* closeImage = [UIImage systemImageNamed:@"xmark"];
	[closeButton setImage:closeImage ? closeImage : [UIImage imageNamed:@"xmark"] forState:UIControlStateNormal];
	closeButton.tintColor = [UIColor blackColor];
	closeButton.translatesAutoresizingMaskIntoConstraints = NO;
	[closeButton addTarget:self action:@selector(closePressed) forControlEvents:UIControlEventTouchUpInside];
	[_topBar addSubview:closeButton];

	UILabel* hintLabel = [[UILabel alloc] init];
	hintLabel.text = @"在页面中点击下载，自动提取安装";
	hintLabel.font = [UIFont systemFontOfSize:13];
	hintLabel.textColor = [UIColor colorWithWhite:0.3 alpha:1.0];
	hintLabel.textAlignment = NSTextAlignmentCenter;
	hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[_topBar addSubview:hintLabel];

	UIButton* safariButton = [UIButton buttonWithType:UIButtonTypeSystem];
	UIImage* safariImage = [UIImage systemImageNamed:@"safari"];
	[safariButton setImage:safariImage ? safariImage : [UIImage imageNamed:@"safari"] forState:UIControlStateNormal];
	safariButton.tintColor = [UIColor blackColor];
	safariButton.translatesAutoresizingMaskIntoConstraints = NO;
	[safariButton addTarget:self action:@selector(openInSafariPressed) forControlEvents:UIControlEventTouchUpInside];
	[_topBar addSubview:safariButton];

	_progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
	_progressView.translatesAutoresizingMaskIntoConstraints = NO;
	_progressView.hidden = YES;
	[self.view addSubview:_progressView];

	_webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:[[WKWebViewConfiguration alloc] init]];
	_webView.navigationDelegate = self;
	_webView.UIDelegate = self;
	_webView.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:_webView];

	[NSLayoutConstraint activateConstraints:@[
		[_topBar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[_topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[_topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[_topBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:40],

		[closeButton.leadingAnchor constraintEqualToAnchor:_topBar.leadingAnchor constant:14],
		[closeButton.centerYAnchor constraintEqualToAnchor:_topBar.bottomAnchor constant:-20],
		[closeButton.widthAnchor constraintEqualToConstant:34],
		[closeButton.heightAnchor constraintEqualToConstant:34],

		[hintLabel.centerXAnchor constraintEqualToAnchor:_topBar.centerXAnchor],
		[hintLabel.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],

		[safariButton.trailingAnchor constraintEqualToAnchor:_topBar.trailingAnchor constant:-14],
		[safariButton.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
		[safariButton.widthAnchor constraintEqualToConstant:34],
		[safariButton.heightAnchor constraintEqualToConstant:34],

		[_progressView.topAnchor constraintEqualToAnchor:_topBar.bottomAnchor],
		[_progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[_progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

		[_webView.topAnchor constraintEqualToAnchor:_progressView.bottomAnchor],
		[_webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[_webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[_webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
	]];

	[_webView addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:nil];

	if(_startURL)
	{
		[_webView loadRequest:[NSURLRequest requestWithURL:_startURL]];
	}
}

- (void)dealloc
{
	@try
	{
		[_webView removeObserver:self forKeyPath:@"estimatedProgress"];
	}
	@catch(NSException* e) {}
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if([keyPath isEqualToString:@"estimatedProgress"])
	{
		double progress = self.webView.estimatedProgress;
		self.progressView.hidden = progress >= 1.0;
		self.progressView.progress = progress;
	}
	else
	{
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

#pragma mark - Actions

- (void)closePressed
{
	[self dismissViewControllerAnimated:YES completion:^
	{
		if([self.delegate respondsToSelector:@selector(linkBrowserDidCancel:)])
		{
			[self.delegate linkBrowserDidCancel:self];
		}
	}];
}

- (void)openInSafariPressed
{
	NSURL* url = _webView.URL ?: _startURL;
	if(url)
	{
		[[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
	}
}

#pragma mark - File URL Detection

- (BOOL)isFileResponse:(NSURLResponse*)response
{
	NSString* mime = response.MIMEType.lowercaseString;
	if(![response isKindOfClass:[NSHTTPURLResponse class]]) return NO;

	NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
	NSString* disposition = @"";
	for(NSString* key in httpResponse.allHeaderFields)
	{
		if([key caseInsensitiveCompare:@"Content-Disposition"] == NSOrderedSame)
		{
			disposition = [httpResponse.allHeaderFields[key] lowercaseString] ?: @"";
			break;
		}
	}

	BOOL isFileMIME = [mime containsString:@"octet-stream"]
		|| [mime containsString:@"zip"]
		|| [mime containsString:@"ipa"]
		|| [mime containsString:@"force-download"]
		|| [mime containsString:@"ios-app"];

	BOOL isFileDisposition = [disposition containsString:@".ipa"]
		|| [disposition containsString:@".tipa"]
		|| ([disposition containsString:@"attachment"] && !([mime containsString:@"text/html"] || [mime containsString:@"json"]));

	return isFileMIME || isFileDisposition;
}

- (void)emitFileURL:(NSURL*)fileURL
{
	if(_didEmit || !fileURL) return;
	_didEmit = YES;

	// 把 WKWebView 里积累的 Cookie（如蓝奏云 acw_sc__v2 反爬 Cookie）同步到
	// 共享 Cookie 存储，这样安装下载请求（NSURLSession）能自动带上
	[[WKWebsiteDataStore defaultDataStore].httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie*>* cookies)
	{
		[[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookies:cookies forURL:fileURL mainDocumentURL:fileURL];

		dispatch_async(dispatch_get_main_queue(), ^
		{
			[self dismissViewControllerAnimated:YES completion:^
			{
				if([self.delegate respondsToSelector:@selector(linkBrowser:didDetectFileURL:)])
				{
					[self.delegate linkBrowser:self didDetectFileURL:fileURL];
				}
			}];
		});
	}];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView*)webView decidePolicyForNavigationAction:(WKNavigationAction*)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
	NSURL* url = navigationAction.request.URL;

	// 拦截 itms-services（在线安装协议，蒲公英/蓝奏云等分发页都用它）：
	// 解析 manifest plist 里的真实 ipa 直链，交给安装流程
	if(url && [url.scheme.lowercaseString isEqualToString:@"itms-services"])
	{
		decisionHandler(WKNavigationActionPolicyCancel);
		[self handleItmsServicesURL:url];
		return;
	}

	if(url && ([url.path.lowercaseString hasSuffix:@".ipa"] || [url.path.lowercaseString hasSuffix:@".tipa"]))
	{
		decisionHandler(WKNavigationActionPolicyCancel);
		[self emitFileURL:url];
		return;
	}

	decisionHandler(WKNavigationActionPolicyAllow);
}

// 解析 itms-services://?action=download-manifest&url=<plist 链接>
- (void)handleItmsServicesURL:(NSURL*)itmsURL
{
	NSString* query = itmsURL.query ?: @"";
	NSString* manifestParam = nil;

	for(NSURLQueryItem* item in [self queryItemsOf:query])
	{
		if([item.name.lowercaseString isEqualToString:@"url"])
		{
			manifestParam = item.value;
			break;
		}
	}

	if(manifestParam.length == 0)
	{
		return;
	}

	NSString* manifestURLString = [manifestParam stringByRemovingPercentEncoding] ?: manifestParam;
	NSURL* manifestURL = [NSURL URLWithString:manifestURLString];
	if(manifestURL && manifestURL.scheme.length == 0)
	{
		// 协议相对地址（//host/...）补 https
		manifestURL = [NSURL URLWithString:[@"https:" stringByAppendingString:manifestURLString]];
	}
	if(!manifestURL) return;

	// 把 WebView cookie 同步给 plist 域（部分分发服务器有 WAF）
	[[WKWebsiteDataStore defaultDataStore].httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie*>* cookies)
	{
		[[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookies:cookies forURL:manifestURL mainDocumentURL:manifestURL];

		NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:manifestURL];
		request.timeoutInterval = 20;
		// 部分分发平台（如蒲公英）的 manifest 接口只对系统安装器 UA 放行，
		// Safari/普通 UA 会返回 404 页面，这里伪装成 iOS 在线安装器的请求
		request.HTTPShouldHandleCookies = YES;
		[request setValue:@"itunesstored/1.0 iOS/17.5.1 model/iPhone15,2 hwp/a7010apn build/21F90 (6 dt:147)" forHTTPHeaderField:@"User-Agent"];
		[request setValue:@"text/xml,application/xml,*/*" forHTTPHeaderField:@"Accept"];

		NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error)
		{
			NSString* plistText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
			NSURL* ipaURL = [TSLinkBrowserViewController softwarePackageURLInPlistText:plistText];

			dispatch_async(dispatch_get_main_queue(), ^
			{
				if(ipaURL)
				{
					[self emitFileURL:ipaURL];
				}
				else
				{
					// 区分错误原因，给用户明确提示
					NSString* msg;
					if(error)
					{
						msg = [error localizedDescription];
					}
					else if([plistText containsString:@"software-package"])
					{
						msg = @"该应用限制了直接安装（可能需要注册设备或安装密码），无法提取安装包。可在页面中先完成设备验证后再试。";
					}
					else
					{
						msg = @"安装清单返回的不是有效内容（可能需要访问权限或已被限制）";
					}
					UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"解析失败"
						message:[NSString stringWithFormat:@"在线安装清单解析失败：\n%@", msg]
						preferredStyle:UIAlertControllerStyleAlert];
					[alert addAction:[UIAlertAction actionWithTitle:@"继续浏览" style:UIAlertActionStyleCancel handler:nil]];
					[self presentViewController:alert animated:YES completion:nil];
				}
			});
		}];
		[task resume];
	}];
}

- (NSArray<NSURLQueryItem*>*)queryItemsOf:(NSString*)queryString
{
	NSMutableArray* items = [NSMutableArray array];
	NSURLComponents* comps = [[NSURLComponents alloc] init];
	comps.query = queryString;
	if(comps.queryItems) return comps.queryItems;

	// 兜底手动解析
	if(queryString.length == 0) return items;
	for(NSString* pair in [queryString componentsSeparatedByString:@"&"])
	{
		NSRange eq = [pair rangeOfString:@"="];
		NSString* name = eq.location == NSNotFound ? pair : [pair substringToIndex:eq.location];
		NSString* value = eq.location == NSNotFound ? @"" : [pair substringFromIndex:eq.location + eq.length];
		[items addObject:[[NSURLQueryItem alloc] initWithName:name value:value]];
	}
	return items;
}

// 从 manifest plist 文本提取 software-package 的 url（兼容 CDATA 包裹）
+ (NSURL*)softwarePackageURLInPlistText:(NSString*)plistText
{
	if(plistText.length == 0) return nil;

	NSRange pkgRange = [plistText rangeOfString:@"software-package"];
	if(pkgRange.location == NSNotFound) return nil;

	NSString* tail = [plistText substringFromIndex:NSMaxRange(pkgRange)];
	// software-package 后的第一个 <string>...</string> 就是文件地址
	NSRange stringTag = [tail rangeOfString:@"<string>"];
	if(stringTag.location == NSNotFound) return nil;

	NSString* rest = [tail substringFromIndex:NSMaxRange(stringTag)];
	NSRange endTag = [rest rangeOfString:@"</string>"];
	if(endTag.location == NSNotFound) return nil;

	NSString* urlString = [rest substringToIndex:endTag.location];
	// 去掉 CDATA 包裹
	urlString = [urlString stringByReplacingOccurrencesOfString:@"<![CDATA[" withString:@""];
	urlString = [urlString stringByReplacingOccurrencesOfString:@"]]>" withString:@""];
	// 解码 XML 转义实体（部分平台不使用 CDATA 而是转义 & 等字符）
	urlString = [urlString stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
	urlString = [urlString stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
	urlString = [urlString stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
	urlString = [urlString stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
	urlString = [urlString stringByReplacingOccurrencesOfString:@"&apos;" withString:@"'"];
	urlString = [urlString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

	if(urlString.length == 0) return nil;
	return [NSURL URLWithString:urlString];
}

- (void)webView:(WKWebView*)webView decidePolicyForNavigationResponse:(WKNavigationResponse*)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
	if(!navigationResponse.canShowMIMEType || [self isFileResponse:navigationResponse.response])
	{
		NSURL* fileURL = navigationResponse.response.URL ?: webView.URL;
		decisionHandler(WKNavigationResponsePolicyCancel);
		[self emitFileURL:fileURL];
		return;
	}

	decisionHandler(WKNavigationResponsePolicyAllow);
}

#pragma mark - WKUIDelegate（target=_blank 链接在当前页打开）

- (WKWebView*)webView:(WKWebView*)webView createWebViewWithConfiguration:(WKWebViewConfiguration*)configuration forNavigationAction:(WKNavigationAction*)navigationAction windowFeatures:(WKWindowFeatures*)windowFeatures
{
	if(!navigationAction.request.URL) return nil;
	[webView loadRequest:navigationAction.request];
	return nil;
}

@end
