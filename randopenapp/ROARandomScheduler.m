//
//  ROARandomScheduler.m
//  随机开启app - 随机调度引擎实现
//
//  逻辑：
//   - 读取 NSUserDefaults 中的配置（启用开关、目标 BundleID、时间段、仅工作日）
//   - 在天窗口的起始点，随机选一个"目标时刻"（时间段内的随机分钟）
//   - 用一个 30s 定时器轮询，判断是否到达目标时刻
//   - 到达后用 LSApplicationWorkspace 拉起目标 App，并写入"今日已开"标记
//   - 只有当天未开过、且（若开启）是工作日时才可能触发
//

#import "ROARandomScheduler.h"
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// ===== 配置键（与 PreferenceBundle 保持一致）=====
static NSString *const kROAEnabled   = @"ROAEnabled";
static NSString *const kROABundleID  = @"ROABundleID";
static NSString *const kROAStartH    = @"ROAStartHour";
static NSString *const kROAStartM    = @"ROAStartMinute";
static NSString *const kROAEndH      = @"ROAEndHour";
static NSString *const kROAEndM      = @"ROAEndMinute";
static NSString *const kROAWorkdays  = @"ROAWorkdaysOnly";

static NSString *const kROALastOpenDate = @"ROALastOpenDay";      // "yyyyMMdd"
static NSString *const kROAPrefsDomain  = @"com.roa.randopenapp"; // 与 bundle id 一致

// 设置面板改动后的跨进程回调（在 start/stop 中注册/移除）
static void roa_settingsChanged(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ROARandomScheduler *s = (__bridge ROARandomScheduler *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [s reloadSettings];
    });
}

// "立即测试打开"通知（来自设置面板的测试按钮）
static void roa_testRequest(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ROARandomScheduler *s = (__bridge ROARandomScheduler *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [s openForTest];
    });
}

@implementation ROARandomScheduler {
    NSTimer *_pollTimer;
    NSDate  *_targetDate;
    NSString *_todayKey;
}

+ (ROARandomScheduler *)sharedInstance {
    static ROARandomScheduler *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ROARandomScheduler alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _todayKey = [self dayKeyForDate:[NSDate date]];
    }
    return self;
}

#pragma mark - 启动 / 停止

- (void)start {
    [self stop];
    [self computeTargetIfNeeded];
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                   target:self
                                                 selector:@selector(tick)
                                                 userInfo:nil
                                                  repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_pollTimer forMode:NSRunLoopCommonModes];

    // 监听设置面板变更通知（跨进程）
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    roa_settingsChanged,
                                    (CFStringRef)@"com.roa.randopenapp.changed",
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    // 监听"立即测试打开"通知
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    roa_testRequest,
                                    (CFStringRef)@"com.roa.randopenapp.test",
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    NSLog(@"[ROA] scheduler started.");
}

- (void)stop {
    [_pollTimer invalidate];
    _pollTimer = nil;
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       (__bridge const void *)self,
                                       (CFStringRef)@"com.roa.randopenapp.changed",
                                       NULL);
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       (__bridge const void *)self,
                                       (CFStringRef)@"com.roa.randopenapp.test",
                                       NULL);
}

- (void)reloadSettings {
    // 设置可能已变，重算目标
    _targetDate = nil;
    _todayKey = [self dayKeyForDate:[NSDate date]];
    [self computeTargetIfNeeded];
}

#pragma mark - 读取设置

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:kROAPrefsDomain];
}

- (BOOL)isEnabled {
    return [[self prefs] boolForKey:kROAEnabled];
}

- (NSString *)targetBundleID {
    NSString *b = [[self prefs] stringForKey:kROABundleID];
    return (b.length > 0) ? b : nil;
}

- (NSInteger)startHour  { return [[self prefs] integerForKey:kROAStartH]; }
- (NSInteger)startMin   { return [[self prefs] integerForKey:kROAStartM]; }
- (NSInteger)endHour    { return [[self prefs] integerForKey:kROAEndH]; }
- (NSInteger)endMin     { return [[self prefs] integerForKey:kROAEndM]; }
- (BOOL)workdaysOnly    { return [[self prefs] boolForKey:kROAWorkdays]; }

#pragma mark - 日期工具

- (NSString *)dayKeyForDate:(NSDate *)date {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd";
    return [fmt stringFromDate:date];
}

- (BOOL)isWorkdayForDate:(NSDate *)date {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSInteger wd = [cal component:NSCalendarUnitWeekday fromDate:date]; // 1=周日
    return (wd != 1 && wd != 7);
}

- (NSInteger)minutesForHour:(NSInteger)h minute:(NSInteger)m {
    return h * 60 + m;
}

#pragma mark - 调度计算

- (void)computeTargetIfNeeded {
    if (_targetDate != nil) return;

    _todayKey = [self dayKeyForDate:[NSDate date]];

    // 已启用？
    if (![self isEnabled]) { NSLog(@"[ROA] disabled."); return; }
    // 有目标 App？
    if (![self targetBundleID]) { NSLog(@"[ROA] no bundle id."); return; }
    // 仅工作日
    if ([self workdaysOnly] && ![self isWorkdayForDate:[NSDate date]]) { NSLog(@"[ROA] weekend, skip."); return; }
    // 今天开过了？
    NSString *last = [[self prefs] stringForKey:kROALastOpenDate];
    if ([last isEqualToString:_todayKey]) { NSLog(@"[ROA] already opened today."); return; }

    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *now = [cal components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:[NSDate date]];
    NSInteger nowMin = [self minutesForHour:now.hour minute:now.minute];
    NSInteger startMin = [self minutesForHour:[self startHour] minute:[self startMin]];
    NSInteger endMin   = [self minutesForHour:[self endHour] minute:[self endMin]];

    // 窗口合法性
    if (endMin <= startMin) { NSLog(@"[ROA] invalid window."); return; }

    // 当前时间是否在窗口内？
    if (nowMin < startMin || nowMin > endMin) {
        NSLog(@"[ROA] outside window now."); 
        return;
    }

    // 在窗口内：从"当前之后 1 分钟"到"窗口末尾"随机选一个时刻
    NSInteger earliest = nowMin + 1;
    NSInteger latest   = endMin;
    if (earliest > latest) { latest = nowMin; } // 接近末尾时兜底
    NSInteger pick = earliest + arc4random_uniform((uint32_t)(latest - earliest + 1));

    NSDateComponents *targetComp = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:[NSDate date]];
    targetComp.hour   = pick / 60;
    targetComp.minute = pick % 60;
    targetComp.second = 0;
    _targetDate = [cal dateFromComponents:targetComp];

    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm";
    NSLog(@"[ROA] target scheduled at %@", [f stringFromDate:_targetDate]);
}

#pragma mark - 轮询

- (void)tick {
    // 跨天处理
    NSString *nowKey = [self dayKeyForDate:[NSDate date]];
    if (![nowKey isEqualToString:_todayKey]) {
        _todayKey = nowKey;
        _targetDate = nil;
        [self computeTargetIfNeeded];
        return;
    }

    if (_targetDate == nil) {
        [self computeTargetIfNeeded];
        return;
    }

    if ([[NSDate date] timeIntervalSinceDate:_targetDate] >= 0) {
        NSLog(@"[ROA] time reached, opening...");
        [self openTarget];
        _targetDate = nil;
    }
}

#pragma mark - 打开目标 App

// 共用：非阻塞拉起一个已注册的 URL scheme（最可靠），失败再走 LSApplicationWorkspace
- (void)launchAppWithURLScheme:(NSString *)scheme {
    if (scheme.length == 0) {
        NSLog(@"[ROA] launch: empty scheme.");
        return;
    }
    NSString *urlString = [scheme rangeOfString:@"://"].location == NSNotFound
                            ? [NSString stringWithFormat:@"%@://", scheme]
                            : scheme;
    NSURL *url = [NSURL URLWithString:urlString];
    NSLog(@"[ROA] launch via scheme: %@", urlString);
    BOOL ok = [[UIApplication sharedApplication] openURL:url];
    NSLog(@"[ROA] scheme open result = %@ (this is the primary path)", ok ? @"YES" : @"NO");
}

// 兜底：用 LSApplicationWorkspace 按 Bundle ID 打开
- (void)launchAppWithBundleID:(NSString *)bundleID {
    Class LSAppWorkspace = NSClassFromString(@"LSApplicationWorkspace");
    if (LSAppWorkspace) {
        id ws = [LSAppWorkspace performSelector:NSSelectorFromString(@"defaultWorkspace")];
        if (ws) {
            BOOL ok = (BOOL)[ws performSelector:NSSelectorFromString(@"openApplicationWithBundleID:")
                                     withObject:bundleID];
            NSLog(@"[ROA] openApplicationWithBundleID result = %@", ok ? @"YES" : @"NO");
            return;
        }
    }
    NSLog(@"[ROA] LSApplicationWorkspace unavailable, no fallback.");
}

// 真正被调度器调用：到达目标时刻，打开 App
- (void)openTarget {
    NSString *bundleID = [self targetBundleID];
    if (!bundleID) return;

    // 写入"今日已开"标记（先标记，即使打开失败也不重复尝试当天）
    [[self prefs] setObject:_todayKey forKey:kROALastOpenDate];
    [[self prefs] synchronize];

    // 首选 URL scheme（兼容钉钉 dingtalk://）；若未配置 scheme，fallback 到 Bundle ID
    NSString *scheme = [[self prefs] stringForKey:@"ROAURLScheme"];
    if (scheme.length == 0) {
        scheme = bundleID;
    }
    [self launchAppWithURLScheme:scheme];
    // 保险：scheme 已尝试，若未配置专门 scheme 再走 Workspace 兜底
    [self launchAppWithBundleID:bundleID];
}

// 设置面板"立即测试打开"按钮：绕开时间段与每日限制，立即拉起
- (void)openForTest {
    NSString *bundleID = [self targetBundleID];
    if (!bundleID) {
        NSLog(@"[ROA] test: no bundle id, set one first.");
        return;
    }
    NSLog(@"[ROA] test open requested for %@", bundleID);
    NSString *scheme = [[self prefs] stringForKey:@"ROAURLScheme"];
    [self launchAppWithURLScheme:(scheme.length ? scheme : bundleID)];
    [self launchAppWithBundleID:bundleID];
}

@end