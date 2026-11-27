#import "TSQRScannerViewController.h"

@import AVFoundation;
@import AudioToolbox;

@interface TSQRScannerViewController () <AVCaptureMetadataOutputObjectsDelegate>
{
	AVCaptureSession* _captureSession;
	AVCaptureDeviceInput* _deviceInput;
	AVCaptureMetadataOutput* _metadataOutput;
	AVCaptureVideoPreviewLayer* _previewLayer;
	UIView* _overlayView;
	CALayer* _scanUILayer;
	UILabel* _hintLabel;
	UIButton* _torchButton;
	UIButton* _closeButton;
	BOOL _hasScanned;
	BOOL _sessionConfigured;
	BOOL _torchOn;
}

@end

@implementation TSQRScannerViewController

- (void)viewDidLoad
{
	[super viewDidLoad];

	self.view.backgroundColor = [UIColor blackColor];
	self.modalPresentationStyle = UIModalPresentationFullScreen;

	[self setupOverlayUI];
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];

	_hasScanned = NO;
	[self requestCameraAccessAndStart];
}

- (void)viewWillDisappear:(BOOL)animated
{
	[super viewWillDisappear:animated];

	if(_captureSession.isRunning)
	{
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
		{
			[_captureSession stopRunning];
		});
	}
}

- (void)dealloc
{
	if(_captureSession && _captureSession.isRunning)
	{
		[_captureSession stopRunning];
	}
}

#pragma mark - UI

- (void)setupOverlayUI
{
	// 顶部标题栏
	UIView* topBar = [[UIView alloc] init];
	topBar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
	topBar.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:topBar];

	UILabel* titleLabel = [[UILabel alloc] init];
	titleLabel.text = @"扫码安装";
	titleLabel.textColor = [UIColor whiteColor];
	titleLabel.font = [UIFont boldSystemFontOfSize:17];
	titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[topBar addSubview:titleLabel];

	_closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
	UIImage* closeImage = [UIImage systemImageNamed:@"xmark"];
	if(!closeImage)
	{
		closeImage = [UIImage imageNamed:@"xmark"];
	}
	[_closeButton setImage:closeImage forState:UIControlStateNormal];
	_closeButton.tintColor = [UIColor whiteColor];
	_closeButton.translatesAutoresizingMaskIntoConstraints = NO;
	[_closeButton addTarget:self action:@selector(closePressed) forControlEvents:UIControlEventTouchUpInside];
	[topBar addSubview:_closeButton];

	_torchButton = [UIButton buttonWithType:UIButtonTypeSystem];
	UIImage* torchImage = [UIImage systemImageNamed:@"flashlight.off.fill"];
	if(!torchImage)
	{
		torchImage = [UIImage imageNamed:@"flashlight.off.fill"];
	}
	[_torchButton setImage:torchImage forState:UIControlStateNormal];
	_torchButton.tintColor = [UIColor whiteColor];
	_torchButton.translatesAutoresizingMaskIntoConstraints = NO;
	[_torchButton addTarget:self action:@selector(torchPressed) forControlEvents:UIControlEventTouchUpInside];
	[topBar addSubview:_torchButton];

	// 半透明遮罩 + 扫描取景框
	_overlayView = [[UIView alloc] init];
	_overlayView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
	_overlayView.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:_overlayView];

	// 提示文字
	_hintLabel = [[UILabel alloc] init];
	_hintLabel.text = @"对准应用下载二维码即可自动安装";
	_hintLabel.textColor = [UIColor whiteColor];
	_hintLabel.font = [UIFont systemFontOfSize:14];
	_hintLabel.textAlignment = NSTextAlignmentCenter;
	_hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:_hintLabel];

	[NSLayoutConstraint activateConstraints:@[
		[topBar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[topBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:44],

		[titleLabel.centerXAnchor constraintEqualToAnchor:topBar.centerXAnchor],
		[titleLabel.centerYAnchor constraintEqualToAnchor:_closeButton.centerYAnchor],

		[_closeButton.leadingAnchor constraintEqualToAnchor:topBar.leadingAnchor constant:16],
		[_closeButton.centerYAnchor constraintEqualToAnchor:topBar.bottomAnchor constant:-22],
		[_closeButton.widthAnchor constraintEqualToConstant:34],
		[_closeButton.heightAnchor constraintEqualToConstant:34],

		[_torchButton.trailingAnchor constraintEqualToAnchor:topBar.trailingAnchor constant:-16],
		[_torchButton.centerYAnchor constraintEqualToAnchor:_closeButton.centerYAnchor],
		[_torchButton.widthAnchor constraintEqualToConstant:34],
		[_torchButton.heightAnchor constraintEqualToConstant:34],

		[_overlayView.topAnchor constraintEqualToAnchor:topBar.bottomAnchor],
		[_overlayView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[_overlayView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[_overlayView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

		[_hintLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
		[_hintLabel.topAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:120],
	]];
}

// 绘制扫描取景框（镂空方框 + 四角高亮边框 + 扫描线）
- (void)viewDidLayoutSubviews
{
	[super viewDidLayoutSubviews];

	// 预览层跟随视图尺寸（适配旋转）
	if(_previewLayer)
	{
		_previewLayer.frame = self.view.bounds;
	}

	if(!_scanUILayer)
	{
		_scanUILayer = [CALayer layer];
		[self.view.layer addSublayer:_scanUILayer];
	}
	[_scanUILayer setNeedsLayout];
	[_scanUILayer.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];

	CGFloat scanSize = MIN(self.view.bounds.size.width, self.view.bounds.size.height) * 0.68;
	CGRect scanRect = CGRectMake((self.view.bounds.size.width - scanSize) / 2.0,
								(self.view.bounds.size.height - scanSize) / 2.0 - 30,
								scanSize,
								scanSize);

	// 遮罩：overlayView 半透明黑底，用镂空 shape 作为 mask，中间透出预览画面
	CAShapeLayer* maskLayer = [CAShapeLayer layer];
	UIBezierPath* fullPath = [UIBezierPath bezierPathWithRect:self.view.bounds];
	UIBezierPath* holePath = [UIBezierPath bezierPathWithRoundedRect:scanRect cornerRadius:12];
	[fullPath appendPath:holePath];
	maskLayer.path = fullPath.CGPath;
	maskLayer.fillRule = kCAFillRuleEvenOdd;
	maskLayer.fillColor = [UIColor whiteColor].CGColor;
	_overlayView.layer.mask = maskLayer;

	// 四角边框
	CGFloat cornerLen = 28;
	CGFloat radius = 12;
	UIColor* cornerColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
	UIBezierPath* cornersPath = [UIBezierPath bezierPath];

	// 左上
	[cornersPath moveToPoint:CGPointMake(scanRect.origin.x, scanRect.origin.y + radius + cornerLen)];
	[cornersPath addLineToPoint:CGPointMake(scanRect.origin.x, scanRect.origin.y + radius)];
	[cornersPath addQuadCurveToPoint:CGPointMake(scanRect.origin.x + radius, scanRect.origin.y)
						controlPoint:CGPointMake(scanRect.origin.x, scanRect.origin.y)];
	[cornersPath addLineToPoint:CGPointMake(scanRect.origin.x + radius + cornerLen, scanRect.origin.y)];

	// 右上
	[cornersPath moveToPoint:CGPointMake(scanRect.origin.x + scanRect.size.width - radius - cornerLen, scanRect.origin.y)];
	[cornersPath addLineToPoint:CGPointMake(scanRect.origin.x + scanRect.size.width - radius, scanRect.origin.y)];
	[cornersPath addQuadCurveToPoint:CGPointMake(scanRect.origin.x + scanRect.size.width, scanRect.origin.y + radius)
						controlPoint:CGPointMake(scanRect.origin.x + scanRect.size.width, scanRect.origin.y)];
	[cornersPath addLineToPoint:CGPointMake(scanRect.origin.x + scanRect.size.width, scanRect.origin.y + radius + cornerLen)];

	// 右下
	[cornersPath moveToPoint:CGPointMake(scanRect.origin.x + scanRect.size.width, scanRect.origin.y + scanRect.size.height - radius - cornerLen)];
	[cornersPath addLineToPoint:CGPointMake(scanRect.origin.x + scanRect.size.width, scanRect.origin.y + scanRect.size.height - radius)];
	[cornersPath addQuadCurveToPoint:CGPointMake(scanRect.origin.x + scanRect.size.width - radius, scanRect.origin.y + scanRect.size.height)
						controlPoint:CGPointMake(scanRect.origin.x + scanRect.size.width, scanRect.origin.y + scanRect.size.height)];
	[cornersPath addLineToPoint:CGPointMake(scanRect.origin.x + scanRect.size.width - radius - cornerLen, scanRect.origin.y + scanRect.size.height)];

	// 左下
	[cornersPath moveToPoint:CGPointMake(scanRect.origin.x + radius + cornerLen, scanRect.origin.y + scanRect.size.height)];
	[cornersPath addLineToPoint:CGPointMake(scanRect.origin.x + radius, scanRect.origin.y + scanRect.size.height)];
	[cornersPath addQuadCurveToPoint:CGPointMake(scanRect.origin.x, scanRect.origin.y + scanRect.size.height - radius)
						controlPoint:CGPointMake(scanRect.origin.x, scanRect.origin.y + scanRect.size.height)];
	[cornersPath addLineToPoint:CGPointMake(scanRect.origin.x, scanRect.origin.y + scanRect.size.height - radius - cornerLen)];

	CAShapeLayer* cornersLayer = [CAShapeLayer layer];
	cornersLayer.path = cornersPath.CGPath;
	cornersLayer.strokeColor = cornerColor.CGColor;
	cornersLayer.fillColor = [UIColor clearColor].CGColor;
	cornersLayer.lineWidth = 4;
	cornersLayer.lineCap = kCALineCapRound;
	[_scanUILayer addSublayer:cornersLayer];

	// 动画扫描线
	CALayer* lineLayer = [CALayer layer];
	lineLayer.frame = CGRectMake(scanRect.origin.x + 8, scanRect.origin.y + 8, scanRect.size.width - 16, 2);
	lineLayer.backgroundColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.40 alpha:0.9].CGColor;
	lineLayer.cornerRadius = 1;
	CABasicAnimation* scanAnim = [CABasicAnimation animationWithKeyPath:@"position.y"];
	scanAnim.fromValue = @(scanRect.origin.y + 9);
	scanAnim.toValue = @(scanRect.origin.y + scanRect.size.height - 9);
	scanAnim.duration = 1.6;
	scanAnim.autoreverses = YES;
	scanAnim.repeatCount = HUGE_VALF;
	[lineLayer addAnimation:scanAnim forKey:@"scanLine"];
	[_scanUILayer addSublayer:lineLayer];
}

#pragma mark - Camera

- (void)requestCameraAccessAndStart
{
	AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];

	switch(status)
	{
		case AVAuthorizationStatusAuthorized:
		{
			[self configureAndStartSession];
			break;
		}
		case AVAuthorizationStatusNotDetermined:
		{
			[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted)
			{
				dispatch_async(dispatch_get_main_queue(), ^
				{
					if(granted)
					{
						[self configureAndStartSession];
					}
					else
					{
						[self showPermissionDeniedAlert];
					}
				});
			}];
			break;
		}
		default:
		{
			[self showPermissionDeniedAlert];
			break;
		}
	}
}

- (void)showPermissionDeniedAlert
{
	// viewWillAppear 阶段视图尚未进入层级，立即 present 会被 UIKit 拒绝，稍等视图就绪后再弹
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^
	{
		if(!self.view.window) return;

		UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"无法访问相机"
			message:@"扫码安装需要相机权限，请在系统设置中允许巨魔商店访问相机。"
			preferredStyle:UIAlertControllerStyleAlert];

	UIAlertAction* settingsAction = [UIAlertAction actionWithTitle:@"前往设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action)
	{
		NSURL* settingsURL = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
		if(settingsURL)
		{
			[[UIApplication sharedApplication] openURL:settingsURL options:@{} completionHandler:nil];
		}
		[self dismissScanViewControllerAnimated:YES];
	}];
	[alert addAction:settingsAction];

	UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
	{
		[self dismissScanViewControllerAnimated:YES];
	}];
	[alert addAction:cancelAction];

	[self presentViewController:alert animated:YES completion:nil];
	});
}

- (void)configureAndStartSession
{
	if(_sessionConfigured)
	{
		if(!_captureSession.isRunning)
		{
			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
			{
				[_captureSession startRunning];
			});
		}
		return;
	}

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
	{
		_captureSession = [[AVCaptureSession alloc] init];

		AVCaptureDevice* device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
		if(!device)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self showNoCameraAlert];
			});
			return;
		}

		NSError* error = nil;
		_deviceInput = [[AVCaptureDeviceInput alloc] initWithDevice:device error:&error];
		if(!_deviceInput || error)
		{
			dispatch_async(dispatch_get_main_queue(), ^
			{
				[self showNoCameraAlert];
			});
			return;
		}

		if([_captureSession canAddInput:_deviceInput])
		{
			[_captureSession addInput:_deviceInput];
		}

		_metadataOutput = [[AVCaptureMetadataOutput alloc] init];
		if([_captureSession canAddOutput:_metadataOutput])
		{
			[_captureSession addOutput:_metadataOutput];
			dispatch_queue_t metadataQueue = dispatch_queue_create("com.opa334.trollstore.qrscanner", DISPATCH_QUEUE_SERIAL);
			[_metadataOutput setMetadataObjectsDelegate:self queue:metadataQueue];
			NSMutableArray* availableTypes = [NSMutableArray arrayWithArray:_metadataOutput.availableMetadataObjectTypes];
			if([availableTypes containsObject:AVMetadataObjectTypeQRCode])
			{
				[_metadataOutput setMetadataObjectTypes:@[AVMetadataObjectTypeQRCode]];
			}
			else if(availableTypes.count)
			{
				[_metadataOutput setMetadataObjectTypes:availableTypes];
			}
		}

		_previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:_captureSession];
		_previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

		dispatch_async(dispatch_get_main_queue(), ^
		{
			_previewLayer.frame = self.view.bounds;
			[self.view.layer insertSublayer:_previewLayer atIndex:0];
		});

		_sessionConfigured = YES;

		[_captureSession startRunning];
	});
}

- (void)showNoCameraAlert
{
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"相机不可用"
		message:@"未检测到可用的摄像头设备。"
		preferredStyle:UIAlertControllerStyleAlert];

	[alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action)
	{
		[self dismissScanViewControllerAnimated:YES];
	}]];

	[self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Actions

- (void)closePressed
{
	[self dismissScanViewControllerAnimated:YES];
	if([self.delegate respondsToSelector:@selector(qrScannerControllerDidCancel:)])
	{
		[self.delegate qrScannerControllerDidCancel:self];
	}
}

- (void)torchPressed
{
	if(!_deviceInput || !_deviceInput.device.hasTorch) return;

	AVCaptureDevice* device = _deviceInput.device;
	NSError* error = nil;
	if([device lockForConfiguration:&error])
	{
		_torchOn = !_torchOn;
		if(_torchOn)
		{
			device.torchMode = AVCaptureTorchModeOn;
			UIImage* onImage = [UIImage systemImageNamed:@"flashlight.on.fill"];
			if(onImage) [_torchButton setImage:onImage forState:UIControlStateNormal];
		}
		else
		{
			device.torchMode = AVCaptureTorchModeOff;
			UIImage* offImage = [UIImage systemImageNamed:@"flashlight.off.fill"];
			if(offImage) [_torchButton setImage:offImage forState:UIControlStateNormal];
		}
		[device unlockForConfiguration];
	}
}

- (void)dismissScanViewControllerAnimated:(BOOL)animated
{
	dispatch_async(dispatch_get_main_queue(), ^
	{
		[self dismissViewControllerAnimated:animated completion:nil];
	});
}

#pragma mark - AVCaptureMetadataOutputObjectsDelegate

- (void)captureOutput:(AVCaptureMetadataOutput*)output didOutputMetadataObjects:(NSArray<AVMetadataObject*>*)metadataObjects fromConnection:(AVCaptureConnection*)connection
{
	if(_hasScanned) return;

	for(AVMetadataObject* metadataObject in metadataObjects)
	{
		if([metadataObject isKindOfClass:[AVMetadataMachineReadableCodeObject class]])
		{
			AVMetadataMachineReadableCodeObject* codeObject = (AVMetadataMachineReadableCodeObject*)metadataObject;
			if([codeObject.type isEqualToString:AVMetadataObjectTypeQRCode] && codeObject.stringValue.length > 0)
			{
				_hasScanned = YES;

				NSString* result = [codeObject.stringValue copy];

				dispatch_async(dispatch_get_main_queue(), ^
				{
					AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
					// stopRunning 是阻塞调用，放后台线程避免卡主线程
					dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
					{
						[_captureSession stopRunning];
					});

					if([self.delegate respondsToSelector:@selector(qrScannerController:didScanResult:)])
					{
						[self.delegate qrScannerController:self didScanResult:result];
					}
				});
				break;
			}
		}
	}
}

@end
