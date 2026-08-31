//
//  ROARootListController.m
//  随机开启app - 设置面板控制器
//
//  功能：
//   - "选择App"：可搜索、带图标的已安装应用表格
//   - "立即测试打开"：绕过时间段/每日限制，立即拉起目标 App
//   - 任一处设置变更都会通知 SpringBoard 上的调度器重算
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Preferences/Preferences.h>
#import <objc/runtime.h>

@interface ROARootListController : PSListController
@end

// ---- 可搜索 + 图标的 App 表格选择器 ----
@interface ROAAppPickerController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) void (^onSelect)(NSString *bid, NSString *name);
@end

@implementation ROARootListController

- (id)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
}

// 设置值变更时通知 SpringBoard 里的调度器立即重算
- (void)setPreferenceValue:(id)value specifier:(id)specifier {
    [super setPreferenceValue:value specifier:specifier];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)@"com.roa.randopenapp.changed",
                                         NULL, NULL, YES);
}

// 打开"立即测试"目标 App（发出通知，SpringBoard 调度器收到后打开）
- (void)testNow {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)@"com.roa.randopenapp.test",
                                         NULL, NULL, YES);
}

#pragma mark - 选择 App（可搜索 + 图标）

- (void)openAppPicker {
    ROAAppPickerController *picker = [[ROAAppPickerController alloc] initWithStyle:UITableViewStylePlain];
    __weak typeof(self) weakSelf = self;
    picker.onSelect = ^(NSString *bid, NSString *name) {
        [weakSelf setBundleID:bid name:name];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)setBundleID:(NSString *)bid name:(NSString *)name {
    if (bid.length == 0) return;
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.roa.randopenapp"];
    [prefs setObject:bid forKey:@"ROABundleID"];
    [prefs synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (CFStringRef)@"com.roa.randopenapp.changed",
                                         NULL, NULL, YES);
    [self reloadSpecifiers];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已选择目标 App"
                                                                   message:[NSString stringWithFormat:@"%@\n(%@)\n已写入配置。", name, bid]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 枚举已安装应用 -> @[@{@"id",@"name"}]
- (NSArray<NSDictionary *> *)enumerateApps {
    NSMutableArray<NSDictionary *> *apps = [NSMutableArray array];
    Class LSAppWorkspace = NSClassFromString(@"LSApplicationWorkspace");
    if (LSAppWorkspace) {
        id ws = [LSAppWorkspace performSelector:NSSelectorFromString(@"defaultWorkspace")];
        if (ws) {
            id installed = [ws performSelector:NSSelectorFromString(@"allInstalledApplications")];
            for (id app in installed) {
                NSString *bid = nil;
                NSString *name = nil;
                @try { bid = [app valueForKey:@"bundleIdentifier"]; } @catch (NSException *e) {}
                @try { name = [app valueForKey:@"localizedName"]; } @catch (NSException *e) {}
                if (bid.length && name.length) {
                    [apps addObject:@{@"id": bid, @"name": name}];
                }
            }
        }
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];
    return apps;
}

@end

// =====================================================================
//  ROAAppPickerController —— 可搜索、带图标的 App 表格选择器
// =====================================================================

@implementation ROAAppPickerController {
    NSArray<NSDictionary *> *_allApps;      // 已安装应用
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    self = [super initWithStyle:style];
    if (self) {
        self.title = @"选择App";
        // 枚举全部已安装应用
        NSMutableArray *apps = [NSMutableArray array];
        Class LSAppWorkspace = NSClassFromString(@"LSApplicationWorkspace");
        if (LSAppWorkspace) {
            id ws = [LSAppWorkspace performSelector:NSSelectorFromString(@"defaultWorkspace")];
            if (ws) {
                id installed = [ws performSelector:NSSelectorFromString(@"allInstalledApplications")];
                for (id app in installed) {
                    NSString *bid = nil, *name = nil;
                    @try { bid = [app valueForKey:@"bundleIdentifier"]; } @catch (NSException *e) {}
                    @try { name = [app valueForKey:@"localizedName"]; } @catch (NSException *e) {}
                    if (bid.length && name.length) {
                        NSData *iconData = [self iconDataForLSApplication:app];
                        [apps addObject:@{@"id": bid, @"name": name,
                                          @"icon": iconData ?: [NSNull null]}];
                    }
                }
            }
        }
        [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
        }];
        _allApps = apps;
        _onSelect = nil;
    }
    return self;
}

// 从 LSApplicationProxy 读取图标 PNG 数据
- (NSData *)iconDataForLSApplication:(id)proxy {
    NSData *data = nil;
    @try {
        data = [proxy performSelector:NSSelectorFromString(@"iconDataForVariant:scale:")
                           withObject:@(2) withObject:@(2)];
        if (!data) {
            NSDictionary *icons = [proxy valueForKey:@"primitiveIconsDictionary"];
            data = icons[@"128"];
            if (!data) data = [icons allValues].firstObject;
        }
    } @catch (NSException *e) {
        data = nil;
    }
    return data;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];

    // 搜索栏
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                                              style:UIBarButtonItemStyleDone
                                                             target:self
                                                             action:@selector(close)];
    self.navigationItem.leftBarButtonItem = close;
//    self.navigationItem.rightBarButtonItem = done;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
}

- (void)close {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self.tableView reloadData];
}

// 按搜索词过滤
- (NSArray<NSDictionary *> *)filteredApps {
    NSString *q = self.navigationItem.searchController.searchBar.text;
    if (q.length == 0) return _allApps;
    q = [q lowercaseString];
    NSMutableArray *res = [NSMutableArray array];
    for (NSDictionary *app in _allApps) {
        NSString *name = [app[@"name"] lowercaseString];
        NSString *bid  = [app[@"id"] lowercaseString];
        if ([name containsString:q] || [bid containsString:q]) {
            [res addObject:app];
        }
    }
    return res;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self filteredApps].count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 56;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"AppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    }
    NSDictionary *app = [self filteredApps][indexPath.row];
    cell.textLabel.text = app[@"name"];
    cell.detailTextLabel.text = app[@"id"];
    cell.imageView.image = nil;
    NSData *iconData = app[@"icon"];
    if ([iconData isKindOfClass:[NSData class]] && iconData.length) {
        UIImage *img = [UIImage imageWithData:iconData];
        // 统一缩略图尺寸
        cell.imageView.image = img;
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *app = [self filteredApps][indexPath.row];
    if (self.onSelect) {
        self.onSelect(app[@"id"], app[@"name"]);
    }
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

@end