#import <UIKit/UIKit.h>
#import "TSAppInfo.h"
#import "TSQRScannerViewController.h"
#import "TSLinkBrowserViewController.h"
#import <CoreServices.h>

@interface TSAppTableViewController : UITableViewController <UISearchResultsUpdating, UIDocumentPickerDelegate, LSApplicationWorkspaceObserverProtocol, TSQRScannerViewControllerDelegate, TSLinkBrowserViewControllerDelegate>
{
    UIImage* _placeholderIcon;
    NSArray<TSAppInfo*>* _cachedAppInfos;
    NSMutableDictionary* _cachedIcons;
    UISearchController* _searchController;
	NSString* _searchKey;
}

@end