#include <substrate.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#include "icon_data.h"



// ==================== IOHIDEvent ====================
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;
static IOHIDEventRef (*$IOHIDEventCreateDigitizerEvent)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat);
static IOHIDEventRef (*$IOHIDEventCreateDigitizerFingerEvent)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,BOOL,BOOL,uint32_t);
static IOHIDEventSystemClientRef (*$IOHIDEventSystemClientCreate)(CFAllocatorRef);
static void (*$IOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef,IOHIDEventRef);
static void (*$IOHIDEventSetIntegerValue)(IOHIDEventRef,uint32_t,int64_t);
static void (*$IOHIDEventSetFloatValue)(IOHIDEventRef,uint32_t,IOHIDFloat);
static void (*$IOHIDEventAppendEvent)(IOHIDEventRef,IOHIDEventRef);
static void (*$IOHIDEventSetSenderID)(IOHIDEventRef,uint64_t);
#define kIOHIDDigitizerEventRange 0x00000001
#define kIOHIDDigitizerEventTouch 0x00000002
#define kIOHIDDigitizerEventPosition 0x00000004
#define kIOHIDDigitizerEventIdentity 0x00000010
#define kIOHIDDigitizerTransducerTypeHand 3
#define kIOHIDEventFieldDigitizerMajorRadius 0x00400003
#define kIOHIDEventFieldIsBuiltIn 0x00060006
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 0x00C00001

static void resolveIOHID(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        $IOHIDEventCreateDigitizerEvent = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        $IOHIDEventCreateDigitizerFingerEvent = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        $IOHIDEventSystemClientCreate = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        $IOHIDEventSystemClientDispatchEvent = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        $IOHIDEventSetIntegerValue = dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        $IOHIDEventSetFloatValue = dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
        $IOHIDEventAppendEvent = dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        $IOHIDEventSetSenderID = dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
        NSLog(@"[AC] IOHID: %s", $IOHIDEventCreateDigitizerEvent ? "OK" : "FAIL");
    });
}

static void postTouch(CGFloat x, CGFloat y, BOOL touchDown) {
    if (!$IOHIDEventCreateDigitizerEvent) { resolveIOHID(); if (!$IOHIDEventCreateDigitizerEvent) return; }
    CGRect sb = UIScreen.mainScreen.bounds;
    IOHIDFloat xf = x/sb.size.width, yf = y/sb.size.height;
    IOHIDEventRef parent = $IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, mach_absolute_time(),
        kIOHIDDigitizerTransducerTypeHand, 1<<22, 1,
        kIOHIDDigitizerEventRange|kIOHIDDigitizerEventTouch|kIOHIDDigitizerEventIdentity,
        0, xf, yf, 0,0,0,0,0,0,0);
    if (!parent) return;
    if ($IOHIDEventSetSenderID) $IOHIDEventSetSenderID(parent, 0x8000000817319375);
    if ($IOHIDEventSetIntegerValue) $IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldIsBuiltIn, 1);
    IOHIDEventRef child = $IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, mach_absolute_time(),
        3, 2, kIOHIDDigitizerEventRange|kIOHIDDigitizerEventTouch, xf, yf, 0,0,0, touchDown, touchDown, 0);
    if (child) {
        if ($IOHIDEventSetFloatValue) $IOHIDEventSetFloatValue(child, kIOHIDEventFieldDigitizerMajorRadius, 0.04);
        $IOHIDEventAppendEvent(parent, child); CFRelease(child);
    }
    IOHIDEventSystemClientRef client = $IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client) { $IOHIDEventSystemClientDispatchEvent(parent, client); CFRelease(client); }
    CFRelease(parent);
}

static void performTap(CGFloat x, CGFloat y, NSTimeInterval holdMs) {
    postTouch(x, y, YES);
    [NSThread sleepForTimeInterval:holdMs/1000.0];
    postTouch(x, y, NO);
}

static void performDoubleTap(CGFloat x, CGFloat y) {
    for (int i=0; i<2; i++) { performTap(x, y, 30); [NSThread sleepForTimeInterval:0.08]; }
}

static void performSwipe(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, NSTimeInterval dur) {
    postTouch(x1, y1, YES);
    int steps = 20;
    for (int i=1; i<=steps; i++) {
        CGFloat t = (CGFloat)i/steps;
        postTouch(x1+(x2-x1)*t, y1+(y2-y1)*t, YES);
        [NSThread sleepForTimeInterval:dur/steps];
    }
    postTouch(x2, y2, NO);
}

// ==================== 截图 & OCR ====================
static UIImage *takeScreenshot(void) {
    CGSize sz = UIScreen.mainScreen.bounds.size;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz];
    [NSThread sleepForTimeInterval:0.05];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        for (UIWindow *win in [UIApplication sharedApplication].windows)
            if (!win.hidden) [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:YES];
    }];
}

static NSArray *performOCR(UIImage *image, CGFloat confThreshold) {
    if (!image) return nil;
    __block NSMutableArray *res = [NSMutableArray array];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *err) {
        for (VNRecognizedTextObservation *obs in request.results) {
            VNRecognizedText *top = [obs topCandidates:1].firstObject;
            if (!top || top.confidence < confThreshold) continue;
            CGRect rect = obs.boundingBox;
            CGFloat sw = UIScreen.mainScreen.bounds.size.width, sh = UIScreen.mainScreen.bounds.size.height;
            [res addObject:@{@"text":top.string, @"confidence":@(top.confidence),
                @"cx":@(rect.origin.x*sw+rect.size.width*sw/2), @"cy":@((1-rect.origin.y-rect.size.height)*sh+rect.size.height*sh/2)}];
        }
        dispatch_semaphore_signal(sem);
    }];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage options:@{}];
    NSError *vErr = nil;
    [handler performRequests:@[req] error:&vErr];
    if (vErr) {
        NSLog(@"[AC] OCR错误: %@", vErr.localizedDescription);
    }
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return res;
}

// ==================== 任务模型 ====================
@interface ACTask : NSObject <NSSecureCoding>
@property (nonatomic, strong) NSString *type;
@property (nonatomic, assign) CGFloat x, y, x2, y2;
@property (nonatomic, assign) NSTimeInterval interval, holdMs, duration;
@property (nonatomic, strong) NSString *targetText;
@property (nonatomic, assign) CGFloat threshold;
@end
@implementation ACTask
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)init {
    if (self = [super init]) {
        self.holdMs = 30;
        self.interval = 0.5;
        self.duration = 0.5;
        self.threshold = 0.7;
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.type forKey:@"type"];
    [coder encodeDouble:self.x forKey:@"x"];
    [coder encodeDouble:self.y forKey:@"y"];
    [coder encodeDouble:self.x2 forKey:@"x2"];
    [coder encodeDouble:self.y2 forKey:@"y2"];
    [coder encodeDouble:self.interval forKey:@"interval"];
    [coder encodeDouble:self.holdMs forKey:@"holdMs"];
    [coder encodeDouble:self.duration forKey:@"duration"];
    [coder encodeObject:self.targetText forKey:@"targetText"];
    [coder encodeDouble:self.threshold forKey:@"threshold"];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super init]) {
        self.type = [coder decodeObjectOfClass:[NSString class] forKey:@"type"];
        self.x = [coder decodeDoubleForKey:@"x"];
        self.y = [coder decodeDoubleForKey:@"y"];
        self.x2 = [coder decodeDoubleForKey:@"x2"];
        self.y2 = [coder decodeDoubleForKey:@"y2"];
        self.interval = [coder decodeDoubleForKey:@"interval"];
        self.holdMs = [coder decodeDoubleForKey:@"holdMs"];
        self.duration = [coder decodeDoubleForKey:@"duration"];
        self.targetText = [coder decodeObjectOfClass:[NSString class] forKey:@"targetText"];
        self.threshold = [coder decodeDoubleForKey:@"threshold"];
    }
    return self;
}
- (NSString *)displayName {
    NSDictionary *names = @{@"click":@"点击", @"doubleClick":@"双击", @"swipe":@"滑动", @"findImage":@"识图", @"ocr":@"识字"};
    NSString *n = names[self.type] ?: self.type;
    if ([self.type isEqual:@"click"]||[self.type isEqual:@"doubleClick"])
        return [NSString stringWithFormat:@"%@ (%.0f, %.0f)", n, self.x, self.y];
    if ([self.type isEqual:@"swipe"])
        return [NSString stringWithFormat:@"%@ (%.0f,%.0f)→(%.0f,%.0f)", n, self.x, self.y, self.x2, self.y2];
    if ([self.type isEqual:@"ocr"]||[self.type isEqual:@"findImage"])
        return [NSString stringWithFormat:@"%@ \"%@\"", n, self.targetText?:@"???"];
    return n;
}
@end

// ==================== 脚本引擎 ====================
@interface ScriptEngine : NSObject
@property (nonatomic, strong) NSArray *tasks;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) NSInteger currentIdx;
@end
@implementation ScriptEngine
- (instancetype)initWithTasks:(NSArray *)tasks {
    if (self=[super init]) { self.tasks=tasks; } return self;
}
- (void)executeTask:(ACTask *)task completion:(void(^)(BOOL ok))completion {
    if ([task.type isEqual:@"click"]) { performTap(task.x,task.y,task.holdMs?:30); completion(YES); }
    else if ([task.type isEqual:@"doubleClick"]) { performDoubleTap(task.x,task.y); completion(YES); }
    else if ([task.type isEqual:@"swipe"]) { performSwipe(task.x,task.y,task.x2,task.y2,task.duration?:0.5); completion(YES); }
    else if ([task.type isEqual:@"ocr"]) {
        NSArray *res = performOCR(takeScreenshot(), task.threshold?:0.3);
        if (task.targetText) {
            BOOL found=NO;
            for (NSDictionary *r in res) { if ([r[@"text"] containsString:task.targetText]) { found=YES; break; } }
            if (found) { [self addLog:[NSString stringWithFormat:@"OCR找到: %@", task.targetText]]; }
            else { [self addLog:[NSString stringWithFormat:@"OCR未找到: %@", task.targetText]]; }
        }
        completion(YES);
    } else if ([task.type isEqual:@"findImage"]) {
        UIImage *ss = takeScreenshot();
        NSArray *res = performOCR(ss, task.threshold?:0.3);
        if (task.targetText && res.count > 0) {
            BOOL found = NO;
            for (NSDictionary *r in res) {
                if ([r[@"text"] containsString:task.targetText]) {
                    CGFloat cx = [r[@"cx"] floatValue];
                    CGFloat cy = [r[@"cy"] floatValue];
                    [self addLog:[NSString stringWithFormat:@"识图找到\"%@\"，点击(%.0f,%.0f)", task.targetText, cx, cy]];
                    performTap(cx, cy, 30);
                    found = YES;
                    break;
                }
            }
            if (!found) [self addLog:[NSString stringWithFormat:@"识图未找到: %@", task.targetText]];
        } else {
            [self addLog:[NSString stringWithFormat:@"识图未找到: %@", task.targetText?:@"(无目标)"]];
        }
        completion(YES);
    } else completion(YES);
}
- (void)addLog:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ACLog" object:msg];
    });
}
- (void)run {
    self.running = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        self.currentIdx = 0;
        while (self.running && self.currentIdx < self.tasks.count) {
            ACTask *task = self.tasks[self.currentIdx];
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [self executeTask:task completion:^(BOOL ok) { dispatch_semaphore_signal(sem); }];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            if (!self.running) break;
            if (task.interval>0) [NSThread sleepForTimeInterval:task.interval];
            self.currentIdx++;
        }
        self.running = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ACScriptDone" object:nil];
        });
    });
}
- (void)stop { self.running = NO; }
@end

// ==================== 全局状态 ====================
static ScriptEngine *g_engine;
static BOOL g_isRunning = NO;
static NSMutableArray *g_taskList;
static NSMutableArray *g_logs;
static BOOL g_inEditMode = NO;

// ==================== 颜色工具 ====================
static UIColor *warmAccentGradientStart(void) { return [UIColor colorWithRed:0.976 green:0.451 blue:0.361 alpha:1]; } // #f9735c
static UIColor *warmAccentGradientEnd(void)   { return [UIColor colorWithRed:0.910 green:0.365 blue:0.227 alpha:1]; } // #e85d3a
static UIColor *warmDarkText(void)            { return [UIColor colorWithRed:0.239 green:0.157 blue:0.125 alpha:1]; } // #3d2820
static UIColor *warmMutedText(void)           { return [UIColor colorWithRed:0.604 green:0.478 blue:0.400 alpha:1]; } // #9a7a6a
static UIColor *warmCardBg(void)              { return [UIColor colorWithRed:0.98 green:0.96 blue:0.95 alpha:0.68]; } // 暖白半透明
static UIColor *warmGlassItem(void)           { return [UIColor colorWithRed:1 green:1 blue:1 alpha:0.5]; }

// ==================== 主控制器 ====================
@interface ACController : NSObject
@property (nonatomic, strong) UIWindow *floatWin;
@property (nonatomic, strong) UIButton *floatBtn;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, assign) BOOL cardVisible;
@property (nonatomic, strong) UIView *actionSheet;
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, strong) UIWindow *pickerWin;
@property (nonatomic, assign) NSInteger pickerPhase; // 0=未开始, 1=已选起点, 2=处理中
@end
@implementation ACController

+ (instancetype)shared {
    static ACController *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst=[[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    if (self=[super init]) {
        g_logs=[NSMutableArray array]; g_taskList=[NSMutableArray array];
        [self loadTasks];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onScriptDone:) name:@"ACScriptDone" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onLog:) name:@"ACLog" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(volumeChanged:) name:@"AVSystemController_SystemVolumeDidChangeNotification" object:nil];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            [self saveTasks];
        }];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

// ==================== 悬浮胶囊 ====================
- (void)setupFloatUI {
    if (self.floatWin) return;
    self.floatWin = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.floatWin.windowLevel = UIWindowLevelNormal + 2000;
    self.floatWin.backgroundColor = UIColor.clearColor;
    self.floatWin.hidden = NO; self.floatWin.userInteractionEnabled = YES;
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = UIColor.clearColor; vc.view.userInteractionEnabled = YES;
    self.floatWin.rootViewController = vc;

    // 圆形悬浮按钮，带胖虎图标
    self.floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    CGFloat bx = UIScreen.mainScreen.bounds.size.width-60, by = UIScreen.mainScreen.bounds.size.height*0.35;
    self.floatBtn.frame = CGRectMake(bx, by, 48, 48);
    self.floatBtn.layer.cornerRadius = 24; self.floatBtn.clipsToBounds = YES;
    self.floatBtn.backgroundColor = [UIColor colorWithRed:1 green:1 blue:1 alpha:0.78];
    self.floatBtn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    self.floatBtn.layer.borderWidth = 0.5;
    self.floatBtn.layer.shadowColor = [UIColor colorWithRed:0.71 green:0.39 blue:0.24 alpha:1].CGColor;
    self.floatBtn.layer.shadowOffset = CGSizeMake(0, 4);
    self.floatBtn.layer.shadowOpacity = 0.2;
    self.floatBtn.layer.shadowRadius = 16;

    // 胖虎图标
    NSData *imgData = [NSData dataWithBytes:kIconPNG length:kIconPNGSize];
    UIImage *iconImg = [UIImage imageWithData:imgData];
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(4, 4, 40, 40)];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = 20; iv.clipsToBounds = YES;
    if (iconImg) iv.image = iconImg;
    else { iv.backgroundColor = warmAccentGradientStart(); }
    iv.userInteractionEnabled = NO;
    [self.floatBtn addSubview:iv];

    // 任务数量角标
    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(30, 2, 18, 18)];
    badge.text = @"0"; badge.font = [UIFont boldSystemFontOfSize:10];
    badge.textColor = UIColor.whiteColor; badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = warmAccentGradientStart();
    badge.layer.cornerRadius = 9; badge.clipsToBounds = YES;
    badge.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.8].CGColor;
    badge.layer.borderWidth = 1.5;
    badge.tag = 800;
    [self.floatBtn addSubview:badge];
    [self.floatBtn addTarget:self action:@selector(onFloatTap) forControlEvents:UIControlEventTouchUpInside];
    [self.floatBtn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onFloatPan:)]];
    [vc.view addSubview:self.floatBtn];
    NSLog(@"[AC] 就绪");
}

- (void)updateFloatBadge {
    UILabel *badge = [self.floatBtn viewWithTag:800];
    if (badge) badge.text = [NSString stringWithFormat:@"%lu", (unsigned long)g_taskList.count];
}

- (void)onFloatPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view; CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x+t.x, v.center.y+t.y);
    [g setTranslation:CGPointZero inView:v.superview];
    if (g.state==UIGestureRecognizerStateEnded) {
        CGRect sb = UIScreen.mainScreen.bounds;
        CGFloat x = v.center.x>sb.size.width/2 ? sb.size.width-53 : 53;
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.6 options:0 animations:^{
            v.center = CGPointMake(x, MAX(70, MIN(sb.size.height-70, v.center.y)));
        } completion:nil];
    }
}

- (void)onFloatTap {
    if (self.cardVisible) [self dismissCard];
    else [self showCard];
}

// ==================== 折叠卡片（暖色玻璃风格） ====================
- (void)showCard {
    if (self.cardVisible) return;
    self.cardVisible = YES;
    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat cw = 300, ch = 200;
    CGFloat cx = sb.size.width-cw-16, cy = sb.size.height-ch-90;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(cx, cy, cw, ch)];
    card.backgroundColor = warmCardBg();
    card.layer.cornerRadius = 28; card.clipsToBounds = YES;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
    card.layer.borderWidth = 0.5;
    card.userInteractionEnabled = YES;
    // 阴影放在superview层
    card.layer.shadowColor = [UIColor colorWithRed:0.59 green:0.35 blue:0.20 alpha:1].CGColor;
    card.layer.shadowOffset = CGSizeMake(0, 12);
    card.layer.shadowOpacity = 0.14;
    card.layer.shadowRadius = 48;
    self.card = card;

    // ====== 简易层 ======
    UIView *simple = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, ch)];
    simple.tag = 100;

    // 小标题
    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(22, 14, 200, 16)];
    subtitle.text = @"● 自动化面板"; subtitle.textColor = warmMutedText();
    subtitle.font = [UIFont systemFontOfSize:12]; subtitle.tag = 888;
    [simple addSubview:subtitle];

    // 大标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(22, 30, 200, 26)];
    NSMutableAttributedString *ats = [[NSMutableAttributedString alloc] initWithString:@"连点助手"];
    [ats addAttribute:NSForegroundColorAttributeName value:warmDarkText() range:NSMakeRange(0,2)];
    [ats addAttribute:NSForegroundColorAttributeName value:warmAccentGradientStart() range:NSMakeRange(2,2)];
    [ats addAttribute:NSFontAttributeName value:[UIFont boldSystemFontOfSize:22] range:NSMakeRange(0,4)];
    title.attributedText = ats; title.tag = 889;
    [simple addSubview:title];

    // 按钮行
    UIButton *runBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    runBtn.frame = CGRectMake(22, 68, (cw-56)/2, 46);
    [self applyGradient:runBtn colors:@[(id)warmAccentGradientStart().CGColor, (id)warmAccentGradientEnd().CGColor]];
    runBtn.layer.cornerRadius = 23; runBtn.clipsToBounds = YES;
    [runBtn setTitle:@"▶ 启动" forState:UIControlStateNormal];
    [runBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    runBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    runBtn.layer.shadowColor = warmAccentGradientStart().CGColor;
    runBtn.layer.shadowOffset = CGSizeMake(0, 4);
    runBtn.layer.shadowOpacity = 0.35;
    runBtn.layer.shadowRadius = 14;
    [runBtn addTarget:self action:@selector(onRun) forControlEvents:UIControlEventTouchUpInside];
    [simple addSubview:runBtn];

    UIButton *stopBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    stopBtn.frame = CGRectMake(cw/2+6, 68, (cw-56)/2, 46);
    stopBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.06];
    stopBtn.layer.cornerRadius = 23; stopBtn.clipsToBounds = YES;
    [stopBtn setTitle:@"■ 停止" forState:UIControlStateNormal];
    [stopBtn setTitleColor:warmDarkText() forState:UIControlStateNormal];
    stopBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [stopBtn addTarget:self action:@selector(onStop) forControlEvents:UIControlEventTouchUpInside];
    [simple addSubview:stopBtn];

    // 编辑按钮
    UIButton *editBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    editBtn.frame = CGRectMake(22, 126, cw-44, 38);
    editBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
    editBtn.layer.cornerRadius = 19; editBtn.clipsToBounds = YES;
    [editBtn setTitle:@"✎ 编辑任务序列" forState:UIControlStateNormal];
    [editBtn setTitleColor:warmDarkText() forState:UIControlStateNormal];
    editBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    [editBtn addTarget:self action:@selector(goToEdit) forControlEvents:UIControlEventTouchUpInside];
    [simple addSubview:editBtn];

    // 状态栏
    UIView *statusBar = [[UIView alloc] initWithFrame:CGRectMake(22, 170, cw-44, 20)];
    statusBar.tag = 890;
    UILabel *countLbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 120, 20)];
    countLbl.text = g_taskList.count>0 ? [NSString stringWithFormat:@"%lu 个任务", (unsigned long)g_taskList.count] : @"暂无任务";
    countLbl.textColor = warmMutedText(); countLbl.font = [UIFont systemFontOfSize:11];
    countLbl.tag = 891; [statusBar addSubview:countLbl];

    UILabel *statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(cw-44-100, 0, 100, 20)];
    statusLbl.textAlignment = NSTextAlignmentRight;
    statusLbl.text = @"待命"; statusLbl.textColor = warmMutedText();
    statusLbl.font = [UIFont systemFontOfSize:11];

    // 状态点
    UIView *sd = [[UIView alloc] initWithFrame:CGRectMake(cw-44-112, 6, 7, 7)];
    sd.layer.cornerRadius = 3.5; sd.backgroundColor = [UIColor colorWithWhite:0.73 alpha:1];
    sd.tag = 893;
    [statusBar addSubview:sd];
    statusLbl.tag = 892;
    [statusBar addSubview:statusLbl];

    [simple addSubview:statusBar];
    [card addSubview:simple];

    // ====== 编辑层 ======
    UIView *edit = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, 330)];
    edit.tag = 200; edit.hidden = YES;

    // 头部
    UIView *editHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, 48)];
    UILabel *hTitle = [[UILabel alloc] initWithFrame:CGRectMake(22, 14, 150, 22)];
    hTitle.text = @"任务序列"; hTitle.font = [UIFont boldSystemFontOfSize:17];
    hTitle.textColor = warmDarkText();
    [editHeader addSubview:hTitle];

    UIButton *closeEdit = [UIButton buttonWithType:UIButtonTypeCustom];
    closeEdit.frame = CGRectMake(cw-46, 10, 32, 32);
    closeEdit.layer.cornerRadius = 16;
    closeEdit.backgroundColor = [UIColor colorWithWhite:0 alpha:0.05];
    [closeEdit setTitle:@"✕" forState:UIControlStateNormal];
    [closeEdit setTitleColor:[UIColor colorWithRed:0.48 green:0.35 blue:0.29 alpha:1] forState:UIControlStateNormal];
    closeEdit.titleLabel.font = [UIFont systemFontOfSize:14];
    [closeEdit addTarget:self action:@selector(foldBack) forControlEvents:UIControlEventTouchUpInside];
    [editHeader addSubview:closeEdit];
    [edit addSubview:editHeader];

    // 任务列表滚动
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 48, cw, 210)];
    scroll.tag = 300; scroll.userInteractionEnabled = YES;
    [edit addSubview:scroll];

    // 底部按钮
    UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    addBtn.frame = CGRectMake(16, 266, (cw-42)/2, 44);
    [self applyGradient:addBtn colors:@[(id)warmAccentGradientStart().CGColor, (id)warmAccentGradientEnd().CGColor]];
    addBtn.layer.cornerRadius = 22; addBtn.clipsToBounds = YES;
    [addBtn setTitle:@"＋ 添加动作" forState:UIControlStateNormal];
    [addBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    addBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    addBtn.layer.shadowColor = warmAccentGradientStart().CGColor;
    addBtn.layer.shadowOffset = CGSizeMake(0, 4);
    addBtn.layer.shadowOpacity = 0.25;
    addBtn.layer.shadowRadius = 12;
    [addBtn addTarget:self action:@selector(showActionSheet) forControlEvents:UIControlEventTouchUpInside];
    [edit addSubview:addBtn];

    UIButton *foldBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    foldBtn.frame = CGRectMake(cw/2+5, 266, (cw-42)/2, 44);
    foldBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
    foldBtn.layer.cornerRadius = 22; foldBtn.clipsToBounds = YES;
    [foldBtn setTitle:@"收起" forState:UIControlStateNormal];
    [foldBtn setTitleColor:warmDarkText() forState:UIControlStateNormal];
    foldBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [foldBtn addTarget:self action:@selector(foldBack) forControlEvents:UIControlEventTouchUpInside];
    [edit addSubview:foldBtn];

    [card addSubview:edit];

    [self.floatWin.rootViewController.view addSubview:card];
    card.alpha = 0; card.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:0 animations:^{
        card.alpha = 1; card.transform = CGAffineTransformIdentity;
    } completion:nil];
    [self refreshTaskList];
    [self updateFloatBadge];
}

- (void)applyGradient:(UIView *)view colors:(NSArray *)colors {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = view.bounds; g.colors = colors;
    g.startPoint = CGPointMake(0, 0); g.endPoint = CGPointMake(1, 1);
    [view.layer insertSublayer:g atIndex:0];
}

- (void)dismissCard {
    self.cardVisible = NO; g_inEditMode = NO;
    [UIView animateWithDuration:0.25 animations:^{
        self.card.alpha = 0; self.card.transform = CGAffineTransformMakeScale(0.88, 0.88);
    } completion:^(BOOL f) {
        [self.card removeFromSuperview]; self.card = nil;
    }];
}

- (void)goToEdit {
    g_inEditMode = YES;
    UIView *simple = [self.card viewWithTag:100];
    UIView *edit = [self.card viewWithTag:200];
    simple.hidden = YES; edit.hidden = NO;
    CGRect f = self.card.frame;
    self.card.frame = CGRectMake(f.origin.x, f.origin.y-65, 300, 330);
    [self refreshTaskList];
}

- (void)foldBack {
    g_inEditMode = NO;
    UIView *simple = [self.card viewWithTag:100];
    UIView *edit = [self.card viewWithTag:200];
    simple.hidden = NO; edit.hidden = YES;
    CGRect f = self.card.frame;
    self.card.frame = CGRectMake(f.origin.x, f.origin.y+65, 300, 200);
    UILabel *countLbl = [[simple viewWithTag:890] viewWithTag:891];
    countLbl.text = g_taskList.count>0 ? [NSString stringWithFormat:@"%lu 个任务",(unsigned long)g_taskList.count] : @"暂无任务";
}

- (void)refreshTaskList {
    UIScrollView *scroll = [self.card viewWithTag:300];
    if (!scroll) return;
    for (UIView *v in scroll.subviews) [v removeFromSuperview];
    CGFloat lw = scroll.frame.size.width-32;
    CGFloat ly = 8;

    if (g_taskList.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(16, 40, lw, 30)];
        empty.text = @"还没有添加任务"; empty.textColor = [UIColor colorWithRed:0.69 green:0.58 blue:0.52 alpha:1];
        empty.textAlignment = NSTextAlignmentCenter; empty.font = [UIFont systemFontOfSize:13];
        [scroll addSubview:empty];
        scroll.contentSize = CGSizeMake(scroll.frame.size.width, 100);
        return;
    }

    for (int i=0; i<g_taskList.count; i++) {
        ACTask *t = g_taskList[i];
        UIView *item = [[UIView alloc] initWithFrame:CGRectMake(16, ly, lw, 42)];
        item.backgroundColor = warmGlassItem();
        item.layer.cornerRadius = 14; item.userInteractionEnabled = YES;

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, lw-60, 42)];
        lb.text = [NSString stringWithFormat:@"%@", t.displayName];
        lb.textColor = warmDarkText(); lb.font = [UIFont systemFontOfSize:13];
        [item addSubview:lb];

        UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        delBtn.frame = CGRectMake(lw-42, 8, 26, 26);
        delBtn.layer.cornerRadius = 13;
        delBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
        [delBtn setTitle:@"✕" forState:UIControlStateNormal];
        [delBtn setTitleColor:[UIColor colorWithRed:0.72 green:0.35 blue:0.26 alpha:1] forState:UIControlStateNormal];
        delBtn.titleLabel.font = [UIFont systemFontOfSize:11];
        delBtn.tag = i;
        [delBtn addTarget:self action:@selector(deleteTask:) forControlEvents:UIControlEventTouchUpInside];
        [item addSubview:delBtn];

        [scroll addSubview:item];
        ly += 48;
    }
    scroll.contentSize = CGSizeMake(scroll.frame.size.width, ly+8);
}

// ==================== 底部ActionSheet（暖色玻璃） ====================
- (void)showActionSheet {
    if (self.actionSheet) { [self dismissActionSheet]; return; }
    CGRect sb = UIScreen.mainScreen.bounds;

    UIView *overlay = [[UIView alloc] initWithFrame:sb];
    overlay.backgroundColor = [UIColor colorWithRed:0.24 green:0.12 blue:0.06 alpha:0.25];
    overlay.userInteractionEnabled = YES;
    [overlay addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissActionSheet)]];
    [self.floatWin.rootViewController.view addSubview:overlay];
    self.overlay = overlay;

    CGFloat sh = 340;
    UIView *sheet = [[UIView alloc] initWithFrame:CGRectMake(0, sb.size.height, sb.size.width, sh)];
    sheet.backgroundColor = [UIColor colorWithRed:1 green:1 blue:1 alpha:0.82];
    sheet.layer.cornerRadius = 28;
    sheet.layer.maskedCorners = kCALayerMinXMinYCorner|kCALayerMaxXMinYCorner;
    sheet.clipsToBounds = YES;
    self.actionSheet = sheet;

    // 拖拽条
    UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-18, 10, 36, 4)];
    handle.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12];
    handle.layer.cornerRadius = 2;
    [sheet addSubview:handle];

    // 标题
    UILabel *sTitle = [[UILabel alloc] initWithFrame:CGRectMake(0, 24, sb.size.width, 22)];
    sTitle.text = @"选择动作类型"; sTitle.textColor = warmDarkText();
    sTitle.textAlignment = NSTextAlignmentCenter;
    sTitle.font = [UIFont boldSystemFontOfSize:16];
    [sheet addSubview:sTitle];

    NSArray *items = @[
        @[@"☝", @"点击", @"click"],
        @[@"☝☝", @"双击", @"doubleClick"],
        @[@"↗", @"滑动", @"swipe"],
        @[@"◎", @"识图", @"findImage"],
        @[@"Aa", @"识字", @"ocr"]
    ];
    NSArray *icoColors = @[
        [UIColor colorWithRed:0.91 green:0.43 blue:0.31 alpha:0.12],
        [UIColor colorWithRed:0.63 green:0.39 blue:0.78 alpha:0.12],
        [UIColor colorWithRed:0.86 green:0.67 blue:0.27 alpha:0.12],
        [UIColor colorWithRed:0.24 green:0.67 blue:0.63 alpha:0.12],
        [UIColor colorWithRed:0.82 green:0.35 blue:0.47 alpha:0.12]
    ];

    for (int i=0; i<items.count; i++) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(16, 60+i*54, sb.size.width-32, 48)];
        row.layer.cornerRadius = 14; row.userInteractionEnabled = YES;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(sheetItemTapped:)];
        [row addGestureRecognizer:tap];
        objc_setAssociatedObject(row, "type", items[i][2], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 图标
        UIView *ico = [[UIView alloc] initWithFrame:CGRectMake(0, 8, 34, 32)];
        ico.backgroundColor = icoColors[i];
        ico.layer.cornerRadius = 10;
        UILabel *icoL = [[UILabel alloc] initWithFrame:ico.bounds];
        icoL.text = items[i][0]; icoL.font = [UIFont systemFontOfSize:15];
        icoL.textAlignment = NSTextAlignmentCenter;
        [ico addSubview:icoL];
        [row addSubview:ico];

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(44, 0, 200, 48)];
        lb.text = items[i][1]; lb.textColor = warmDarkText();
        lb.font = [UIFont systemFontOfSize:15];
        [row addSubview:lb];

        [sheet addSubview:row];
    }

    // 取消按钮
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
    cancel.frame = CGRectMake(16, sh-54, sb.size.width-32, 44);
    cancel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
    cancel.layer.cornerRadius = 14; cancel.clipsToBounds = YES;
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel setTitleColor:[UIColor colorWithRed:0.72 green:0.35 blue:0.26 alpha:1] forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [cancel addTarget:self action:@selector(dismissActionSheet) forControlEvents:UIControlEventTouchUpInside];
    [sheet addSubview:cancel];

    [self.floatWin.rootViewController.view addSubview:sheet];
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.5 options:0 animations:^{
        sheet.frame = CGRectMake(0, sb.size.height-sh, sb.size.width, sh);
    } completion:nil];
}

- (void)sheetItemTapped:(UITapGestureRecognizer *)tap {
    NSString *type = objc_getAssociatedObject(tap.view, "type");
    [self dismissActionSheet];
    [self dismissCard];

    ACTask *task = [[ACTask alloc] init];
    task.type = type; task.holdMs = 30; task.interval = 0.5; task.duration = 0.5; task.threshold = 0.7;

    if ([type isEqual:@"findImage"]||[type isEqual:@"ocr"]) {
        [self showTextInput:task];
    } else {
        [self showPicker:task isNew:YES];
    }
}

- (void)dismissActionSheet {
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0 options:0 animations:^{
        self.actionSheet.frame = CGRectMake(0, UIScreen.mainScreen.bounds.size.height, self.actionSheet.frame.size.width, self.actionSheet.frame.size.height);
    } completion:^(BOOL f) {
        [self.actionSheet removeFromSuperview]; self.actionSheet = nil;
        [self.overlay removeFromSuperview]; self.overlay = nil;
    }];
}

// ==================== 文本输入 ====================
- (void)showTextInput:(ACTask *)task {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"输入目标文字" message:@"输入要查找的文字内容" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"例如: 确认"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        task.targetText = alert.textFields.firstObject.text?:@"";
        [g_taskList addObject:task];
        [self saveTasks];
        [self showCard]; [self refreshTaskList];
        [self updateFloatBadge];
        if (g_inEditMode) [self goToEdit];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [self showCard]; [self refreshTaskList];
        [self updateFloatBadge];
        if (g_inEditMode) [self goToEdit];
    }]];
    UIViewController *root = self.floatWin.rootViewController;
    if (root.presentedViewController) root = root.presentedViewController;
    [root presentViewController:alert animated:YES completion:nil];
}

// ==================== 坐标拾取（暖色风格） ====================
- (void)showPicker:(ACTask *)task isNew:(BOOL)isNew {
    CGRect sb = UIScreen.mainScreen.bounds;
    UIWindow *pw = [[UIWindow alloc] initWithFrame:sb];
    pw.windowLevel = UIWindowLevelNormal + 3000; pw.backgroundColor = UIColor.clearColor;
    pw.hidden = NO; self.pickerWin = pw;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.userInteractionEnabled = YES; pw.rootViewController = vc;

    UIView *bg = [[UIView alloc] initWithFrame:sb];
    bg.backgroundColor = [UIColor colorWithRed:0.12 green:0.06 blue:0.03 alpha:0.6];
    [vc.view addSubview:bg];

    // 十字线（暖色）
    UIView *hL = [[UIView alloc] initWithFrame:CGRectMake(0, sb.size.height/2-0.5, sb.size.width, 1)];
    hL.backgroundColor = [UIColor colorWithRed:0.91 green:0.43 blue:0.31 alpha:0.6]; hL.tag = 901;
    [bg addSubview:hL];
    UIView *vL = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-0.5, 0, 1, sb.size.height)];
    vL.backgroundColor = [UIColor colorWithRed:0.91 green:0.43 blue:0.31 alpha:0.6]; vL.tag = 902;
    [bg addSubview:vL];
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-18, sb.size.height/2-18, 36, 36)];
    dot.layer.cornerRadius = 18; dot.layer.borderColor = [UIColor colorWithRed:0.91 green:0.43 blue:0.31 alpha:0.7].CGColor;
    dot.layer.borderWidth = 2.5; dot.backgroundColor = UIColor.clearColor; dot.tag = 903;
    [bg addSubview:dot];

    // 坐标标签
    UILabel *coord = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, sb.size.width-40, 36)];
    coord.text = [task.type isEqual:@"swipe"] ? @"点选起点位置" : @"点击屏幕选点";
    coord.textColor = UIColor.whiteColor; coord.textAlignment = NSTextAlignmentCenter;
    coord.font = [UIFont boldSystemFontOfSize:16];
    coord.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    coord.layer.cornerRadius = 18; coord.clipsToBounds = YES; coord.tag = 904;
    [bg addSubview:coord];

    // 底部按钮
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
    cancel.frame = CGRectMake(sb.size.width/2-110, sb.size.height-100, 100, 44);
    cancel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
    cancel.layer.cornerRadius = 22; cancel.clipsToBounds = YES;
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [cancel addTarget:self action:@selector(cancelPicker) forControlEvents:UIControlEventTouchUpInside];
    [bg addSubview:cancel];

    UIButton *confirm = [UIButton buttonWithType:UIButtonTypeCustom];
    confirm.frame = CGRectMake(sb.size.width/2+10, sb.size.height-100, 100, 44);
    [self applyGradient:confirm colors:@[(id)warmAccentGradientStart().CGColor, (id)warmAccentGradientEnd().CGColor]];
    confirm.layer.cornerRadius = 22; confirm.clipsToBounds = YES;
    [confirm setTitle:@"确定 ✓" forState:UIControlStateNormal];
    [confirm setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    confirm.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [confirm addTarget:self action:@selector(pickerConfirmTap) forControlEvents:UIControlEventTouchUpInside];
    confirm.layer.shadowColor = warmAccentGradientStart().CGColor;
    confirm.layer.shadowOffset = CGSizeMake(0, 4);
    confirm.layer.shadowOpacity = 0.35;
    confirm.layer.shadowRadius = 14;
    [bg addSubview:confirm];

    objc_setAssociatedObject(bg, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(bg, "isNew", @(isNew), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(bg, "ctrl", self, OBJC_ASSOCIATION_ASSIGN);

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pickerPan:)];
    [bg addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(pickerTap:)];
    [bg addGestureRecognizer:tap];
}

- (void)pickerPan:(UIPanGestureRecognizer *)g {
    CGPoint pt = [g locationInView:g.view]; UIView *bg = g.view; CGRect sb = UIScreen.mainScreen.bounds;
    [bg viewWithTag:901].frame = CGRectMake(0, pt.y-0.5, sb.size.width, 1);
    [bg viewWithTag:902].frame = CGRectMake(pt.x-0.5, 0, 1, sb.size.height);
    [bg viewWithTag:903].center = pt;
    UILabel *hint = [bg viewWithTag:904]; hint.text = [NSString stringWithFormat:@"(%.0f, %.0f)", pt.x, pt.y];
    if (g.state == UIGestureRecognizerStateEnded) [self pickerConfirm:pt];
}
- (void)pickerTap:(UITapGestureRecognizer *)g {
    [self pickerConfirm:[g locationInView:g.view]];
}
- (void)pickerConfirmTap {
    UIView *bg = self.pickerWin.rootViewController.view.subviews.firstObject;
    if (!bg) return;
    UIView *dot = [bg viewWithTag:903];
    [self pickerConfirm:dot.center];
}
- (void)pickerConfirm:(CGPoint)pt {
    // 防止手势冲突导致的重复调用
    if (self.pickerPhase == 2) return;
    UIView *bg = self.pickerWin.rootViewController.view.subviews.firstObject;
    if (!bg) return;
    ACTask *task = objc_getAssociatedObject(bg, "task");
    BOOL isNew = [objc_getAssociatedObject(bg, "isNew") boolValue];

    if ([task.type isEqual:@"swipe"]) {
        // 使用 pickerPhase 跟踪状态，避免不能选(0,0)的问题
        if (self.pickerPhase == 0) {
            task.x=pt.x; task.y=pt.y;
            self.pickerPhase = 1;
            UILabel *hint = [bg viewWithTag:904];
            hint.text = [NSString stringWithFormat:@"起点(%.0f,%.0f) 再点终点", pt.x, pt.y];
            return;
        }
        task.x2=pt.x; task.y2=pt.y;
    } else {
        task.x=pt.x; task.y=pt.y;
    }
    self.pickerPhase = 2;
    [self.pickerWin setHidden:YES]; self.pickerWin = nil;

    if (isNew) {
        [g_taskList addObject:task];
        [self saveTasks];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pickerPhase = 0;
        [self showCard];
        [self refreshTaskList];
        [self updateFloatBadge];
        if (g_inEditMode) [self goToEdit];
    });
}
- (void)cancelPicker {
    [self.pickerWin setHidden:YES]; self.pickerWin = nil;
    [self showCard];
    [self refreshTaskList];
    [self updateFloatBadge];
    if (g_inEditMode) [self goToEdit];
}

// ==================== 删除任务 ====================
- (void)deleteTask:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx >= g_taskList.count) return;
    [g_taskList removeObjectAtIndex:idx];
    [self saveTasks];
    [self refreshTaskList];
    [self updateFloatBadge];
}

// ==================== 启动/停止 ====================
- (void)onRun {
    if (g_taskList.count == 0) { [self addLog:@"没有任务"]; return; }
    if (g_isRunning) { [self addLog:@"已在运行"]; return; }
    g_isRunning = YES;
    resolveIOHID();
    [self dismissCard];
    // 更新角标
    [self updateFloatBadge];
    g_engine = [[ScriptEngine alloc] initWithTasks:[g_taskList copy]];
    [g_engine run];
    [self addLog:@"启动任务序列"];
}

- (void)onStop {
    if (g_engine) [g_engine stop];
    g_isRunning = NO;
    [self addLog:@"已停止"];
}

- (void)onScriptDone:(NSNotification *)n {
    g_isRunning = NO;
    [self addLog:@"任务完成"];
    [self showCard];
}

// ==================== 日志 ====================
- (void)addLog:(NSString *)msg {
    @synchronized(g_logs) {
        [g_logs addObject:msg];
        if (g_logs.count>20) [g_logs removeObjectAtIndex:0];
    }
    NSLog(@"[AC] %@", msg);
}
- (void)onLog:(NSNotification *)n { [self addLog:n.object]; }

// ==================== 任务持久化 ====================
static NSString *tasksArchivePath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [[paths.firstObject stringByAppendingPathComponent:@"autoclicker_tasks"] stringByAppendingPathExtension:@"archive"];
}

- (void)saveTasks {
    @synchronized(g_taskList) {
        if (g_taskList.count == 0) return;
        NSError *err = nil;
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:g_taskList requiringYESecureCoding:NO error:&err];
        if (data) {
            [data writeToFile:tasksArchivePath() atomically:YES];
        }
    }
}

- (void)loadTasks {
    NSString *path = tasksArchivePath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        NSError *err = nil;
        NSSet *classes = [NSSet setWithObjects:[NSMutableArray class], [ACTask class], [NSString class], nil];
        NSArray *loaded = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:&err];
        if (loaded) {
            [g_taskList addObjectsFromArray:loaded];
        }
    }
}

// ==================== 音量键 ====================
- (void)volumeChanged:(NSNotification *)n {
    if (!g_isRunning && g_taskList.count>0) [self onRun];
}

@end

// ==================== 初始化 ====================
__attribute__((constructor))
static void init() {
    dispatch_async(dispatch_get_main_queue(), ^{
        static void (^trySetup)(void);
        trySetup = ^{
            UIWindow *kw = [UIApplication sharedApplication].keyWindow;
            if (!kw) { for (UIWindow *w in [UIApplication sharedApplication].windows)
                if (!w.hidden) { kw=w; break; } }
            if (!kw) {
                id del = [UIApplication sharedApplication].delegate;
                if ([del respondsToSelector:@selector(window)]) kw = [del window];
            }
            if (kw) { resolveIOHID(); [[ACController shared] setupFloatUI]; }
            else { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)),
                dispatch_get_main_queue(), trySetup); }
        };
        trySetup();
    });
}