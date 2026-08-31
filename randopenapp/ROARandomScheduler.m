//
//  ROARandomScheduler.m
//  随机开启app - 随机调度引擎实现
//
//  逻辑（v1.2.0 重构）：
//   - 支持两个时间段（①和②），每个时间段在窗口内随机选一个目标时刻，各触发一次
//   - 每个时间窗有独立的"今日已触发"标记，互不影响（不再用全局次数互相抢占）
//   - 30s 定时器轮询；到达目标时刻用 URL scheme / LSApplicationWorkspace 拉起 App
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
static NSString *const kROAStart2H   = @"ROAStartHour2";
static NSString *const kROAStart2M   = @"ROAStartMinute2";
static NSString *const kROAEnd2H     = @"ROAEndHour2";
static NSString *const kROAEnd2M     = @"ROAEndMinute2";
static NSString *const kROAWorkdays  = @"ROAWorkdaysOnly";

// 每个时窗独立的"今日已触发"标记，值为 "yyyyMMdd"
static NSString *const kROALastOpenW1 = @"ROALastOpenW1";
static NSString *const kROALastOpenW2 = @"ROALastOpenW2";
static NSString *const kROAPrefsDomain = @"com.roa.randopenapp";

static NSString *const kROANotifChanged = @"com.roa.randopenapp.changed";
static NSString *const kROANotifTest    = @"com.roa.randopenapp.test";

// 设置面板改动后的跨进程回调
static void roa_settingsChanged(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ROARandomScheduler *s = (__bridge ROARandomScheduler *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [s reloadSettings];
    });
}

// "立即测试打开"通知
static void roa_testRequest(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ROARandomScheduler *s = (__bridge ROARandomScheduler *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [s openForTest];
    });
}

@implementation ROARandomScheduler {
    NSTimer *_pollTimer;
    NSDate  *_targetDate1; // 时窗①的目标时刻
    NSDate  *_targetDate2; // 时窗②的目标时刻（未配置时为 nil）
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
    _todayKey = [self dayKeyForDate:[NSDate date]];

    NSLog(@"[ROA] v1.2.0 settings => enabled=%d bundleID=%@ w1=%02ld:%02ld-%02ld:%02ld w2=%02ld:%02ld-%02ld:%02ld workdays=%d w1Done=%@ w2Done=%@",
          [self isEnabled], [self targetBundleID] ?: @"nil",
          (long)[self startHour], (long)[self startMin], (long)[self endHour], (long)[self endMin],
          (long)[self start2Hour], (long)[self start2Min], (long)[self end2Hour], (long)[self end2Min],
          [self workdaysOnly],
          [[self prefs] stringForKey:kROALastOpenW1] ?: @"-",
          [[self prefs] stringForKey:kROALastOpenW2] ?: @"-");

    [self computeTargets];
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                   target:self
                                                 selector:@selector(tick)
                                                 userInfo:nil
                                                  repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_pollTimer forMode:NSRunLoopCommonModes];

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    roa_settingsChanged,
                                    (CFStringRef)kROANotifChanged,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    roa_testRequest,
                                    (CFStringRef)kROANotifTest,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    NSLog(@"[ROA] scheduler started.");
}

- (void)stop {
    [_pollTimer invalidate];
    _pollTimer = nil;
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       (__bridge const void *)self,
                                       (CFStringRef)kROANotifChanged,
                                       NULL);
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       (__bridge const void *)self,
                                       (CFStringRef)kROANotifTest,
                                       NULL);
}

- (void)reloadSettings {
    // 设置变更：重算两个窗口的目标；（不再清"今日已触发"标记，防止同一天重启后重复触发）
    _todayKey = [self dayKeyForDate:[NSDate date]];
    _targetDate1 = nil;
    _targetDate2 = nil;
    [self computeTargets];
}

#pragma mark - 读取设置

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:kROAPrefsDomain];
}

- (BOOL)isEnabled       { return [[self prefs] boolForKey:kROAEnabled]; }
- (NSString *)targetBundleID { NSString *b = [[self prefs] stringForKey:kROABundleID]; return (b.length > 0) ? b : nil; }
- (NSInteger)startHour  { return [[self prefs] integerForKey:kROAStartH]; }
- (NSInteger)startMin   { return [[self prefs] integerForKey:kROAStartM]; }
- (NSInteger)endHour    { return [[self prefs] integerForKey:kROAEndH]; }
- (NSInteger)endMin     { return [[self prefs] integerForKey:kROAEndM]; }
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
    NSInteger wd = [cal component:NSCalendarUnitWeekday fromDate:date];
    return (wd != 1 && wd != 7);
}

- (NSInteger)minutesForHour:(NSInteger)h minute:(NSInteger)m { return h * 60 + m; }

- (NSInteger)nowMinutesOfDay {
    NSDateComponents *c = [[NSCalendar currentCalendar] components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:[NSDate date]];
    return [self minutesForHour:c.hour minute:c.minute];
}

#pragma mark - 目标安排（两个窗口各自独立）

// 为两个窗口分别计算目标时刻
- (void)computeTargets {
    if (![self isEnabled]) { NSLog(@"[ROA] disabled, no targets."); return; }
    if (![self targetBundleID]) { NSLog(@"[ROA] no bundle id."); return; }
    if ([self workdaysOnly] && ![self isWorkdayForDate:[NSDate date]]) { NSLog(@"[ROA] weekend, skip."); return; }

    NSInteger nowMin = [self nowMinutesOfDay];

    // 时窗①
    _targetDate1 = [self computedTargetForWindow:1
                        startMin:[self minutesForHour:[self startHour] minute:[self startMin]]
                          endMin:[self minutesForHour:[self endHour] minute:[self endMin]]
                           doneKey:kROALastOpenW1
                          nowMin:nowMin];

    // 时窗②（未配置时自动跳过）
    _targetDate2 = [self computedTargetForWindow:2
                        startMin:[self minutesForHour:[self start2Hour] minute:[self start2Min]]
                          endMin:[self minutesForHour:[self end2Hour] minute:[self end2Min]]
                           doneKey:kROALastOpenW2
                          nowMin:nowMin];
}

// 为单个窗口计算目标时刻（返回 NSDate，nil 表示不安排）
- (NSDate *)computedTargetForWindow:(NSInteger)windex
                           startMin:(NSInteger)ws
                             endMin:(NSInteger)we
                            doneKey:(NSString *)doneKey
                             nowMin:(NSInteger)nowMin {
    // 未配置（结束 <= 开始即无效）
    if (we <= ws) {
        NSLog(@"[ROA] window%ld not configured, skip.", (long)windex);
        return nil;
    }
    // 今日已触发过该窗口 -> 不再安排
    NSString *done = [[self prefs] stringForKey:doneKey];
    if (done.length > 0 && [done isEqualToString:_todayKey]) {
        NSLog(@"[ROA] window%ld already triggered today.", (long)windex);
        return nil;
    }
    // 目标时刻：若当前在窗口内，从 [max(now+1, ws) .. we] 随机；若当前早于窗口，从整窗随机；已过则不安排
    NSInteger earliest, latest;
    if (nowMin < ws) {
        earliest = ws; latest = we;                    // 还没开始：整窗随机
    } else if (nowMin <= we) {
        earliest = nowMin + 1; latest = we;            // 正在窗口中：从现在起作用
        if (earliest > latest) earliest = ws;          // 接近末尾兜底
    } else {
        NSLog(@"[ROA] window%ld already passed today.", (long)windex);
        return nil;
    }
    NSInteger pick = earliest + arc4random_uniform((uint32_t)(latest - earliest + 1));
    NSDate *target = [self dateTodayForMinute:pick];

    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm";
    NSLog(@"[ROA] window%ld target scheduled at %@", (long)windex, [f stringFromDate:target]);
    return target;
}

- (NSDate *)dateTodayForMinute:(NSInteger)min {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:[NSDate date]];
    c.hour   = min / 60;
    c.minute = min % 60;
    c.second = 0;
    return [cal dateFromComponents:c];
}

#pragma mark - 轮询

- (void)tick {
    // 跨天处理：清空标记与目标
    NSString *nowKey = [self dayKeyForDate:[NSDate date]];
    if (![nowKey isEqualToString:_todayKey]) {
        _todayKey = nowKey;
        _targetDate1 = nil;
        _targetDate2 = nil;
        [self computeTargets];
        return;
    }

    NSDate *now = [NSDate date];

    // 时窗①
    if (_targetDate1 && [now timeIntervalSinceDate:_targetDate1] >= 0) {
        NSLog(@"[ROA] window1 time reached, opening...");
        [self openTargetForWindow:1 doneKey:kROALastOpenW1];
        _targetDate1 = nil;
    }
    // 时窗②
    if (_targetDate2 && [now timeIntervalSinceDate:_targetDate2] >= 0) {
        NSLog(@"[ROA] window2 time reached, opening...");
        [self openTargetForWindow:2 doneKey:kROALastOpenW2];
        _targetDate2 = nil;
    }

    // 若某窗口目标为空且今天还没触发，尝试补排（例如刚进入窗口）
    if (_targetDate1 == nil && ![[[self prefs] stringForKey:kROALastOpenW1] isEqualToString:_todayKey]) {
        NSInteger nowMin = [self nowMinutesOfDay];
        if (nowMin >= [self minutesForHour:[self startHour] minute:[self startMin]]
            && nowMin <= [self minutesForHour:[self endHour] minute:[self endMin]]) {
            [self computeTargets];
        }
    }
    if (_targetDate2 == nil && ![[[self prefs] stringForKey:kROALastOpenW2] isEqualToString:_todayKey]) {
        NSInteger nowMin = [self nowMinutesOfDay];
        if (nowMin >= [self minutesForHour:[self start2Hour] minute:[self start2Min]]
            && nowMin <= [self minutesForHour:[self end2Hour] minute:[self end2Min]]) {
            [self computeTargets];
        }
    }
}

#pragma mark - 打开目标 App

- (void)launchAppWithURLScheme:(NSString *)scheme {
    if (scheme.length == 0) return;
    NSString *urlString = [scheme rangeOfString:@"://"].location == NSNotFound
                            ? [NSString stringWithFormat:@"%@://", scheme] : scheme;
    NSLog(@"[ROA] launch via scheme: %@", urlString);
    BOOL ok = [[UIApplication sharedApplication] openURL:[NSURL URLWithString:urlString]];
    NSLog(@"[ROA] scheme open result = %@", ok ? @"YES" : @"NO");
}

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
}

// 到达目标时刻，打开并仅标记当前窗口已触发
- (void)openTargetForWindow:(NSInteger)windex doneKey:(NSString *)doneKey {
    NSString *bundleID = [self targetBundleID];
    if (!bundleID) return;

    [[self prefs] setObject:_todayKey forKey:doneKey];
    [[self prefs] synchronize];
    NSLog(@"[ROA] window%ld opened, marking done.", (long)windex);

    NSString *scheme = [[self prefs] stringForKey:@"ROAURLScheme"];
    [self launchAppWithURLScheme:(scheme.length ? scheme : bundleID)];
    [self launchAppWithBundleID:bundleID];
}

// 设置面板"立即测试打开"按钮：立即拉起，不影响任何窗口标记
- (void)openForTest {
    NSString *bundleID = [self targetBundleID];
    if (!bundleID) { NSLog(@"[ROA] test: no bundle id."); return; }
    NSLog(@"[ROA] test open requested for %@", bundleID);
    NSString *scheme = [[self prefs] stringForKey:@"ROAURLScheme"];
    [self launchAppWithURLScheme:(scheme.length ? scheme : bundleID)];
    [self launchAppWithBundleID:bundleID];
}

@end