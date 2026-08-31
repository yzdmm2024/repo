//
//  ROARootListController.m
//  随机开启app - 设置面板控制器
//
//  功能：
//   - "选择App"按钮：动态枚举已安装应用，弹出选择列表
//   - 选择后写入 ROABundleID 配置
//

#import <Preferences/Preferences.h>
#import <objc/runtime.h>

static NSBundle *gBundle = nil;

@interface ROARootListController : PSListController
- (void)openAppPicker;
@end

@implementation ROARootListController

- (id)specifiers {
    if (_specifiers == nil) {
        if (!gBundle) {
            NSBundle *b = [NSBundle bundleWithIdentifier:@"com.roa.randopenapp.settings"];
            if (!b) { // fallback: 从当前 controller 推断
                NSArray *components = [[self bundle] bundlePath].pathComponents;
                if (components.count > 0 && [components[components.count-1] hasSuffix:@".bundle"]) {
                    b = [NSBundle bundleWithPath:[self bundle].bundlePath];
                }
            }
            gBundle = b ?: [NSBundle mainBundle];
        }
        NSArray *loaded = [gBundle objectForInfoDictionaryKey:@"items"]
                        ?: [NSArray arrayWithContentsOfFile:[gBundle pathForResource:@"Root" ofType:@"plist"]];
        // Root.plist 是 preferences plist 格式，取 items 键
        self.customSpecifiers = loaded ? [self specifiersFromPlist:loaded] : [NSArray array];
    }
    return _specifiers;
}

// 从 plist 的 items 数组构建 specifiers
- (NSArray *)specifiersFromPlist:(NSArray *)items {
    NSMutableArray *specs = [NSMutableArray array];
    for (NSDictionary *dict in items) {
        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:dict[@"label"]
                                                           target:self
                                                              set:NULL
                                                              get:NULL
                                                           detail:nil
                                                             cell:dict[@"cell"]
                                                             edit:nil];
        if ([dict[@"cell"] isKindOfClass:[NSString class]]) {
            NSString *cell = dict[@"cell"];
            if ([cell isEqualToString:@"PSSwitchCell"] || [cell isEqualToString:@"PSEditTextCell"]) {
                // 绑定 defaults/key
                [spec setProperty:dict[@"defaults"] forKey:@"defaults"];
                [spec setProperty:dict[@"key"] forKey:@"key"];
                if (dict[@"default"]) [spec setProperty:dict[@"default"] forKey:@"default"];
                if (cell == nil) {}
            }
            [spec setProperty:dict[@"keyboardType"] ?: @"" forKey:@"keyboardType"];
        }
        if (dict[@"action"]) {
            [spec setButtonAction:NSSelectorFromString(dict[@"action"])];
        }
        if (dict[@"footerText"]) {
            [spec setProperty:dict[@"footerText"] forKey:@"footerText"];
        }
        [specs addObject:spec];
    }
    return specs;
}

#pragma mark - 选择 App

- (void)openAppPicker {
    // 枚举已安装应用
    NSMutableArray<NSDictionary *> *apps = [NSMutableArray array];

    id LSAppWorkspace = NSClassFromString(@"LSApplicationWorkspace");
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

    if (apps.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未获取到应用"
                                                                       message:@"无法枚举已安装应用，请手动填写 Bundle ID。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // 按名称排序
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择要随机开启的App"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *app in apps) {
        NSString *title = [NSString stringWithFormat:@"%@ (%@)", app[@"name"], app[@"id"]];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
                                                    [self setBundleID:app[@"id"]];
                                                }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 需要 popover
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        sheet.modalPresentationStyle = UIModalPresentationPopover;
        UIPopoverPresentationController *pop = sheet.popoverPresentationController;
        pop.sourceView = self.view;
        pop.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
        pop.permittedArrowDirections = 0;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)setBundleID:(NSString *)bid {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.roa.randopenapp"];
    [prefs setObject:bid forKey:@"ROABundleID"];
    [prefs synchronize];
    [self reloadSpecifiers];
    // 提示
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已选择"
                                                                   message:[NSString stringWithFormat:@"目标 App：%@\n已自动写入当前 Bundle ID。", bid]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end