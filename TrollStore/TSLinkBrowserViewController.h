#import <UIKit/UIKit.h>

@class TSLinkBrowserViewController;

@protocol TSLinkBrowserViewControllerDelegate <NSObject>
- (void)linkBrowser:(TSLinkBrowserViewController*)browser didDetectFileURL:(NSURL*)fileURL;
@optional
- (void)linkBrowserDidCancel:(TSLinkBrowserViewController*)browser;
@end

@interface TSLinkBrowserViewController : UIViewController

- (instancetype)initWithURL:(NSURL*)url;
@property (nonatomic, weak) id<TSLinkBrowserViewControllerDelegate> delegate;

@end
