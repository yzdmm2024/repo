//
//  Tweak.xm
//  随机开启app - 在设定时间段内随机拉起目标 App，每天只开一次
//
//  注入目标：SpringBoard（锁屏/前台均常驻，最适合后台调度）
//  架构：roothide (Relaxin) 兼容，ARC 关闭（Theos 默认用 libobjc 手动管理，这里用 modern rt，配合 -fobjc-arc 亦可）
//

#import <Foundation/Foundation.h>
#import "ROARandomScheduler.h"

// 在 SpringBoard 启动完成后启动调度器
static void __attribute__((constructor)) roa_init(void) {
    // 延迟到 SpringBoard 完全就绪再启动
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[ROARandomScheduler sharedInstance] start];
    });    
}