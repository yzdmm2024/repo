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
static NSString *const kROATimes     = @"ROATimesPerDay";
// 时间段②
static NSString *const kROAStart2H   = @"ROAStartHour2";
static NSString *const kROAStart2M   = @"ROAStartMinute2";
static NSString *const kROAEnd2H     = @"ROAEndHour2";
static NSString *const kROAEnd2M     = @"ROAEndMinute2";
static NSString *const kROAWorkdays  = @"ROAWorkdaysOnly";

static NSString *const kROALastOpenDate = @"ROALastOpenDay";      // "yyyyMMdd"
static NSString *const kROAOpenCount    = @"ROAOpenCount";         // 今天已触发次数
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
    // 启动即重置今日状态：避免旧的 ROALastOpenDay 残留把当天永久挡住（立即测试不受此影响）
    [[self prefs] removeObjectForKey:kROALastOpenDate];
    [[self prefs] setInteger:0 forKey:kROAOpenCount];
    [[self prefs] synchronize];
    _todayKey = [self dayKeyForDate:[NSDate date]];

    NSLog(@"[ROA] settings => enabled=%d bundleID=%@ w1=%02ld:%02ld-%02ld:%02ld w2=%02ld:%02ld-%02ld:%02ld times=%ld workdays=%d",
          [self isEnabled], [self targetBundleID] ?: @"nil",
          (long)[self startHour], (long)[self startMin], (long)[self endHour], (long)[self endMin],
          (long)[self start2Hour], (long)[self start2Min], (long)[self end2Hour], (long)[self end2Min],
          (long)[self timesPerDay], [self workdaysOnly]);

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
    // 设置变更时重置"今日已开"标记与计数，让用户改动后当天能重新触发
    [[self prefs] removeObjectForKey:kROALastOpenDate];
    [[self prefs] setInteger:0 forKey:kROAOpenCount];
    [[self prefs] synchronize];
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
- (NSInteger)timesPerDay { NSInteger t = [[self prefs] integerForKey:kROATimes]; return (t < 1) ? 1 : (t > 2 ? 2 : t); }
// 时间段②
- (NSInteger)start2Hour { return [[self prefs] integerForKey:kROAStart2H]; }
- (NSInteger)start2Min  { return [[self prefs] integerForKey:kROAStart2M]; }
- (NSInteger)end2Hour   { return [[self prefs] integerForKey:kROAEnd2H]; }
- (NSInteger)end2Min    { return [[self prefs] integerForKey:kROAEnd2M]; }
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
    // 今天触发次数是否已达上限
    NSInteger todayCount = 0;
    NSString *last = [[self prefs] stringForKey:kROALastOpenDate];
    if (last.length > 0 && [last isEqualToString:_todayKey]) {
        todayCount = [[self prefs] integerForKey:kROAOpenCount];
    }
    NSInteger times = [self timesPerDay];
    if (todayCount >= times) {
        NSLog(@"[ROA] reached limit %ld/%ld today.", (long)todayCount, (long)times);
        return;
    }

    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *now = [cal components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:[NSDate date]];
    NSInteger nowMin = [self minutesForHour:now.hour minute:now.minute];

    // 两个时间段
    NSInteger w1s = [self minutesForHour:[self startHour] minute:[self startMin]];
    NSInteger w1e = [self minutesForHour:[self endHour] minute:[self endMin]];
    NSInteger w2s = [self minutesForHour:[self start2Hour] minute:[self start2Min]];
    NSInteger w2e = [self minutesForHour:[self end2Hour] minute:[self end2Min]];

    // 收集所有"未过期且合法"的候选窗口
    // 目标必须是当前之后的时刻，且在今天剩余窗口内随机
    NSMutableArray *candidates = [NSMutableArray array];
    // 窗口①
    if (w1e > w1s) {
        [candidates addObject:@[@(w1s), @(w1e)]];
    }
    // 窗口②（未填写时 w2s==0,w2e==0 视为无效）
    if (w2e > w2s && w2s > 0) {
        [candidates addObject:@[@(w2s), @(w2e)]];
    }
    if (candidates.count == 0) { NSLog(@"[ROA] no valid window."); return; }

    // 挑选"现在所处或之后"的候选：优先当前窗口，否则下一个未来的窗口
    NSArray *chosen = nil;
    // 先看当前是否在某窗口内
    for (NSArray *win in candidates) {
        NSInteger ws = [win[0] integerValue], we = [win[1] integerValue];
        if (nowMin >= ws && nowMin <= we) { chosen = win; break; }
    }
    // 不在任何窗口内：选即将到来的最早窗口
    if (!chosen) {
        NSArray *best = nil;
        for (NSArray *win in candidates) {
            NSInteger ws = [win[0] integerValue];
            // 窗口开始时间必须晚于当前
            if (ws > nowMin) {
                if (!best || ws < [best[0] integerValue]) { best = win; }
            }
        }
        chosen = best;
    }
    if (!chosen) { NSLog(@"[ROA] no upcoming window today."); return; }

    NSInteger ws = [chosen[0] integerValue], we = [chosen[1] integerValue];
    // 在窗口内：earliest 至少当前+1分钟，最晚窗口末尾；若窗口已到末尾则用当前时刻
    NSInteger earliest = nowMin + 1;
    NSInteger latest   = we;
    if (earliest > latest) {
        // 窗口刚结束，退回到现在（保证能立即安排）
        if (nowMin <= we) { earliest = nowMin; latest = we; }
        else { NSLog(@"[ROA] window passed, skip."); return; }
    }
    if (earliest < ws) earliest = ws;
    NSInteger pick = earliest + arc4random_uniform((uint32_t)(latest - earliest + 1));

    NSDateComponents *targetComp = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:[NSDate date]];
    targetComp.hour   = pick / 60;
    targetComp.minute = pick % 60;
    targetComp.second = 0;
    _targetDate = [cal dateFromComponents:targetComp];

    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm";
    NSLog(@"[ROA] target scheduled at %@ (window %02ld:%02ld-%02ld:%02ld)",
          [f stringFromDate:_targetDate], (long)(ws/60), (long)(ws%60), (long)(we/60), (long)(we%60));
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

    // 写入今天日期并计数递增（即使打开失败也不重复尝试同一个窗口）
    NSInteger count = 0;
    NSString *last = [[self prefs] stringForKey:kROALastOpenDate];
    if (last.length > 0 && [last isEqualToString:_todayKey]) {
        count = [[self prefs] integerForKey:kROAOpenCount];
    }
    count += 1;
    [[self prefs] setObject:_todayKey forKey:kROALastOpenDate];
    [[self prefs] setInteger:count forKey:kROAOpenCount];
    [[self prefs] synchronize];

    // 首选 URL scheme（兼容钉钉 dingtalk://）；若未配置 scheme，fallback 到 Bundle ID
    NSString *scheme = [[self prefs] stringForKey:@"ROAURLScheme"];
    if (scheme.length == 0) {
        scheme = bundleID;
    }
    NSLog(@"[ROA] time reached, opening (count %ld) ...", (long)count);
    [self launchAppWithURLScheme:scheme];
    // 保险：scheme 已尝试，若未配置专门 scheme 再走 Workspace 兜底
    [self launchAppWithBundleID:bundleID];
    // 下一次触发可能在另一窗口，清空当前目标让它找下一个窗口
    _targetDate = nil;
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