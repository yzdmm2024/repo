//
//  ADHelper.m
//  AppData
//
//  Created by Fouad Raheb on 6/29/20.
//

#import "ADHelper.h"

@interface ADHelper ()
@property (nonatomic, strong) NSBundle *resoucesBundle;
@end

@implementation ADHelper

+ (instancetype)sharedInstance {
    static dispatch_once_t p = 0;
    __strong static ADHelper *_sharedInstance = nil;
    dispatch_once(&p, ^{
        _sharedInstance = [[self alloc] init];
        // Create resources bundle
        // [rootless] 无根越狱 (Dopamine/roothide) 文件系统挂载在 /var/jb
        _sharedInstance.resoucesBundle = [NSBundle bundleWithPath:@"/var/jb/Library/Application Support/AppData/Resources.bundle"];
    });
    return _sharedInstance;
}

#pragma mark - Resources

+ (UIImage *)imageNamed:(NSString *)imageName {
    return [UIImage imageNamed:imageName inBundle:ADHelper.sharedInstance.resoucesBundle];
}

#pragma mark - Helpers

+ (void)openDirectoryAtURL:(NSURL *)url fromController:(UIViewController *)controller {
    NSString *path = [url.path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    // [Fila] 原为 Filza(filza://view<path>) / iFile，现改用 Fila (wiki.qaq.fila)。
    // Fila scheme: fila://open?path=<path> 直接打开该目录。
    if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"fila://"]]) {
        NSURL *filaURL = [NSURL URLWithString:[@"fila://open?path=" stringByAppendingString:path]];
        [[UIApplication sharedApplication] openURL:filaURL options:@{} completionHandler:nil];
    } else {
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"AppData" message:@"Install Fila app to open the selected directory" preferredStyle:UIAlertControllerStyleAlert];
        [alertController addAction:[UIAlertAction actionWithTitle:@"Okay" style:UIAlertActionStyleDefault handler:nil]];
        [controller presentViewController:alertController animated:YES completion:nil];
    }
}

+ (SBSApplicationShortcutItem *)applicationShortcutItem {
    SBSApplicationShortcutItem *shortcutItem = [[NSClassFromString(@"SBSApplicationShortcutItem") alloc] init];
    shortcutItem.localizedTitle = @"AppData";
    shortcutItem.type = kSBApplicationShortcutItemType;
    
    NSData *imageData = nil;
    if (@available(iOS 13, *)) {
        if ([UITraitCollection currentTraitCollection].userInterfaceStyle == UIUserInterfaceStyleDark) {
            imageData = UIImagePNGRepresentation([[self imageNamed:@"AppDataIconWhite"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]);
        } else {
            imageData = UIImagePNGRepresentation([[self imageNamed:@"AppDataIcon"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]);
        }
    } else {
        imageData = UIImagePNGRepresentation([[self imageNamed:@"AppDataIcon12"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]);
    }
    if (imageData) {
        SBSApplicationShortcutCustomImageIcon *iconImage = [[NSClassFromString(@"SBSApplicationShortcutCustomImageIcon") alloc] initWithImagePNGData:imageData];
        [shortcutItem setIcon:iconImage];
    }
    return shortcutItem;
}

@end
