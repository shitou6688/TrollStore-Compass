#import <UIKit/UIKit.h>

@class TSQRScannerViewController;

@protocol TSQRScannerViewControllerDelegate <NSObject>
- (void)qrScannerController:(TSQRScannerViewController*)scanner didScanResult:(NSString*)result;
- (void)qrScannerControllerDidCancel:(TSQRScannerViewController*)scanner;
@end

@interface TSQRScannerViewController : UIViewController

@property (nonatomic, weak) id<TSQRScannerViewControllerDelegate> delegate;

@end
