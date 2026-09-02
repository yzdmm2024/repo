#include <substrate.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#include "icon_data.h"

// Forward declarations
static void hook_sendEvent(id, SEL, UIEvent *);
static void (*orig_sendEvent)(id, SEL, UIEvent *);

// ==================== IOHIDEvent ====================
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;
static IOHIDEventRef (*$IOHIDEventCreateDigitizerEvent)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat);
static void (*$clientDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
static IOHIDEventSystemClientRef (*$clientCreate)(CFAllocatorRef);
static IOHIDEventRef (*$IOHIDEventCreateDigitizerFingerEvent)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,IOHIDFloat,BOOL,BOOL,uint32_t);
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

static void resolveIOHID(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        $IOHIDEventCreateDigitizerEvent = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        $IOHIDEventCreateDigitizerFingerEvent = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
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
    // 优先使用 _enqueueHIDEvent: 更可靠（参考老贝贝）
    BOOL enqueued = NO;
    SEL sel_enqueue = NSSelectorFromString(@"_enqueueHIDEvent:");
    if ([UIApplication.sharedApplication respondsToSelector:sel_enqueue]) {
        ((void (*)(id, SEL, IOHIDEventRef))[UIApplication.sharedApplication methodForSelector:sel_enqueue])(UIApplication.sharedApplication, sel_enqueue, parent);
        enqueued = YES;
    }
    if (!enqueued && $clientCreate && $clientDispatch) {
        IOHIDEventSystemClientRef client = $clientCreate(kCFAllocatorDefault);
        if (client) { $clientDispatch(client, parent); CFRelease(client); }
    }
    CFRelease(parent);
}

static void performTap(CGFloat x, CGFloat y, NSTimeInterval holdMs) {
    postTouch(x, y, YES); [NSThread sleepForTimeInterval:holdMs/1000.0]; postTouch(x, y, NO);
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
        for (UIWindow *win in [UIApplication sharedApplication].windows) {
            if (!win.hidden) [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:YES];
        }
    }];
}

static NSArray *performOCR(UIImage *image, CGFloat confThreshold) {
    if (!image || !NSClassFromString(@"VNRecognizeTextRequest")) return nil;
    __block NSMutableArray *res = [NSMutableArray array];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *err) {
        if (err) NSLog(@"[AC] OCR错误: %@", err.localizedDescription);
        for (VNRecognizedTextObservation *obs in request.results) {
            VNRecognizedText *top = [obs topCandidates:1].firstObject;
            if (!top || top.confidence < confThreshold) continue;
            CGFloat sw = UIScreen.mainScreen.bounds.size.width, sh = UIScreen.mainScreen.bounds.size.height;
            [res addObject:@{@"text":top.string, @"confidence":@(top.confidence),
                @"cx":@(obs.boundingBox.origin.x*sw + obs.boundingBox.size.width*sw/2),
                @"cy":@((1-obs.boundingBox.origin.y-obs.boundingBox.size.height)*sh + obs.boundingBox.size.height*sh/2)}];
        }
        dispatch_semaphore_signal(sem);
    }];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    CGImageRef cgImg = image.CGImage;
    if (!cgImg) { dispatch_semaphore_signal(sem); return nil; }
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImg options:@{}];
    [handler performRequests:@[req] error:nil];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return res;
}

// ==================== 模板匹配 ====================
static NSDictionary *findImageTemplate(UIImage *screen, UIImage *templ, CGFloat threshold) {
    if (!screen || !templ) return nil;
    CGImageRef cgS = screen.CGImage, cgT = templ.CGImage;
    if (!cgS || !cgT) return nil;
    int sw = (int)CGImageGetWidth(cgS), sh = (int)CGImageGetHeight(cgS);
    int tw = (int)CGImageGetWidth(cgT), th = (int)CGImageGetHeight(cgT);
    if (tw > sw || th > sh) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    uint8_t *sd = malloc(sw * sh * 4);
    uint8_t *td = malloc(tw * th * 4);
    CGContextRef ctx = CGBitmapContextCreate(sd, sw, sh, 8, sw*4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(ctx, CGRectMake(0,0,sw,sh), cgS); CGContextRelease(ctx);
    ctx = CGBitmapContextCreate(td, tw, th, 8, tw*4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(ctx, CGRectMake(0,0,tw,th), cgT); CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    double tMean = 0;
    for (int i = 0; i < tw*th; i++) tMean += (td[i*4+1] + td[i*4+2] + td[i*4+3]) / 3.0;
    tMean /= (tw*th);
    double tVar = 0;
    for (int i = 0; i < tw*th; i++) { double v = (td[i*4+1] + td[i*4+2] + td[i*4+3]) / 3.0 - tMean; tVar += v*v; }
    if (tVar < 1) { free(sd); free(td); return nil; }
    double best = -1; int bestX = 0, bestY = 0;
    int stride = MAX(1, MIN(tw, th) / 6);
    if (stride > 8) stride = 8;
    for (int y = 0; y <= sh-th; y += stride) {
        for (int x = 0; x <= sw-tw; x += stride) {
            double sSum = 0, sSq = 0, prod = 0;
            for (int ty = 0; ty < th; ty++) {
                for (int tx = 0; tx < tw; tx++) {
                    uint8_t *sp = sd + ((y+ty)*sw + (x+tx))*4;
                    uint8_t *tp = td + (ty*tw + tx)*4;
                    double sv = (sp[1] + sp[2] + sp[3]) / 3.0;
                    double tv = (tp[1] + tp[2] + tp[3]) / 3.0;
                    sSum += sv; sSq += sv*sv; prod += sv*tv;
                }
            }
            double n = tw*th;
            double sMean = sSum/n, sVar = sSq/n - sMean*sMean;
            double cov = prod/n - sMean*tMean;
            double denom = sqrt(sVar * tVar);
            if (denom > 0) { double score = cov/denom; if (score > best) { best = score; bestX = x; bestY = y; } }
        }
    }
    if (stride > 1 && best >= 0) {
        int sx = MAX(0, bestX - stride + 1), sy = MAX(0, bestY - stride + 1);
        int ex = MIN(sw-tw, bestX + stride - 1), ey = MIN(sh-th, bestY + stride - 1);
        for (int y = sy; y <= ey; y++) {
            for (int x = sx; x <= ex; x++) {
                double sSum = 0, sSq = 0, prod = 0;
                for (int ty = 0; ty < th; ty++) {
                    for (int tx = 0; tx < tw; tx++) {
                        uint8_t *sp = sd + ((y+ty)*sw + (x+tx))*4;
                        uint8_t *tp = td + (ty*tw + tx)*4;
                        double sv = (sp[1] + sp[2] + sp[3]) / 3.0;
                        double tv = (tp[1] + tp[2] + tp[3]) / 3.0;
                        sSum += sv; sSq += sv*sv; prod += sv*tv;
                    }
                }
                double n = tw*th;
                double sMean = sSum/n, sVar = sSq/n - sMean*sMean;
                double cov = prod/n - sMean*tMean;
                double denom = sqrt(sVar * tVar);
                if (denom > 0) { double score = cov/denom; if (score > best) { best = score; bestX = x; bestY = y; } }
            }
        }
    }
    free(sd); free(td);
    if (best >= threshold) {
        CGFloat scale = UIScreen.mainScreen.scale;
        return @{@"x":@((bestX + tw/2)/scale), @"y":@((bestY + th/2)/scale), @"score":@(best)};
    }
    return nil;
}

// ==================== 任务模型 ====================
@interface ACTask : NSObject <NSSecureCoding>
@property (nonatomic, strong) NSString *type;
@property (nonatomic, strong) NSString *desc;           // 动作备注
@property (nonatomic, assign) NSInteger repeatCount; // 执行次数 (0=无限)
@property (nonatomic, assign) NSTimeInterval postWait; // 执行后等待毫秒
@property (nonatomic, assign) CGFloat x, y, x2, y2;
@property (nonatomic, assign) NSTimeInterval holdMs, doubleClickInterval; // 按下时长, 双击间隔
@property (nonatomic, assign) NSTimeInterval duration; // 滑动时长/等待时长
@property (nonatomic, strong) NSString *targetText;
@property (nonatomic, strong) NSData *templateData;
@property (nonatomic, assign) CGFloat threshold;      // 相似度/置信度/颜色容差 (0-1)
@property (nonatomic, assign) NSInteger actionAfterFound; // 0=不执行, 1=点击匹配位置, 2=点击中心
@property (nonatomic, assign) NSInteger r, g, b;       // 颜色匹配 RGB (0-255)
@property (nonatomic, assign) NSInteger conditionType; // 0:无, 1:如果找到, 2:如果没找到
@property (nonatomic, assign) NSInteger gotoIndex;     // 跳转目标索引 (从0开始)
@end
@implementation ACTask
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)init {
    if (self = [super init]) {
        self.desc = @"";
        self.repeatCount = 1;
        self.postWait = 300;
        self.holdMs = 30;
        self.doubleClickInterval = 100;
        self.duration = 500;
        self.threshold = 0.7;
        self.actionAfterFound = 1;
        self.r = 255; self.g = 0; self.b = 0; // 默认红色
        self.conditionType = 0;
        self.gotoIndex = 0;
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.type forKey:@"type"];
    [coder encodeObject:self.desc forKey:@"desc"];
    [coder encodeInteger:self.repeatCount forKey:@"repeatCount"];
    [coder encodeDouble:self.postWait forKey:@"postWait"];
    [coder encodeDouble:self.x forKey:@"x"]; [coder encodeDouble:self.y forKey:@"y"];
    [coder encodeDouble:self.x2 forKey:@"x2"]; [coder encodeDouble:self.y2 forKey:@"y2"];
    [coder encodeDouble:self.holdMs forKey:@"holdMs"];
    [coder encodeDouble:self.doubleClickInterval forKey:@"doubleClickInterval"];
    [coder encodeDouble:self.duration forKey:@"duration"];
    [coder encodeObject:self.targetText forKey:@"targetText"];
    [coder encodeObject:self.templateData forKey:@"templateData"];
    [coder encodeDouble:self.threshold forKey:@"threshold"];
    [coder encodeInteger:self.actionAfterFound forKey:@"actionAfterFound"];
    [coder encodeInteger:self.r forKey:@"r"]; [coder encodeInteger:self.g forKey:@"g"]; [coder encodeInteger:self.b forKey:@"b"];
    [coder encodeInteger:self.conditionType forKey:@"conditionType"];
    [coder encodeInteger:self.gotoIndex forKey:@"gotoIndex"];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super init]) {
        self.type = [coder decodeObjectOfClass:[NSString class] forKey:@"type"];
        self.desc = [coder decodeObjectOfClass:[NSString class] forKey:@"desc"];
        self.repeatCount = [coder decodeIntegerForKey:@"repeatCount"];
        self.postWait = [coder decodeDoubleForKey:@"postWait"];
        self.x = [coder decodeDoubleForKey:@"x"]; self.y = [coder decodeDoubleForKey:@"y"];
        self.x2 = [coder decodeDoubleForKey:@"x2"]; self.y2 = [coder decodeDoubleForKey:@"y2"];
        self.holdMs = [coder decodeDoubleForKey:@"holdMs"];
        if ([coder containsValueForKey:@"doubleClickInterval"])
            self.doubleClickInterval = [coder decodeDoubleForKey:@"doubleClickInterval"];
        else
            self.doubleClickInterval = 100;
        self.duration = [coder decodeDoubleForKey:@"duration"];
        self.targetText = [coder decodeObjectOfClass:[NSString class] forKey:@"targetText"];
        self.templateData = [coder decodeObjectOfClass:[NSData class] forKey:@"templateData"];
        self.threshold = [coder decodeDoubleForKey:@"threshold"];
        if ([coder containsValueForKey:@"actionAfterFound"])
            self.actionAfterFound = [coder decodeIntegerForKey:@"actionAfterFound"];
        else
            self.actionAfterFound = 1;
        self.r = [coder containsValueForKey:@"r"] ? [coder decodeIntegerForKey:@"r"] : 0;
        self.g = [coder containsValueForKey:@"g"] ? [coder decodeIntegerForKey:@"g"] : 0;
        self.b = [coder containsValueForKey:@"b"] ? [coder decodeIntegerForKey:@"b"] : 0;
        self.conditionType = [coder containsValueForKey:@"conditionType"] ? [coder decodeIntegerForKey:@"conditionType"] : 0;
        self.gotoIndex = [coder containsValueForKey:@"gotoIndex"] ? [coder decodeIntegerForKey:@"gotoIndex"] : 0;
        if (!self.postWait) self.postWait = 300;
        if (!self.repeatCount) self.repeatCount = 1;
    }
    return self;
}
@end

// ==================== 接收窗口（不拦截触摸）====================
// 核心：参考老贝贝的顶层窗口设计，hitTest只返回我们自己的控件，其他触摸透传
@interface ACPassThroughWindow : UIWindow
@end
@implementation ACPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    // 只有点击到我们的实际控件才响应
    return hit;
}
@end

// ==================== 脚本引擎 ====================
@interface ScriptEngine : NSObject
@property (nonatomic, strong) NSArray *tasks;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) NSInteger currentIdx;
- (void)addLog:(NSString *)msg;
@end
@implementation ScriptEngine
- (instancetype)initWithTasks:(NSArray *)tasks {
    if (self = [super init]) { self.tasks = tasks; }
    return self;
}
- (void)executeTask:(ACTask *)task completion:(void(^)(BOOL ok))completion {
    if ([task.type isEqual:@"click"]) {
        performTap(task.x, task.y, task.holdMs ?: 30); completion(YES);
    } else if ([task.type isEqual:@"doubleClick"]) {
        performDoubleTap(task.x, task.y); completion(YES);
    } else if ([task.type isEqual:@"longPress"]) {
        performTap(task.x, task.y, task.holdMs ?: 500); completion(YES);
    } else if ([task.type isEqual:@"swipe"]) {
        performSwipe(task.x, task.y, task.x2, task.y2, task.duration ?: 0.5); completion(YES);
    } else if ([task.type isEqual:@"wait"]) {
        [NSThread sleepForTimeInterval:task.duration ?: 1.0]; completion(YES);
    } else if ([task.type isEqual:@"ocr"]) {
        UIImage *ss = takeScreenshot();
        NSArray *res = performOCR(ss, task.threshold ?: 0.3);
        BOOL found = NO;
        for (NSDictionary *r in res) {
            if (!task.targetText || [r[@"text"] containsString:task.targetText]) {
                CGFloat cx = [r[@"cx"] floatValue], cy = [r[@"cy"] floatValue];
                [self addLog:[NSString stringWithFormat:@"识字\"%@\" (%.0f%%)", r[@"text"], [r[@"confidence"] floatValue]*100]];
                if (task.actionAfterFound == 1) {
                    performTap(cx, cy, 30);
                } else if (task.actionAfterFound == 2) {
                    // 点击区域中心（OCR默认就是文字中心，所以等同点击匹配位置）
                    performTap(cx, cy, 30);
                }
                found = YES; break;
            }
        }
        if (!found) [self addLog:[NSString stringWithFormat:@"识字未找到: %@", task.targetText ?: @"(任意文字)"]];
        completion(YES);
    } else if ([task.type isEqual:@"findImage"]) {
        if (task.templateData) {
            UIImage *template = [UIImage imageWithData:task.templateData];
            if (template) {
                UIImage *ss = takeScreenshot();
                NSDictionary *match = findImageTemplate(ss, template, task.threshold ?: 0.5);
                if (match) {
                    [self addLog:[NSString stringWithFormat:@"识图匹配 (%.0f%%)", [match[@"score"] floatValue]*100]];
                    if (task.actionAfterFound == 1) {
                        performTap([match[@"x"] floatValue], [match[@"y"] floatValue], 30);
                    } else if (task.actionAfterFound == 2) {
                        // 点击区域中心
                        UIImage *template = [UIImage imageWithData:task.templateData];
                        CGFloat scale = UIScreen.mainScreen.scale;
                        CGFloat tw = template.size.width;
                        CGFloat th = template.size.height;
                        performTap([match[@"x"] floatValue], [match[@"y"] floatValue], 30);
                    }
                } else {
                    [self addLog:[NSString stringWithFormat:@"识图未匹配 (阈值: %.0f%%)", task.threshold*100]];
                }
            }
        }
        completion(YES);
    } else if ([task.type isEqual:@"colorMatch"]) {
        UIImage *ss = takeScreenshot();
        if (ss) {
            CGImageRef cg = ss.CGImage;
            if (cg) {
                int w = (int)CGImageGetWidth(cg), h = (int)CGImageGetHeight(cg);
                int px = (int)(task.x * UIScreen.mainScreen.scale);
                int py = (int)(task.y * UIScreen.mainScreen.scale);
                if (px >= 0 && px < w && py >= 0 && py < h) {
                    CGDataProviderRef dp = CGImageGetDataProvider(cg);
                    CFDataRef data = CGDataProviderCopyData(dp);
                    if (data) {
                        const uint8_t *bytes = CFDataGetBytePtr(data);
                        int bpp = 4; // RGBA
                        int offset = (py * w + px) * bpp;
                        if (offset + 3 < CFDataGetLength(data)) {
                            int r = bytes[offset+1], g = bytes[offset+2], b = bytes[offset+3];
                            int tol = (int)(task.threshold * 255);
                            int diff = abs(r-task.r) + abs(g-task.g) + abs(b-task.b);
                            BOOL match = diff <= tol * 3;
                            [self addLog:[NSString stringWithFormat:@"取色 (%d,%d,%d) → (%d,%d,%d) %@",
                                task.r, task.g, task.b, r, g, b, match ? @"匹配" : @"不匹配"]];
                            // 条件判断：conditionType=1 如果匹配成功跳转
                            if (match && task.conditionType == 1) {
                                self.currentIdx = task.gotoIndex;
                            } else if (!match && task.conditionType == 2) {
                                self.currentIdx = task.gotoIndex;
                            }
                        }
                        CFRelease(data);
                    }
                }
            }
        }
        completion(YES);
    } else if ([task.type isEqual:@"goto"]) {
        if (task.gotoIndex >= 0 && task.gotoIndex < self.tasks.count) {
            self.currentIdx = task.gotoIndex;
            [self addLog:[NSString stringWithFormat:@"跳转到第 %ld 条", (long)task.gotoIndex+1]];
        } else {
            [self addLog:[NSString stringWithFormat:@"跳转目标无效: %ld", (long)task.gotoIndex]];
        }
        completion(YES);
    } else if ([task.type isEqual:@"condition"]) {
        // 条件判断：根据前面任务的执行结果跳转
        // conditionType=1 跳到 gotoIndex, conditionType=2 跳到 gotoIndex+1
        if (task.conditionType == 1) {
            self.currentIdx = task.gotoIndex;
            [self addLog:[NSString stringWithFormat:@"条件→跳转到第 %ld 条", (long)task.gotoIndex+1]];
        }
        completion(YES);
    } else {
        [self addLog:[NSString stringWithFormat:@"未知类型: %@", task.type]];
        completion(YES);
    }
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
            for (NSInteger r = 0; r < task.repeatCount && self.running; r++) {
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                [self executeTask:task completion:^(BOOL ok) { dispatch_semaphore_signal(sem); }];
                dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
                if (!self.running) break;
            }
            if (!self.running) break;
            NSTimeInterval wait = task.postWait / 1000.0;
            if (wait > 0) [NSThread sleepForTimeInterval:wait];
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
static ACPassThroughWindow *g_floatWin;
static UIView *g_floatBall;
static UIView *g_panel;
static BOOL g_panelVisible = NO;
static BOOL g_isRecording = NO;
static NSMutableArray *g_recordedEvents;
static UIWindow *g_pickerWin;
static UIWindow *g_regionWin;
static UIWindow *g_configWin;
static NSInteger g_pickerPhase = 0;

// 多脚本管理
static NSMutableArray *g_profiles;   // 每个元素: @{@"name":NSString, @"tasks":NSMutableArray}
static NSInteger g_currentProfileIndex = 0;

// 设置选项
static BOOL g_autoRun = NO;           // 打开app后自动运行
static CGFloat g_autoRunDelay = 0;    // 自动运行延时(秒)
static BOOL g_autoClose = NO;         // 运行结束后自动关闭app
static CGFloat g_autoCloseDelay = 0;  // 关闭延时(秒)
static BOOL g_timerEnabled = NO;      // 定时启动
static NSMutableArray *g_timerTimes;  // 多个定时时间点: NSString @"HH:mm:ss"

// ==================== 主控制器 ====================
@interface ACCtrl : NSObject
@end
@implementation ACCtrl

+ (instancetype)shared {
    static ACCtrl *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        g_logs = [NSMutableArray array];
        g_taskList = [NSMutableArray array];
        g_recordedEvents = [NSMutableArray array];
        g_timerTimes = [NSMutableArray array];
        g_profiles = [NSMutableArray array];
        // 默认脚本
        [g_profiles addObject:[@{@"name":@"默认", @"tasks":g_taskList} mutableCopy]];
        g_currentProfileIndex = 0;
        [self loadProfiles];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onScriptDone:) name:@"ACScriptDone" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onLog:) name:@"ACLog" object:nil];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            [self saveProfiles];
        }];
    }
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

// ==================== 悬浮球（不阻塞触摸）====================
- (void)setupFloatUI {
    if (g_floatWin) return;
    CGRect sb = UIScreen.mainScreen.bounds;
    g_floatWin = [[ACPassThroughWindow alloc] initWithFrame:sb];
    g_floatWin.windowLevel = UIWindowLevelAlert - 1;
    g_floatWin.backgroundColor = UIColor.clearColor;
    g_floatWin.hidden = NO;
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = UIColor.clearColor;
    g_floatWin.rootViewController = vc;

    // 悬浮球 - 使用图标
    NSData *imgData = [NSData dataWithBytes:kIconPNG length:kIconPNGSize];
    UIImage *iconImg = [UIImage imageWithData:imgData];

    g_floatBall = [UIButton buttonWithType:UIButtonTypeCustom];
    CGRect bf = CGRectMake(sb.size.width - 64, sb.size.height * 0.35, 48, 48);
    ((UIButton *)g_floatBall).frame = bf;
    ((UIButton *)g_floatBall).backgroundColor = [UIColor systemBlueColor];
    ((UIButton *)g_floatBall).layer.cornerRadius = 24;
    ((UIButton *)g_floatBall).clipsToBounds = YES;
    if (iconImg) {
        [((UIButton *)g_floatBall) setImage:iconImg forState:UIControlStateNormal];
        ((UIButton *)g_floatBall).imageView.contentMode = UIViewContentModeScaleAspectFit;
    } else {
        ((UIButton *)g_floatBall).backgroundColor = [UIColor systemBlueColor];
        [((UIButton *)g_floatBall) setTitle:@"⚡" forState:UIControlStateNormal];
    }
    // 阴影
    g_floatBall.layer.shadowColor = [UIColor blackColor].CGColor;
    g_floatBall.layer.shadowOffset = CGSizeMake(0, 2);
    g_floatBall.layer.shadowRadius = 4;
    g_floatBall.layer.shadowOpacity = 0.3;
    [((UIButton *)g_floatBall) addTarget:self action:@selector(onBallTap) forControlEvents:UIControlEventTouchUpInside];
    [g_floatBall addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onBallPan:)]];
    // 状态指示
    UIView *ind = [[UIView alloc] initWithFrame:CGRectMake(0, 42, 48, 6)];
    ind.backgroundColor = UIColor.greenColor; ind.tag = 999; ind.layer.cornerRadius = 3; ind.hidden = YES;
    [g_floatBall addSubview:ind];
    [vc.view addSubview:g_floatBall];
    NSLog(@"[AC] 悬浮球就绪");
}

- (void)onBallPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x+t.x, v.center.y+t.y);
    [g setTranslation:CGPointZero inView:v.superview];
    if (g.state == UIGestureRecognizerStateEnded) {
        CGRect sb = UIScreen.mainScreen.bounds;
        CGFloat x = v.center.x > sb.size.width/2 ? sb.size.width-26 : 26;
        [UIView animateWithDuration:0.25 animations:^{ v.center = CGPointMake(x, MAX(50, MIN(sb.size.height-50, v.center.y))); }];
    }
}

- (void)onBallTap {
    if (g_panelVisible) [self dismissPanel];
    else [self showPanel];
}

// ==================== 面板UI ====================
- (void)showPanel {
    if (g_panelVisible) return;
    g_panelVisible = YES;
    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat pw = 300;  // 缩小
    CGFloat ph = 420;
    CGFloat px = (sb.size.width-pw)/2, py = (sb.size.height-ph)/2;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(px, py, pw, ph)];
    panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    panel.layer.cornerRadius = 16;
    panel.clipsToBounds = YES;
    g_panel = panel;

    // 手势：拖拽（不允许缩放，固定尺寸）
    UIPanGestureRecognizer *panG = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPanelPan:)];
    panG.delegate = (id<UIGestureRecognizerDelegate>)self;
    [panel addGestureRecognizer:panG];

    // 标题栏
    UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, 44)];
    head.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    head.tag = 1000;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 140, 44)];
    title.text = @"胖虎连点器"; title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:15];
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.8;
    [head addSubview:title];
    
    // 设置按钮
    UIButton *settingsBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    settingsBtn.frame = CGRectMake(152, 6, 36, 32);
    settingsBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    settingsBtn.layer.cornerRadius = 6;
    [settingsBtn setTitle:@"⚙" forState:UIControlStateNormal];
    [settingsBtn setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
    settingsBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    settingsBtn.tag = 951;
    [settingsBtn addTarget:self action:@selector(onSettingsTap) forControlEvents:UIControlEventTouchUpInside];
    [head addSubview:settingsBtn];
    
    // 录制按钮（录像）- 靠左靠近设置
    UIButton *recBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    recBtn.frame = CGRectMake(192, 6, 36, 32);
    recBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    recBtn.layer.cornerRadius = 6;
    [recBtn setTitle:@"⏺" forState:UIControlStateNormal];
    [recBtn setTitleColor:[UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:1] forState:UIControlStateNormal];
    recBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    recBtn.tag = 950;
    [recBtn addTarget:self action:@selector(onRecordTap) forControlEvents:UIControlEventTouchUpInside];
    [head addSubview:recBtn];
    
    // 状态指示器
    UIView *statusDot = [[UIView alloc] initWithFrame:CGRectMake(pw-44, 16, 8, 8)];
    statusDot.layer.cornerRadius = 4;
    statusDot.backgroundColor = [UIColor grayColor];
    statusDot.tag = 900;
    [head addSubview:statusDot];
    
    // 关闭按钮
    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(pw-32, 0, 32, 44);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16];
    [close addTarget:self action:@selector(dismissPanel) forControlEvents:UIControlEventTouchUpInside];
    [head addSubview:close];
    [panel addSubview:head];

    // 左侧动作按钮栏（全高，按钮均匀分布，适合触摸）
    CGFloat leftW = 40;
    CGFloat actionBarH = ph - 44 - 44 - 46;
    CGFloat btnH = actionBarH / 10;
    NSArray *actionItems = @[
        @[@"点击", @"click"],
        @[@"双击", @"doubleClick"],
        @[@"长按", @"longPress"],
        @[@"滑动", @"swipe"],
        @[@"等待", @"wait"],
        @[@"识图", @"findImage"],
        @[@"识字", @"ocr"],
        @[@"取色", @"colorMatch"],
        @[@"跳转", @"goto"],
        @[@"条件", @"condition"],
    ];
    CGFloat actionY = 44;
    UIView *actionBar = [[UIView alloc] initWithFrame:CGRectMake(0, actionY, leftW, actionBarH)];
    actionBar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
    actionBar.tag = 1100;
    [panel addSubview:actionBar];

    for (int i = 0; i < actionItems.count; i++) {
        NSArray *item = actionItems[i];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, i*btnH, leftW, btnH);
        btn.tag = i;
        btn.backgroundColor = [UIColor clearColor];
        // 文字（全屏居中）
        UILabel *txtLb = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, leftW, btnH)];
        txtLb.text = item[0]; txtLb.textAlignment = NSTextAlignmentCenter;
        txtLb.font = [UIFont boldSystemFontOfSize:15];
        txtLb.textColor = [UIColor colorWithWhite:0.7 alpha:1];
        [btn addSubview:txtLb];
        // 分割线
        if (i < actionItems.count-1) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(4, btnH-0.5, leftW-8, 0.5)];
            line.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
            [btn addSubview:line];
        }
        objc_setAssociatedObject(btn, "type", item[1], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [btn addTarget:self action:@selector(onActionBtnTap:) forControlEvents:UIControlEventTouchUpInside];
        [actionBar addSubview:btn];
    }

    // 任务列表（右侧，从动作栏底部开始）
    CGFloat listX = leftW, listW = pw - leftW, listY = 44, listH = ph - 44 - 44 - 46;
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(listX, listY, listW, listH)];
    scroll.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
    scroll.tag = 500;
    scroll.showsVerticalScrollIndicator = NO;
    [panel addSubview:scroll];
    [self refreshTaskList];

    // 底部操作栏
    CGFloat bottomBarY = ph - 44 - 46;
    UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, bottomBarY, pw, 44)];
    bottomBar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
    bottomBar.tag = 1101;
    
    // 清空全部 - 红色垃圾桶
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    clearBtn.frame = CGRectMake(4, 6, 45, 32);
    clearBtn.backgroundColor = [UIColor colorWithRed:0.5 green:0.1 blue:0.1 alpha:1];
    clearBtn.layer.cornerRadius = 6;
    [clearBtn setTitle:@"🗑" forState:UIControlStateNormal];
    [clearBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [clearBtn addTarget:self action:@selector(clearAllTasks) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:clearBtn];
    
    // 保存脚本按钮
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.frame = CGRectMake(53, 6, 55, 32);
    saveBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.4 blue:0.8 alpha:1];
    saveBtn.layer.cornerRadius = 6;
    [saveBtn setTitle:@"💾保存" forState:UIControlStateNormal];
    [saveBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    saveBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    saveBtn.tag = 960;
    [saveBtn addTarget:self action:@selector(onSaveCurrentScript) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:saveBtn];

    UIButton *startBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    startBtn.frame = CGRectMake(112, 6, pw-116, 32);
    startBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:1];
    startBtn.layer.cornerRadius = 6;
    [startBtn setTitle:@"▶开始" forState:UIControlStateNormal];
    [startBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    startBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    startBtn.titleLabel.adjustsFontSizeToFitWidth = YES; startBtn.titleLabel.minimumScaleFactor = 0.6;
    startBtn.tag = 600;
    [startBtn addTarget:self action:@selector(onStartTasks) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:startBtn];
    [panel addSubview:bottomBar];

    // 日志区域
    CGFloat logY = ph - 46;
    UIView *logView = [[UIView alloc] initWithFrame:CGRectMake(0, logY, pw, 46)];
    logView.backgroundColor = [UIColor colorWithWhite:0.04 alpha:1];
    logView.tag = 801;
    
    UILabel *logTitle = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, 60, 16)];
    logTitle.text = @"📋运行日志";
    logTitle.textColor = [UIColor lightGrayColor];
    logTitle.font = [UIFont systemFontOfSize:12];
    [logView addSubview:logTitle];
    
    UIScrollView *logScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 22, pw, 22)];
    logScroll.tag = 800;
    logScroll.showsVerticalScrollIndicator = NO;
    [logView addSubview:logScroll];
    
    [panel addSubview:logView];

    [g_floatWin.rootViewController.view addSubview:panel];
    panel.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{ panel.alpha = 1; }];
    
    [self updateStatus:0];
    [self addLog:@"脚本就绪"];
}

// 左侧动作按钮点击
- (void)onActionBtnTap:(UIButton *)sender {
    NSString *type = objc_getAssociatedObject(sender, "type");
    // 移除编辑面板
    [[g_panel viewWithTag:700] removeFromSuperview];
    [[g_panel viewWithTag:701] removeFromSuperview];
    [[g_panel viewWithTag:702] removeFromSuperview];
    [[g_panel viewWithTag:703] removeFromSuperview];
    ACTask *task = [[ACTask alloc] init];
    task.type = type;
    [g_taskList addObject:task];
    [self saveTasks];
    [self showEditPanel:task];
}

// ==================== 新增任务 ====================
- (void)addNewTask {
    // 显示动作类型选择菜单
    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat mw = 200, mh = 260;
    CGFloat mx = (sb.size.width-mw)/2, my = (sb.size.height-mh)/2;
    UIView *menu = [[UIView alloc] initWithFrame:CGRectMake(mx, my, mw, mh)];
    menu.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    menu.layer.cornerRadius = 14; menu.clipsToBounds = YES;
    menu.tag = 700;
    [g_panel addSubview:menu];

    UIButton *backBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    backBtn.frame = CGRectMake(0, 0, 44, 36);
    [backBtn setTitle:@"✕" forState:UIControlStateNormal];
    [backBtn setTitleColor:[UIColor grayColor] forState:UIControlStateNormal];
    backBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [backBtn addTarget:self action:@selector(dismissActionMenu) forControlEvents:UIControlEventTouchUpInside];
    [menu addSubview:backBtn];

    NSArray *items = @[@"点击", @"双击", @"长按", @"滑动", @"等待", @"识图", @"识字"];
    NSArray *types = @[@"click", @"doubleClick", @"longPress", @"swipe", @"wait", @"findImage", @"ocr"];
    for (int i = 0; i < items.count; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, i*36, mw, 36);
        [btn setTitle:items[i] forState:UIControlStateNormal];
        [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:14];
        btn.tag = i;
        [btn addTarget:self action:@selector(onAddNewTaskTypeSelected:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(btn, "type", types[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (i < items.count-1) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(20, 35, mw-40, 0.5)];
            line.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
            [btn addSubview:line];
        }
        [menu addSubview:btn];
    }
}

- (void)onAddNewTaskTypeSelected:(UIButton *)sender {
    NSString *type = objc_getAssociatedObject(sender, "type");
    [[g_panel viewWithTag:700] removeFromSuperview];
    ACTask *task = [[ACTask alloc] init];
    task.type = type;
    [g_taskList addObject:task];
    [self saveTasks];
    [self showEditPanel:task];
}

// ==================== 编辑面板入口 ====================
- (void)showEditPanel:(ACTask *)task {
    // 移除已有编辑面板
    [[g_panel viewWithTag:700] removeFromSuperview];
    [[g_panel viewWithTag:701] removeFromSuperview];
    [[g_panel viewWithTag:702] removeFromSuperview];
    [[g_panel viewWithTag:703] removeFromSuperview];
    
    if ([task.type isEqual:@"click"]) {
        [self showClickEditPanel:task];
    } else if ([task.type isEqual:@"doubleClick"]) {
        [self showDoubleClickEditPanel:task];
    } else if ([task.type isEqual:@"longPress"]) {
        [self showLongPressEditPanel:task];
    } else if ([task.type isEqual:@"swipe"]) {
        [self showSwipeEditPanel:task];
    } else if ([task.type isEqual:@"wait"]) {
        [self showWaitEditPanel:task];
    } else if ([task.type isEqual:@"findImage"]) {
        [self showFindImageEditPanel:task];
    } else if ([task.type isEqual:@"ocr"]) {
        [self showOCREditPanel:task];
    } else if ([task.type isEqual:@"colorMatch"]) {
        [self showColorMatchEditPanel:task];
    } else if ([task.type isEqual:@"goto"]) {
        [self showGotoEditPanel:task];
    } else if ([task.type isEqual:@"condition"]) {
        [self showConditionEditPanel:task];
    }
}

// ==================== 通用编辑面板工厂 ====================
// 创建一个编辑面板覆盖层，返回card视图供子类添加具体字段
- (UIView *)createEditPanelOverlay:(ACTask *)task title:(NSString *)title {
    CGRect screen = UIScreen.mainScreen.bounds;
    // 全屏半透明遮罩，点击遮罩关闭，允许编辑面板拖出去到连点器界面外
    UIView *mask = [[UIView alloc] initWithFrame:screen];
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    mask.tag = 701;
    mask.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissEditPanel)];
    [mask addGestureRecognizer:tap];
    [g_floatWin.rootViewController.view addSubview:mask];
    
    // 居中卡片（可拖拽到全屏任意位置，scrollview保证内容完整）
    CGFloat cw = 280;
    CGFloat contentHeight = 300 + 40;  // 预留底部按钮空间
    CGFloat ch = MIN(contentHeight, screen.size.height - 40);  // 不超过屏幕
    CGFloat cx = (screen.size.width-cw)/2, cy = (screen.size.height-ch)/2;
    UIScrollView *card = [[UIScrollView alloc] initWithFrame:CGRectMake(cx, cy, cw, ch)];
    card.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.98];
    card.layer.cornerRadius = 14;
    card.clipsToBounds = YES;
    card.tag = 702;
    card.showsVerticalScrollIndicator = YES;
    card.userInteractionEnabled = YES;
    card.contentSize = CGSizeMake(cw, contentHeight + 50);
    // 添加拖拽手势（卡片本身可拖）
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onEditPanelPan:)];
    pan.cancelsTouchesInView = NO;
    [card addGestureRecognizer:pan];
    objc_setAssociatedObject(card, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [g_floatWin.rootViewController.view addSubview:card];
    
    // 标题
    UILabel *titleLb = [[UILabel alloc] initWithFrame:CGRectMake(0, 16, cw, 24)];
    titleLb.text = title;
    titleLb.textColor = UIColor.whiteColor;
    titleLb.textAlignment = NSTextAlignmentCenter;
    titleLb.font = [UIFont boldSystemFontOfSize:17];
    [card addSubview:titleLb];
    // 拖拽指示条
    UIView *dragBar = [[UIView alloc] initWithFrame:CGRectMake(cw/2-20, 6, 40, 4)];
    dragBar.backgroundColor = [UIColor colorWithWhite:0.5 alpha:1];
    dragBar.layer.cornerRadius = 2;
    [card addSubview:dragBar];
    
    // 通用字段：备注
    UILabel *descLb = [[UILabel alloc] initWithFrame:CGRectMake(20, 48, 60, 28)];
    descLb.text = @"备注";
    descLb.textColor = [UIColor lightGrayColor];
    descLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:descLb];
    UITextField *descTf = [[UITextField alloc] initWithFrame:CGRectMake(80, 48, cw-100, 28)];
    descTf.placeholder = @"任务描述";
    descTf.text = task.desc;
    descTf.textColor = UIColor.whiteColor;
    descTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    descTf.layer.cornerRadius = 6;
    descTf.font = [UIFont systemFontOfSize:13];
    descTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    descTf.leftViewMode = UITextFieldViewModeAlways;
    descTf.tag = 10001;
    [card addSubview:descTf];
    
    // 通用字段：执行次数
    UILabel *repeatLb = [[UILabel alloc] initWithFrame:CGRectMake(20, 84, 80, 28)];
    repeatLb.text = @"执行次数";
    repeatLb.textColor = [UIColor lightGrayColor];
    repeatLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:repeatLb];
    UITextField *repeatTf = [[UITextField alloc] initWithFrame:CGRectMake(100, 84, 80, 28)];
    repeatTf.text = [NSString stringWithFormat:@"%ld", (long)task.repeatCount];
    repeatTf.textColor = UIColor.whiteColor;
    repeatTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    repeatTf.layer.cornerRadius = 6;
    repeatTf.font = [UIFont systemFontOfSize:13];
    repeatTf.keyboardType = UIKeyboardTypeNumberPad;
    repeatTf.textAlignment = NSTextAlignmentCenter;
    repeatTf.tag = 10002;
    repeatTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    repeatTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:repeatTf];
    UILabel *repeatHint = [[UILabel alloc] initWithFrame:CGRectMake(188, 84, 80, 28)];
    repeatHint.text = @"(0=无限)";
    repeatHint.textColor = [UIColor grayColor];
    repeatHint.font = [UIFont systemFontOfSize:10];
    [card addSubview:repeatHint];
    
    // 通用字段：执行后等待
    UILabel *postWaitLb = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, 100, 28)];
    postWaitLb.text = @"执行前等待";
    postWaitLb.textColor = [UIColor lightGrayColor];
    postWaitLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:postWaitLb];
    UITextField *postWaitTf = [[UITextField alloc] initWithFrame:CGRectMake(120, 120, 80, 28)];
    postWaitTf.text = [NSString stringWithFormat:@"%.0f", task.postWait];
    postWaitTf.textColor = UIColor.whiteColor;
    postWaitTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    postWaitTf.layer.cornerRadius = 6;
    postWaitTf.font = [UIFont systemFontOfSize:13];
    postWaitTf.keyboardType = UIKeyboardTypeNumberPad;
    postWaitTf.textAlignment = NSTextAlignmentCenter;
    postWaitTf.tag = 10003;
    postWaitTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    postWaitTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:postWaitTf];
    UILabel *postWaitUnit = [[UILabel alloc] initWithFrame:CGRectMake(206, 120, 50, 28)];
    postWaitUnit.text = @"ms";
    postWaitUnit.textColor = [UIColor grayColor];
    postWaitUnit.font = [UIFont systemFontOfSize:12];
    [card addSubview:postWaitUnit];
    
    return card;
}

// 保存单个编辑面板的通用字段和类型特定字段
- (void)saveEditPanel:(UIView *)card {
    ACTask *task = objc_getAssociatedObject(card, "task");
    UITextField *descTf = [card viewWithTag:10001];
    UITextField *repeatTf = [card viewWithTag:10002];
    UITextField *postWaitTf = [card viewWithTag:10003];
    if (descTf) task.desc = descTf.text ?: @"";
    if (repeatTf) task.repeatCount = [repeatTf.text integerValue];
    if (postWaitTf) task.postWait = [postWaitTf.text doubleValue];
    [self saveTasks];
    [self refreshTaskList];
    [self addLog:[NSString stringWithFormat:@"已保存: %@", task.desc ?: task.type]];
}

// 编辑面板拖拽（拖拽时禁用滚动，只在顶部可拖）
- (void)onEditPanelPan:(UIPanGestureRecognizer *)g {
    static CGPoint startCenter;
    static BOOL fromTopOnly;
    UIView *card = g.view;
    if (g.state == UIGestureRecognizerStateBegan) {
        CGPoint loc = [g locationInView:card];
        fromTopOnly = (loc.y < 50); // 只在标题区域拖拽
        if (!fromTopOnly) {
            g.state = UIGestureRecognizerStateCancelled;
            return;
        }
        startCenter = card.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:card.superview];
        card.center = CGPointMake(startCenter.x + t.x, startCenter.y + t.y);
    }
}

// 关闭编辑面板
- (void)dismissEditPanel {
    [[g_floatWin.rootViewController.view viewWithTag:701] removeFromSuperview];
    [[g_floatWin.rootViewController.view viewWithTag:702] removeFromSuperview];
    [[g_floatWin.rootViewController.view viewWithTag:703] removeFromSuperview];
    [[g_panel viewWithTag:701] removeFromSuperview];
    [[g_panel viewWithTag:702] removeFromSuperview];
    [[g_panel viewWithTag:703] removeFromSuperview];
}

// ==================== 各类型编辑面板 ====================

// 点击编辑面板
- (void)showClickEditPanel:(ACTask *)task {
    UIView *card = [self createEditPanelOverlay:task title:@"编辑 - 点击"];
    CGFloat cw = card.frame.size.width;
    CGFloat y = 158;
    
    // 坐标
    UILabel *coordLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 60, 28)];
    coordLb.text = @"坐标X";
    coordLb.textColor = [UIColor lightGrayColor];
    coordLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:coordLb];
    UITextField *xTf = [[UITextField alloc] initWithFrame:CGRectMake(80, y, 60, 28)];
    xTf.text = [NSString stringWithFormat:@"%.0f", task.x];
    xTf.textColor = UIColor.whiteColor;
    xTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    xTf.layer.cornerRadius = 6;
    xTf.font = [UIFont systemFontOfSize:13];
    xTf.keyboardType = UIKeyboardTypeNumberPad;
    xTf.textAlignment = NSTextAlignmentCenter;
    xTf.tag = 10010;
    xTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    xTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:xTf];
    
    UILabel *coordY = [[UILabel alloc] initWithFrame:CGRectMake(150, y, 20, 28)];
    coordY.text = @"Y";
    coordY.textColor = [UIColor lightGrayColor];
    coordY.font = [UIFont systemFontOfSize:13];
    [card addSubview:coordY];
    UITextField *yTf = [[UITextField alloc] initWithFrame:CGRectMake(170, y, 60, 28)];
    yTf.text = [NSString stringWithFormat:@"%.0f", task.y];
    yTf.textColor = UIColor.whiteColor;
    yTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    yTf.layer.cornerRadius = 6;
    yTf.font = [UIFont systemFontOfSize:13];
    yTf.keyboardType = UIKeyboardTypeNumberPad;
    yTf.textAlignment = NSTextAlignmentCenter;
    yTf.tag = 10011;
    yTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    yTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:yTf];
    
    UIButton *pickBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    pickBtn.frame = CGRectMake(20, y+36, cw-40, 32);
    pickBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:1];
    pickBtn.layer.cornerRadius = 16;
    [pickBtn setTitle:@"拾取坐标" forState:UIControlStateNormal];
    [pickBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    pickBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    objc_setAssociatedObject(pickBtn, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(pickBtn, "xField", @(10010), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(pickBtn, "yField", @(10011), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [pickBtn addTarget:self action:@selector(onPickCoordForEditPanel:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:pickBtn];
    
    // 按下时长
    UILabel *holdLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y+78, 80, 28)];
    holdLb.text = @"按下时长";
    holdLb.textColor = [UIColor lightGrayColor];
    holdLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:holdLb];
    UITextField *holdTf = [[UITextField alloc] initWithFrame:CGRectMake(100, y+78, 80, 28)];
    holdTf.text = [NSString stringWithFormat:@"%.0f", task.holdMs];
    holdTf.textColor = UIColor.whiteColor;
    holdTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    holdTf.layer.cornerRadius = 6;
    holdTf.font = [UIFont systemFontOfSize:13];
    holdTf.keyboardType = UIKeyboardTypeNumberPad;
    holdTf.textAlignment = NSTextAlignmentCenter;
    holdTf.tag = 10012;
    holdTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    holdTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:holdTf];
    UILabel *holdUnit = [[UILabel alloc] initWithFrame:CGRectMake(186, y+78, 50, 28)];
    holdUnit.text = @"ms";
    holdUnit.textColor = [UIColor grayColor];
    holdUnit.font = [UIFont systemFontOfSize:12];
    [card addSubview:holdUnit];
    
    // 取消/保存按钮
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    cancelBtn.frame = CGRectMake(cw/2-100, y+120, 90, 34);
    cancelBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    cancelBtn.layer.cornerRadius = 17;
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [cancelBtn addTarget:self action:@selector(onEditPanelCancel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancelBtn];
    
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.frame = CGRectMake(cw/2+10, y+120, 90, 34);
    saveBtn.backgroundColor = [UIColor systemBlueColor];
    saveBtn.layer.cornerRadius = 17;
    [saveBtn setTitle:@"保存" forState:UIControlStateNormal];
    [saveBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    objc_setAssociatedObject(saveBtn, "card", card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "xField", @(10010), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "yField", @(10011), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "holdField", @(10012), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [saveBtn addTarget:self action:@selector(onClickEditSave:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:saveBtn];
    
    ((UIScrollView *)card).contentSize = CGSizeMake(cw, y+170);
}

// 双击编辑面板
- (void)showDoubleClickEditPanel:(ACTask *)task {
    UIView *card = [self createEditPanelOverlay:task title:@"编辑 - 双击"];
    CGFloat cw = card.frame.size.width;
    CGFloat y = 158;
    
    // 坐标
    UILabel *coordLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 60, 28)];
    coordLb.text = @"坐标X";
    coordLb.textColor = [UIColor lightGrayColor];
    coordLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:coordLb];
    UITextField *xTf = [[UITextField alloc] initWithFrame:CGRectMake(80, y, 60, 28)];
    xTf.text = [NSString stringWithFormat:@"%.0f", task.x];
    xTf.textColor = UIColor.whiteColor;
    xTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    xTf.layer.cornerRadius = 6;
    xTf.font = [UIFont systemFontOfSize:13];
    xTf.keyboardType = UIKeyboardTypeNumberPad;
    xTf.textAlignment = NSTextAlignmentCenter;
    xTf.tag = 10010;
    xTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    xTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:xTf];
    
    UILabel *coordY = [[UILabel alloc] initWithFrame:CGRectMake(150, y, 20, 28)];
    coordY.text = @"Y";
    coordY.textColor = [UIColor lightGrayColor];
    coordY.font = [UIFont systemFontOfSize:13];
    [card addSubview:coordY];
    UITextField *yTf = [[UITextField alloc] initWithFrame:CGRectMake(170, y, 60, 28)];
    yTf.text = [NSString stringWithFormat:@"%.0f", task.y];
    yTf.textColor = UIColor.whiteColor;
    yTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    yTf.layer.cornerRadius = 6;
    yTf.font = [UIFont systemFontOfSize:13];
    yTf.keyboardType = UIKeyboardTypeNumberPad;
    yTf.textAlignment = NSTextAlignmentCenter;
    yTf.tag = 10011;
    yTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    yTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:yTf];
    
    UIButton *pickBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    pickBtn.frame = CGRectMake(20, y+36, cw-40, 32);
    pickBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:1];
    pickBtn.layer.cornerRadius = 16;
    [pickBtn setTitle:@"拾取坐标" forState:UIControlStateNormal];
    [pickBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    pickBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    objc_setAssociatedObject(pickBtn, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(pickBtn, "xField", @(10010), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(pickBtn, "yField", @(10011), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [pickBtn addTarget:self action:@selector(onPickCoordForEditPanel:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:pickBtn];
    
    // 双击间隔
    UILabel *intervalLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y+78, 80, 28)];
    intervalLb.text = @"双击间隔";
    intervalLb.textColor = [UIColor lightGrayColor];
    intervalLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:intervalLb];
    UITextField *intervalTf = [[UITextField alloc] initWithFrame:CGRectMake(100, y+78, 80, 28)];
    intervalTf.text = [NSString stringWithFormat:@"%.0f", task.doubleClickInterval];
    intervalTf.textColor = UIColor.whiteColor;
    intervalTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    intervalTf.layer.cornerRadius = 6;
    intervalTf.font = [UIFont systemFontOfSize:13];
    intervalTf.keyboardType = UIKeyboardTypeNumberPad;
    intervalTf.textAlignment = NSTextAlignmentCenter;
    intervalTf.tag = 10012;
    intervalTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    intervalTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:intervalTf];
    UILabel *intervalUnit = [[UILabel alloc] initWithFrame:CGRectMake(186, y+78, 50, 28)];
    intervalUnit.text = @"ms";
    intervalUnit.textColor = [UIColor grayColor];
    intervalUnit.font = [UIFont systemFontOfSize:12];
    [card addSubview:intervalUnit];
    
    // 取消/保存
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    cancelBtn.frame = CGRectMake(cw/2-100, y+120, 90, 34);
    cancelBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    cancelBtn.layer.cornerRadius = 17;
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [cancelBtn addTarget:self action:@selector(onEditPanelCancel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancelBtn];
    
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.frame = CGRectMake(cw/2+10, y+120, 90, 34);
    saveBtn.backgroundColor = [UIColor systemBlueColor];
    saveBtn.layer.cornerRadius = 17;
    [saveBtn setTitle:@"保存" forState:UIControlStateNormal];
    [saveBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    objc_setAssociatedObject(saveBtn, "card", card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "xField", @(10010), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "yField", @(10011), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "intervalField", @(10012), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [saveBtn addTarget:self action:@selector(onDoubleClickEditSave:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:saveBtn];
    
    ((UIScrollView *)card).contentSize = CGSizeMake(cw, y+170);
}

// 长按编辑面板
- (void)showLongPressEditPanel:(ACTask *)task {
    UIView *card = [self createEditPanelOverlay:task title:@"编辑 - 长按"];
    CGFloat cw = card.frame.size.width;
    CGFloat y = 158;
    
    // 坐标
    UILabel *coordLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 60, 28)];
    coordLb.text = @"坐标X";
    coordLb.textColor = [UIColor lightGrayColor];
    coordLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:coordLb];
    UITextField *xTf = [[UITextField alloc] initWithFrame:CGRectMake(80, y, 60, 28)];
    xTf.text = [NSString stringWithFormat:@"%.0f", task.x];
    xTf.textColor = UIColor.whiteColor;
    xTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    xTf.layer.cornerRadius = 6;
    xTf.font = [UIFont systemFontOfSize:13];
    xTf.keyboardType = UIKeyboardTypeNumberPad;
    xTf.textAlignment = NSTextAlignmentCenter;
    xTf.tag = 10010;
    xTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    xTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:xTf];
    
    UILabel *coordY = [[UILabel alloc] initWithFrame:CGRectMake(150, y, 20, 28)];
    coordY.text = @"Y";
    coordY.textColor = [UIColor lightGrayColor];
    coordY.font = [UIFont systemFontOfSize:13];
    [card addSubview:coordY];
    UITextField *yTf = [[UITextField alloc] initWithFrame:CGRectMake(170, y, 60, 28)];
    yTf.text = [NSString stringWithFormat:@"%.0f", task.y];
    yTf.textColor = UIColor.whiteColor;
    yTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    yTf.layer.cornerRadius = 6;
    yTf.font = [UIFont systemFontOfSize:13];
    yTf.keyboardType = UIKeyboardTypeNumberPad;
    yTf.textAlignment = NSTextAlignmentCenter;
    yTf.tag = 10011;
    yTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    yTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:yTf];
    
    UIButton *pickBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    pickBtn.frame = CGRectMake(20, y+36, cw-40, 32);
    pickBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:1];
    pickBtn.layer.cornerRadius = 16;
    [pickBtn setTitle:@"拾取坐标" forState:UIControlStateNormal];
    [pickBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    pickBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    objc_setAssociatedObject(pickBtn, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(pickBtn, "xField", @(10010), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(pickBtn, "yField", @(10011), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [pickBtn addTarget:self action:@selector(onPickCoordForEditPanel:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:pickBtn];
    
    // 按住时长
    UILabel *holdLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y+78, 80, 28)];
    holdLb.text = @"按住时长";
    holdLb.textColor = [UIColor lightGrayColor];
    holdLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:holdLb];
    UITextField *holdTf = [[UITextField alloc] initWithFrame:CGRectMake(100, y+78, 80, 28)];
    holdTf.text = [NSString stringWithFormat:@"%.0f", task.holdMs];
    holdTf.textColor = UIColor.whiteColor;
    holdTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    holdTf.layer.cornerRadius = 6;
    holdTf.font = [UIFont systemFontOfSize:13];
    holdTf.keyboardType = UIKeyboardTypeNumberPad;
    holdTf.textAlignment = NSTextAlignmentCenter;
    holdTf.tag = 10012;
    holdTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    holdTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:holdTf];
    UILabel *holdUnit = [[UILabel alloc] initWithFrame:CGRectMake(186, y+78, 50, 28)];
    holdUnit.text = @"ms";
    holdUnit.textColor = [UIColor grayColor];
    holdUnit.font = [UIFont systemFontOfSize:12];
    [card addSubview:holdUnit];
    
    // 取消/保存
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    cancelBtn.frame = CGRectMake(cw/2-100, y+120, 90, 34);
    cancelBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    cancelBtn.layer.cornerRadius = 17;
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [cancelBtn addTarget:self action:@selector(onEditPanelCancel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancelBtn];
    
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.frame = CGRectMake(cw/2+10, y+120, 90, 34);
    saveBtn.backgroundColor = [UIColor systemBlueColor];
    saveBtn.layer.cornerRadius = 17;
    [saveBtn setTitle:@"保存" forState:UIControlStateNormal];
    [saveBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    objc_setAssociatedObject(saveBtn, "card", card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "xField", @(10010), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "yField", @(10011), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "holdField", @(10012), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [saveBtn addTarget:self action:@selector(onLongPressEditSave:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:saveBtn];
    
    ((UIScrollView *)card).contentSize = CGSizeMake(cw, y+170);
}

// 滑动编辑面板
- (void)showSwipeEditPanel:(ACTask *)task {
    UIView *card = [self createEditPanelOverlay:task title:@"编辑 - 滑动"];
    CGFloat cw = card.frame.size.width;
    CGFloat y = 158;
    
    // 起点坐标
    UILabel *startLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 60, 28)];
    startLb.text = @"起点X";
    startLb.textColor = [UIColor lightGrayColor];
    startLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:startLb];
    UITextField *x1Tf = [[UITextField alloc] initWithFrame:CGRectMake(80, y, 60, 28)];
    x1Tf.text = [NSString stringWithFormat:@"%.0f", task.x];
    x1Tf.textColor = UIColor.whiteColor;
    x1Tf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    x1Tf.layer.cornerRadius = 6;
    x1Tf.font = [UIFont systemFontOfSize:13];
    x1Tf.keyboardType = UIKeyboardTypeNumberPad;
    x1Tf.textAlignment = NSTextAlignmentCenter;
    x1Tf.tag = 10010;
    x1Tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    x1Tf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:x1Tf];
    UILabel *startY = [[UILabel alloc] initWithFrame:CGRectMake(150, y, 20, 28)];
    startY.text = @"Y";
    startY.textColor = [UIColor lightGrayColor];
    startY.font = [UIFont systemFontOfSize:13];
    [card addSubview:startY];
    UITextField *y1Tf = [[UITextField alloc] initWithFrame:CGRectMake(170, y, 60, 28)];
    y1Tf.text = [NSString stringWithFormat:@"%.0f", task.y];
    y1Tf.textColor = UIColor.whiteColor;
    y1Tf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    y1Tf.layer.cornerRadius = 6;
    y1Tf.font = [UIFont systemFontOfSize:13];
    y1Tf.keyboardType = UIKeyboardTypeNumberPad;
    y1Tf.textAlignment = NSTextAlignmentCenter;
    y1Tf.tag = 10011;
    y1Tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    y1Tf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:y1Tf];
    
    // 终点坐标
    UILabel *endLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y+36, 60, 28)];
    endLb.text = @"终点X";
    endLb.textColor = [UIColor lightGrayColor];
    endLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:endLb];
    UITextField *x2Tf = [[UITextField alloc] initWithFrame:CGRectMake(80, y+36, 60, 28)];
    x2Tf.text = [NSString stringWithFormat:@"%.0f", task.x2];
    x2Tf.textColor = UIColor.whiteColor;
    x2Tf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    x2Tf.layer.cornerRadius = 6;
    x2Tf.font = [UIFont systemFontOfSize:13];
    x2Tf.keyboardType = UIKeyboardTypeNumberPad;
    x2Tf.textAlignment = NSTextAlignmentCenter;
    x2Tf.tag = 10020;
    x2Tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    x2Tf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:x2Tf];
    UILabel *endY = [[UILabel alloc] initWithFrame:CGRectMake(150, y+36, 20, 28)];
    endY.text = @"Y";
    endY.textColor = [UIColor lightGrayColor];
    endY.font = [UIFont systemFontOfSize:13];
    [card addSubview:endY];
    UITextField *y2Tf = [[UITextField alloc] initWithFrame:CGRectMake(170, y+36, 60, 28)];
    y2Tf.text = [NSString stringWithFormat:@"%.0f", task.y2];
    y2Tf.textColor = UIColor.whiteColor;
    y2Tf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    y2Tf.layer.cornerRadius = 6;
    y2Tf.font = [UIFont systemFontOfSize:13];
    y2Tf.keyboardType = UIKeyboardTypeNumberPad;
    y2Tf.textAlignment = NSTextAlignmentCenter;
    y2Tf.tag = 10021;
    y2Tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    y2Tf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:y2Tf];
    
    // AB选择按钮（一次性选择起点+终点）
    UIButton *abPickBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    abPickBtn.frame = CGRectMake(20, y+72, cw-40, 38);
    abPickBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:1];
    abPickBtn.layer.cornerRadius = 19;
    [abPickBtn setTitle:@"🅰🅱 选择起点和终点" forState:UIControlStateNormal];
    [abPickBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    abPickBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    objc_setAssociatedObject(abPickBtn, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [abPickBtn addTarget:self action:@selector(onABSwipePick:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:abPickBtn];
    
    // 滑动时长
    UILabel *durLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y+118, 80, 28)];
    durLb.text = @"滑动时长";
    durLb.textColor = [UIColor lightGrayColor];
    durLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:durLb];
    UITextField *durTf = [[UITextField alloc] initWithFrame:CGRectMake(100, y+118, 80, 28)];
    durTf.text = [NSString stringWithFormat:@"%.0f", task.duration];
    durTf.textColor = UIColor.whiteColor;
    durTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    durTf.layer.cornerRadius = 6;
    durTf.font = [UIFont systemFontOfSize:13];
    durTf.keyboardType = UIKeyboardTypeNumberPad;
    durTf.textAlignment = NSTextAlignmentCenter;
    durTf.tag = 10012;
    durTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    durTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:durTf];
    UILabel *durUnit = [[UILabel alloc] initWithFrame:CGRectMake(186, y+118, 50, 28)];
    durUnit.text = @"ms";
    durUnit.textColor = [UIColor grayColor];
    durUnit.font = [UIFont systemFontOfSize:12];
    [card addSubview:durUnit];
    
    // 取消/确定
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    cancelBtn.frame = CGRectMake(cw/2-100, y+160, 90, 34);
    cancelBtn.backgroundColor = [UIColor colorWithRed:0.75 green:0.15 blue:0.15 alpha:1];
    cancelBtn.layer.cornerRadius = 17;
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [cancelBtn addTarget:self action:@selector(onEditPanelCancel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancelBtn];
    
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.frame = CGRectMake(cw/2+10, y+160, 90, 34);
    saveBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:1];
    saveBtn.layer.cornerRadius = 17;
    [saveBtn setTitle:@"确定" forState:UIControlStateNormal];
    [saveBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    objc_setAssociatedObject(saveBtn, "card", card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [saveBtn addTarget:self action:@selector(onSwipeEditSave:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:saveBtn];
    
    ((UIScrollView *)card).contentSize = CGSizeMake(cw, y+210);
}

// AB滑动选择（一次性选择起点+终点）
- (void)onABSwipePick:(UIButton *)sender {
    ACTask *task = objc_getAssociatedObject(sender, "task");
    [self dismissEditPanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGRect sb = UIScreen.mainScreen.bounds;
        g_pickerWin = [[ACPassThroughWindow alloc] initWithFrame:sb];
        g_pickerWin.windowLevel = UIWindowLevelAlert - 1;
        g_pickerWin.backgroundColor = UIColor.clearColor; g_pickerWin.hidden = NO;
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = UIColor.clearColor; g_pickerWin.rootViewController = vc;
        UIView *bg = [[UIView alloc] initWithFrame:sb];
        bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        [vc.view addSubview:bg];
        
        // 十字线
        UIView *hLine = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-40, sb.size.height/2-0.5, 80, 1)];
        hLine.backgroundColor = [UIColor redColor]; hLine.tag = 901; [bg addSubview:hLine];
        UIView *vLine = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-0.5, sb.size.height/2-40, 1, 80)];
        vLine.backgroundColor = [UIColor redColor]; vLine.tag = 902; [bg addSubview:vLine];
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-12, sb.size.height/2-12, 24, 24)];
        dot.layer.cornerRadius = 12; dot.backgroundColor = [UIColor redColor]; dot.alpha = 0.7; dot.tag = 903;
        dot.layer.borderColor = UIColor.whiteColor.CGColor; dot.layer.borderWidth = 2;
        [bg addSubview:dot];
        
        // A/B标记文字
        UILabel *aLabel = [[UILabel alloc] initWithFrame:CGRectMake(sb.size.width/2-8, sb.size.height/2-8, 16, 16)];
        aLabel.text = @"A"; aLabel.textColor = UIColor.whiteColor; aLabel.font = [UIFont boldSystemFontOfSize:14];
        aLabel.textAlignment = NSTextAlignmentCenter; aLabel.tag = 906;
        [bg addSubview:aLabel];
        
        UIImageView *bDot = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
        bDot.hidden = YES; bDot.tag = 907;
        bDot.backgroundColor = [UIColor blueColor]; bDot.layer.cornerRadius = 12;
        bDot.layer.borderColor = UIColor.whiteColor.CGColor; bDot.layer.borderWidth = 2;
        [bg addSubview:bDot];
        UILabel *bLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 16, 16)];
        bLabel.text = @"B"; bLabel.textColor = UIColor.whiteColor; bLabel.font = [UIFont boldSystemFontOfSize:14];
        bLabel.textAlignment = NSTextAlignmentCenter; bLabel.tag = 908;
        [bg addSubview:bLabel];
        
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, sb.size.width-40, 36)];
        hint.text = @"点击选择 🅰 起点"; hint.textColor = UIColor.whiteColor;
        hint.textAlignment = NSTextAlignmentCenter; hint.font = [UIFont boldSystemFontOfSize:16];
        hint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6]; hint.layer.cornerRadius = 10;
        hint.clipsToBounds = YES; hint.tag = 904;
        [bg addSubview:hint];
        
        UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
        cancel.frame = CGRectMake(sb.size.width/2-50, sb.size.height-100, 100, 36);
        cancel.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1];
        cancel.layer.cornerRadius = 18;
        [cancel setTitle:@"取消" forState:UIControlStateNormal];
        [cancel setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        cancel.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [cancel addTarget:self action:@selector(onPickerCancel) forControlEvents:UIControlEventTouchUpInside];
        [bg addSubview:cancel];
        
        objc_setAssociatedObject(bg, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        g_pickerPhase = 0;
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(abPickerPan:)];
        [bg addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(abPickerTap:)];
        [bg addGestureRecognizer:tap];
    });
}
- (void)abPickerPan:(UIPanGestureRecognizer *)g {
    CGPoint pt = [g locationInView:g.view];
    UIView *bg = g.view;
    [bg viewWithTag:901].frame = CGRectMake(pt.x-40, pt.y-0.5, 80, 1);
    [bg viewWithTag:902].frame = CGRectMake(pt.x-0.5, pt.y-40, 1, 80);
    [bg viewWithTag:903].center = pt;
    UILabel *hint = [bg viewWithTag:904];
    if (g_pickerPhase == 0) {
        hint.text = [NSString stringWithFormat:@"🅰 选择起点: (%.0f, %.0f)", pt.x, pt.y];
        [bg viewWithTag:906].center = pt;
    } else {
        hint.text = [NSString stringWithFormat:@"🅱 选择终点: (%.0f, %.0f)", pt.x, pt.y];
        [bg viewWithTag:908].center = pt;
    }
    if (g.state == UIGestureRecognizerStateEnded) {
        [self abPickerConfirm:pt];
    }
}
- (void)abPickerTap:(UITapGestureRecognizer *)g {
    [self abPickerConfirm:[g locationInView:g.view]];
}
- (void)abPickerConfirm:(CGPoint)pt {
    if (g_pickerPhase == 99) return;
    UIView *bg = g_pickerWin.rootViewController.view.subviews.firstObject;
    if (!bg) return;
    ACTask *task = objc_getAssociatedObject(bg, "task");
    if (g_pickerPhase == 0) {
        task.x = pt.x; task.y = pt.y;
        g_pickerPhase = 1;
        // 固定A点，显示B点标记
        UIView *bDot = [bg viewWithTag:907];
        bDot.hidden = NO;
        UIView *bLabel = [bg viewWithTag:908];
        bLabel.hidden = NO;
        // 更新A点颜色
        UIView *dot = [bg viewWithTag:903];
        dot.backgroundColor = [UIColor greenColor];
        // 启用B点标记
        bDot.center = pt;
        bLabel.center = pt;
        UILabel *hint = [bg viewWithTag:904];
        hint.text = @"点击选择 🅱 终点";
        // 移动十字线到B点
        [bg viewWithTag:901].frame = CGRectMake(pt.x-40, pt.y-0.5, 80, 1);
        [bg viewWithTag:902].frame = CGRectMake(pt.x-0.5, pt.y-40, 1, 80);
        return;
    }
    task.x2 = pt.x; task.y2 = pt.y;
    g_pickerPhase = 99;
    [g_pickerWin setHidden:YES]; g_pickerWin = nil;
    // 更新编辑面板中的坐标
    [self showSwipeEditPanel:task];
}

// 等待编辑面板
- (void)showWaitEditPanel:(ACTask *)task {
    UIView *card = [self createEditPanelOverlay:task title:@"编辑 - 等待"];
    CGFloat cw = card.frame.size.width;
    CGFloat y = 158;
    
    // 默认等待时长改为1000ms
    if (task.duration >= 500) task.duration = 1.0;
    
    // 等待时长
    UILabel *durLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 80, 28)];
    durLb.text = @"等待时长";
    durLb.textColor = [UIColor lightGrayColor];
    durLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:durLb];
    UITextField *durTf = [[UITextField alloc] initWithFrame:CGRectMake(100, y, 80, 28)];
    durTf.text = [NSString stringWithFormat:@"%.0f", task.duration * 1000];
    durTf.textColor = UIColor.whiteColor;
    durTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    durTf.layer.cornerRadius = 6;
    durTf.font = [UIFont systemFontOfSize:13];
    durTf.keyboardType = UIKeyboardTypeNumberPad;
    durTf.textAlignment = NSTextAlignmentCenter;
    durTf.tag = 10010;
    durTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    durTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:durTf];
    UILabel *durUnit = [[UILabel alloc] initWithFrame:CGRectMake(186, y, 50, 28)];
    durUnit.text = @"ms";
    durUnit.textColor = [UIColor grayColor];
    durUnit.font = [UIFont systemFontOfSize:12];
    [card addSubview:durUnit];
    
    // 取消/确定
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    cancelBtn.frame = CGRectMake(cw/2-100, y+50, 90, 34);
    cancelBtn.backgroundColor = [UIColor colorWithRed:0.75 green:0.15 blue:0.15 alpha:1];
    cancelBtn.layer.cornerRadius = 17;
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [cancelBtn addTarget:self action:@selector(onEditPanelCancel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancelBtn];
    
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.frame = CGRectMake(cw/2+10, y+50, 90, 34);
    saveBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:1];
    saveBtn.layer.cornerRadius = 17;
    [saveBtn setTitle:@"确定" forState:UIControlStateNormal];
    [saveBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    objc_setAssociatedObject(saveBtn, "card", card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "durField", @(10010), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [saveBtn addTarget:self action:@selector(onWaitEditSave:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:saveBtn];
    
    ((UIScrollView *)card).contentSize = CGSizeMake(cw, y+100);
}

// 识图编辑面板
- (void)showFindImageEditPanel:(ACTask *)task {
    UIView *card = [self createEditPanelOverlay:task title:@"编辑 - 识图"];
    CGFloat cw = card.frame.size.width;
    CGFloat y = 158;
    
    // 相似度阈值
    UILabel *threshLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 80, 28)];
    threshLb.text = @"相似度";
    threshLb.textColor = [UIColor lightGrayColor];
    threshLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:threshLb];
    UITextField *threshTf = [[UITextField alloc] initWithFrame:CGRectMake(100, y, 80, 28)];
    threshTf.text = [NSString stringWithFormat:@"%.0f", task.threshold * 100];
    threshTf.textColor = UIColor.whiteColor;
    threshTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    threshTf.layer.cornerRadius = 6;
    threshTf.font = [UIFont systemFontOfSize:13];
    threshTf.keyboardType = UIKeyboardTypeNumberPad;
    threshTf.textAlignment = NSTextAlignmentCenter;
    threshTf.tag = 10010;
    threshTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    threshTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:threshTf];
    UILabel *threshUnit = [[UILabel alloc] initWithFrame:CGRectMake(186, y, 50, 28)];
    threshUnit.text = @"%";
    threshUnit.textColor = [UIColor grayColor];
    threshUnit.font = [UIFont systemFontOfSize:12];
    [card addSubview:threshUnit];
    
    // 找到后动作
    UILabel *actionLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y+36, 80, 28)];
    actionLb.text = @"找到后";
    actionLb.textColor = [UIColor lightGrayColor];
    actionLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:actionLb];
    
    UISegmentedControl *actionSeg = [[UISegmentedControl alloc] initWithItems:@[@"不执行", @"点击匹配", @"点击中心"]];
    actionSeg.frame = CGRectMake(20, y+68, cw-40, 32);
    actionSeg.selectedSegmentIndex = task.actionAfterFound;
    actionSeg.tintColor = [UIColor systemBlueColor];
    actionSeg.tag = 10030;
    [card addSubview:actionSeg];
    
    // 模板图片预览
    UILabel *previewLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y+110, 100, 28)];
    previewLb.text = @"模板图片";
    previewLb.textColor = [UIColor lightGrayColor];
    previewLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:previewLb];
    
    UIImageView *previewIv = [[UIImageView alloc] initWithFrame:CGRectMake(cw-80, y+108, 56, 56)];
    previewIv.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    previewIv.contentMode = UIViewContentModeScaleAspectFit;
    previewIv.layer.cornerRadius = 6;
    previewIv.clipsToBounds = YES;
    previewIv.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1].CGColor;
    previewIv.layer.borderWidth = 0.5;
    previewIv.tag = 10040;
    if (task.templateData) {
        previewIv.image = [UIImage imageWithData:task.templateData];
    }
    [card addSubview:previewIv];
    
    // 模板图片选择按钮（局部截图 + 相册选择）
    UIButton *screenshotBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    screenshotBtn.frame = CGRectMake(20, y+146, (cw-50)/2, 32);
    screenshotBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:1];
    screenshotBtn.layer.cornerRadius = 16;
    [screenshotBtn setTitle:@"局部截图" forState:UIControlStateNormal];
    [screenshotBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    screenshotBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    objc_setAssociatedObject(screenshotBtn, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [screenshotBtn addTarget:self action:@selector(onFindImageScreenshotSelect:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:screenshotBtn];
    
    UIButton *albumBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    albumBtn.frame = CGRectMake(cw/2+10, y+146, (cw-50)/2, 32);
    albumBtn.backgroundColor = [UIColor colorWithRed:0.6 green:0.4 blue:0.2 alpha:1];
    albumBtn.layer.cornerRadius = 16;
    [albumBtn setTitle:@"相册选择" forState:UIControlStateNormal];
    [albumBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    albumBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    objc_setAssociatedObject(albumBtn, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [albumBtn addTarget:self action:@selector(onFindImageAlbumSelect:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:albumBtn];
    
    // 取消/确定
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    cancelBtn.frame = CGRectMake(cw/2-100, y+192, 90, 34);
    cancelBtn.backgroundColor = [UIColor colorWithRed:0.75 green:0.15 blue:0.15 alpha:1];
    cancelBtn.layer.cornerRadius = 17;
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [cancelBtn addTarget:self action:@selector(onEditPanelCancel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancelBtn];
    
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.frame = CGRectMake(cw/2+10, y+192, 90, 34);
    saveBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:1];
    saveBtn.layer.cornerRadius = 17;
    [saveBtn setTitle:@"确定" forState:UIControlStateNormal];
    [saveBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    objc_setAssociatedObject(saveBtn, "card", card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "threshField", @(10010), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "actionSeg", @(10030), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [saveBtn addTarget:self action:@selector(onFindImageEditSave:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:saveBtn];
    
    ((UIScrollView *)card).contentSize = CGSizeMake(cw, y+240);
}

// 识字编辑面板
- (void)showOCREditPanel:(ACTask *)task {
    UIView *card = [self createEditPanelOverlay:task title:@"编辑 - 识字"];
    CGFloat cw = card.frame.size.width;
    CGFloat y = 158;
    
    // 目标文字
    UILabel *textLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 80, 28)];
    textLb.text = @"目标文字";
    textLb.textColor = [UIColor lightGrayColor];
    textLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:textLb];
    UITextField *textTf = [[UITextField alloc] initWithFrame:CGRectMake(20, y+32, cw-40, 32)];
    textTf.text = task.targetText;
    textTf.placeholder = @"留空匹配任意文字";
    textTf.textColor = UIColor.whiteColor;
    textTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    textTf.layer.cornerRadius = 6;
    textTf.font = [UIFont systemFontOfSize:14];
    textTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,10,32)];
    textTf.leftViewMode = UITextFieldViewModeAlways;
    textTf.tag = 10010;
    [card addSubview:textTf];
    
    // 置信度阈值
    UILabel *confLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y+74, 80, 28)];
    confLb.text = @"置信度";
    confLb.textColor = [UIColor lightGrayColor];
    confLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:confLb];
    UITextField *confTf = [[UITextField alloc] initWithFrame:CGRectMake(100, y+74, 80, 28)];
    confTf.text = [NSString stringWithFormat:@"%.0f", task.threshold * 100];
    confTf.textColor = UIColor.whiteColor;
    confTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    confTf.layer.cornerRadius = 6;
    confTf.font = [UIFont systemFontOfSize:13];
    confTf.keyboardType = UIKeyboardTypeNumberPad;
    confTf.textAlignment = NSTextAlignmentCenter;
    confTf.tag = 10011;
    confTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    confTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:confTf];
    UILabel *confUnit = [[UILabel alloc] initWithFrame:CGRectMake(186, y+74, 50, 28)];
    confUnit.text = @"%";
    confUnit.textColor = [UIColor grayColor];
    confUnit.font = [UIFont systemFontOfSize:12];
    [card addSubview:confUnit];
    
    // 找到后动作
    UILabel *actionLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y+110, 80, 28)];
    actionLb.text = @"找到后";
    actionLb.textColor = [UIColor lightGrayColor];
    actionLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:actionLb];
    
    UISegmentedControl *actionSeg = [[UISegmentedControl alloc] initWithItems:@[@"不执行", @"点击匹配", @"点击中心"]];
    actionSeg.frame = CGRectMake(20, y+142, cw-40, 32);
    actionSeg.selectedSegmentIndex = task.actionAfterFound;
    actionSeg.tintColor = [UIColor systemBlueColor];
    actionSeg.tag = 10030;
    [card addSubview:actionSeg];
    
    // 取消/确定
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    cancelBtn.frame = CGRectMake(cw/2-100, y+188, 90, 34);
    cancelBtn.backgroundColor = [UIColor colorWithRed:0.75 green:0.15 blue:0.15 alpha:1];
    cancelBtn.layer.cornerRadius = 17;
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [cancelBtn addTarget:self action:@selector(onEditPanelCancel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancelBtn];
    
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.frame = CGRectMake(cw/2+10, y+188, 90, 34);
    saveBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:1];
    saveBtn.layer.cornerRadius = 17;
    [saveBtn setTitle:@"确定" forState:UIControlStateNormal];
    [saveBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    objc_setAssociatedObject(saveBtn, "card", card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "textField", @(10010), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "confField", @(10011), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "actionSeg", @(10030), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [saveBtn addTarget:self action:@selector(onOCREditSave:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:saveBtn];
    
    ((UIScrollView *)card).contentSize = CGSizeMake(cw, y+240);
}

// ==================== 编辑面板保存回调 ====================
- (void)onClickEditSave:(UIButton *)btn {
    UIView *card = objc_getAssociatedObject(btn, "card");
    ACTask *task = objc_getAssociatedObject(card, "task");
    [self saveEditPanel:card];
    UITextField *xTf = [card viewWithTag:10010];
    UITextField *yTf = [card viewWithTag:10011];
    UITextField *holdTf = [card viewWithTag:10012];
    task.x = [xTf.text doubleValue];
    task.y = [yTf.text doubleValue];
    task.holdMs = [holdTf.text doubleValue];
    [self saveTasks];
    [self refreshTaskList];
    [self dismissEditPanel];
    [self addLog:[NSString stringWithFormat:@"已保存点击任务: (%.0f,%.0f)", task.x, task.y]];
}

- (void)onDoubleClickEditSave:(UIButton *)btn {
    UIView *card = objc_getAssociatedObject(btn, "card");
    ACTask *task = objc_getAssociatedObject(card, "task");
    [self saveEditPanel:card];
    UITextField *xTf = [card viewWithTag:10010];
    UITextField *yTf = [card viewWithTag:10011];
    UITextField *intervalTf = [card viewWithTag:10012];
    task.x = [xTf.text doubleValue];
    task.y = [yTf.text doubleValue];
    task.doubleClickInterval = [intervalTf.text doubleValue];
    [self saveTasks];
    [self refreshTaskList];
    [self dismissEditPanel];
    [self addLog:[NSString stringWithFormat:@"已保存双击任务: (%.0f,%.0f)", task.x, task.y]];
}

- (void)onLongPressEditSave:(UIButton *)btn {
    UIView *card = objc_getAssociatedObject(btn, "card");
    ACTask *task = objc_getAssociatedObject(card, "task");
    [self saveEditPanel:card];
    UITextField *xTf = [card viewWithTag:10010];
    UITextField *yTf = [card viewWithTag:10011];
    UITextField *holdTf = [card viewWithTag:10012];
    task.x = [xTf.text doubleValue];
    task.y = [yTf.text doubleValue];
    task.holdMs = [holdTf.text doubleValue];
    [self saveTasks];
    [self refreshTaskList];
    [self dismissEditPanel];
    [self addLog:[NSString stringWithFormat:@"已保存长按任务: (%.0f,%.0f) %.0fms", task.x, task.y, task.holdMs]];
}

- (void)onSwipeEditSave:(UIButton *)btn {
    UIView *card = objc_getAssociatedObject(btn, "card");
    ACTask *task = objc_getAssociatedObject(card, "task");
    [self saveEditPanel:card];
    UITextField *x1Tf = [card viewWithTag:10010];
    UITextField *y1Tf = [card viewWithTag:10011];
    UITextField *x2Tf = [card viewWithTag:10020];
    UITextField *y2Tf = [card viewWithTag:10021];
    UITextField *durTf = [card viewWithTag:10012];
    task.x = [x1Tf.text doubleValue];
    task.y = [y1Tf.text doubleValue];
    task.x2 = [x2Tf.text doubleValue];
    task.y2 = [y2Tf.text doubleValue];
    task.duration = [durTf.text doubleValue];
    [self saveTasks];
    [self refreshTaskList];
    [self dismissEditPanel];
    [self addLog:[NSString stringWithFormat:@"已保存滑动任务: (%.0f,%.0f)->(%.0f,%.0f)", task.x, task.y, task.x2, task.y2]];
}

- (void)onWaitEditSave:(UIButton *)btn {
    UIView *card = objc_getAssociatedObject(btn, "card");
    ACTask *task = objc_getAssociatedObject(card, "task");
    [self saveEditPanel:card];
    UITextField *durTf = [card viewWithTag:10010];
    task.duration = [durTf.text doubleValue] / 1000.0; // 转换为秒
    [self saveTasks];
    [self refreshTaskList];
    [self dismissEditPanel];
    [self addLog:[NSString stringWithFormat:@"已保存等待任务: %.0fms", task.duration*1000]];
}

- (void)onFindImageEditSave:(UIButton *)btn {
    UIView *card = objc_getAssociatedObject(btn, "card");
    ACTask *task = objc_getAssociatedObject(card, "task");
    [self saveEditPanel:card];
    UITextField *threshTf = [card viewWithTag:10010];
    UISegmentedControl *actionSeg = [card viewWithTag:10030];
    task.threshold = [threshTf.text doubleValue] / 100.0;
    task.actionAfterFound = actionSeg.selectedSegmentIndex;
    [self saveTasks];
    [self refreshTaskList];
    [self dismissEditPanel];
    [self addLog:[NSString stringWithFormat:@"已保存识图任务 (阈值: %.0f%%)", task.threshold*100]];
}

- (void)onOCREditSave:(UIButton *)btn {
    UIView *card = objc_getAssociatedObject(btn, "card");
    ACTask *task = objc_getAssociatedObject(card, "task");
    [self saveEditPanel:card];
    UITextField *textTf = [card viewWithTag:10010];
    UITextField *confTf = [card viewWithTag:10011];
    UISegmentedControl *actionSeg = [card viewWithTag:10030];
    task.targetText = textTf.text ?: @"";
    task.threshold = [confTf.text doubleValue] / 100.0;
    task.actionAfterFound = actionSeg.selectedSegmentIndex;
    [self saveTasks];
    [self refreshTaskList];
    [self dismissEditPanel];
    [self addLog:[NSString stringWithFormat:@"已保存识字任务: \"%@\"", task.targetText]];
}

// ==================== 编辑面板取消 ====================
- (void)onEditPanelCancel {
    [self dismissEditPanel];
    [self refreshTaskList];
}

// ==================== 识图模板选择 ====================
- (void)onFindImageSelectTemplate:(UIButton *)sender {
    ACTask *task = objc_getAssociatedObject(sender, "task");
    [self showImageSourceMenu:task];
}

- (void)onFindImageScreenshotSelect:(UIButton *)sender {
    ACTask *task = objc_getAssociatedObject(sender, "task");
    [self dismissEditPanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self showRegionSelector:task];
    });
}

- (void)onFindImageAlbumSelect:(UIButton *)sender {
    ACTask *task = objc_getAssociatedObject(sender, "task");
    [self dismissEditPanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self pickImageFromLibrary:task];
    });
}

// ==================== 编辑面板拾取坐标 ====================
- (void)onPickCoordForEditPanel:(UIButton *)sender {
    ACTask *task = objc_getAssociatedObject(sender, "task");
    NSNumber *xTag = objc_getAssociatedObject(sender, "xField");
    NSNumber *yTag = objc_getAssociatedObject(sender, "yField");
    [self dismissEditPanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self showCoordPickerForFieldTask:task xFieldTag:[xTag integerValue] yFieldTag:[yTag integerValue]];
    });
}

- (void)onPickCoordForSwipeEditPanel:(UIButton *)sender {
    ACTask *task = objc_getAssociatedObject(sender, "task");
    NSNumber *xTag = objc_getAssociatedObject(sender, "xField");
    NSNumber *yTag = objc_getAssociatedObject(sender, "yField");
    NSString *phase = objc_getAssociatedObject(sender, "phase");
    [self dismissEditPanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self showCoordPickerForFieldTask:task xFieldTag:[xTag integerValue] yFieldTag:[yTag integerValue]];
    });
}

- (void)showCoordPickerForFieldTask:(ACTask *)task xFieldTag:(NSInteger)xTag yFieldTag:(NSInteger)yTag {
    [self dismissPanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGRect sb = UIScreen.mainScreen.bounds;
        g_pickerWin = [[ACPassThroughWindow alloc] initWithFrame:sb];
        g_pickerWin.windowLevel = UIWindowLevelAlert - 1;
        g_pickerWin.backgroundColor = UIColor.clearColor;
        g_pickerWin.hidden = NO;
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = UIColor.clearColor;
        g_pickerWin.rootViewController = vc;
        
        UIView *overlay = [[UIView alloc] initWithFrame:sb];
        overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        [vc.view addSubview:overlay];
        
        // 十字光标
        UIView *hLine = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-40, sb.size.height/2-0.5, 80, 1)];
        hLine.backgroundColor = [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.9]; hLine.tag = 901;
        [overlay addSubview:hLine];
        UIView *vLine = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-0.5, sb.size.height/2-40, 1, 80)];
        vLine.backgroundColor = [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.9]; vLine.tag = 902;
        [overlay addSubview:vLine];
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-8, sb.size.height/2-8, 16, 16)];
        dot.layer.cornerRadius = 8; dot.layer.borderColor = [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.9].CGColor;
        dot.layer.borderWidth = 2; dot.tag = 903;
        [overlay addSubview:dot];
        
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, sb.size.width-40, 36)];
        hint.text = @"点击选择位置";
        hint.textColor = UIColor.whiteColor; hint.textAlignment = NSTextAlignmentCenter;
        hint.font = [UIFont boldSystemFontOfSize:16]; hint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        hint.layer.cornerRadius = 10; hint.clipsToBounds = YES; hint.tag = 904;
        [overlay addSubview:hint];
        
        UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
        cancel.frame = CGRectMake(sb.size.width/2-50, sb.size.height-100, 100, 36);
        cancel.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1];
        cancel.layer.cornerRadius = 18;
        [cancel setTitle:@"取消" forState:UIControlStateNormal];
        [cancel setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        cancel.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [cancel addTarget:self action:@selector(onPickerForEditCancel) forControlEvents:UIControlEventTouchUpInside];
        [overlay addSubview:cancel];
        
        objc_setAssociatedObject(overlay, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(overlay, "xTag", @(xTag), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(overlay, "yTag", @(yTag), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pickerForEditPan:)];
        [overlay addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(pickerForEditTap:)];
        [overlay addGestureRecognizer:tap];
    });
}

- (void)pickerForEditPan:(UIPanGestureRecognizer *)g {
    CGPoint pt = [g locationInView:g.view];
    UIView *bg = g.view;
    [bg viewWithTag:901].frame = CGRectMake(pt.x-40, pt.y-0.5, 80, 1);
    [bg viewWithTag:902].frame = CGRectMake(pt.x-0.5, pt.y-40, 1, 80);
    [bg viewWithTag:903].center = pt;
    UILabel *hint = [bg viewWithTag:904];
    hint.text = [NSString stringWithFormat:@"选中: (%.0f, %.0f)", pt.x, pt.y];
    if (g.state == UIGestureRecognizerStateEnded) [self pickerForEditConfirm:pt];
}

- (void)pickerForEditTap:(UITapGestureRecognizer *)g {
    [self pickerForEditConfirm:[g locationInView:g.view]];
}

- (void)pickerForEditConfirm:(CGPoint)pt {
    if (g_pickerPhase == 99) return;
    UIView *bg = g_pickerWin.rootViewController.view.subviews.firstObject;
    if (!bg) return;
    ACTask *task = objc_getAssociatedObject(bg, "task");
    NSInteger xTag = [objc_getAssociatedObject(bg, "xTag") integerValue];
    NSInteger yTag = [objc_getAssociatedObject(bg, "yTag") integerValue];
    
    g_pickerPhase = 99;
    [g_pickerWin setHidden:YES]; g_pickerWin = nil;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        g_pickerPhase = 0;
        [self showPanel];
        // 更新编辑面板中的字段
        [self showEditPanel:task];
        UIView *card = [g_panel viewWithTag:702];
        UITextField *xTf = [card viewWithTag:xTag];
        UITextField *yTf = [card viewWithTag:yTag];
        xTf.text = [NSString stringWithFormat:@"%.0f", pt.x];
        yTf.text = [NSString stringWithFormat:@"%.0f", pt.y];
    });
}

- (void)onPickerForEditCancel {
    UIView *bg = g_pickerWin.rootViewController.view.subviews.firstObject;
    ACTask *task = objc_getAssociatedObject(bg, "task");
    [g_pickerWin setHidden:YES]; g_pickerWin = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        g_pickerPhase = 0;
        [self showPanel];
        // 重新打开编辑面板
        if (task) [self showEditPanel:task];
    });
}

// ==================== 移动任务 ====================
- (void)moveTaskUp:(int)index {
    if (index <= 0 || index >= g_taskList.count) return;
    [g_taskList exchangeObjectAtIndex:index withObjectAtIndex:index-1];
    [self saveTasks];
    [self refreshTaskList];
    [self addLog:@"任务上移"];
}

- (void)moveTaskDown:(int)index {
    if (index < 0 || index >= g_taskList.count-1) return;
    [g_taskList exchangeObjectAtIndex:index withObjectAtIndex:index+1];
    [self saveTasks];
    [self refreshTaskList];
    [self addLog:@"任务下移"];
}

// ==================== 状态指示器 ====================
- (void)updateStatus:(int)status {
    UIView *dot = [g_panel viewWithTag:900];
    if (!dot) return;
    if (status == 0) {
        dot.backgroundColor = [UIColor grayColor]; // 停止
    } else if (status == 1) {
        dot.backgroundColor = [UIColor greenColor]; // 运行中
    } else if (status == 2) {
        dot.backgroundColor = [UIColor redColor]; // 错误
    }
}

// ==================== 面板拖拽 ====================
// 只允许在标题栏区域拖拽面板
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if ([g isKindOfClass:UIPanGestureRecognizer.class] && g.view == g_panel) {
        CGPoint pt = [g locationInView:g_panel];
        if (pt.y > 44) return NO; // 不在标题栏区域，不拖拽面板
    }
    return YES;
}

- (void)onPanelPan:(UIPanGestureRecognizer *)g {
    UIView *panel = g.view;
    CGPoint t = [g translationInView:panel.superview];
    panel.frame = CGRectOffset(panel.frame, t.x, t.y);
    [g setTranslation:CGPointZero inView:panel.superview];
}

// ==================== 面板双指缩放 ====================
- (void)onPanelPinch:(UIPinchGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged) {
        UIView *panel = g.view;
        CGFloat scale = g.scale;
        CGFloat newW = panel.frame.size.width * scale;
        CGFloat newH = panel.frame.size.height * scale;
        // 限制最小300x350，最大不超过屏幕
        CGRect sb = UIScreen.mainScreen.bounds;
        newW = MIN(MAX(300, newW), sb.size.width - 10);
        newH = MIN(MAX(350, newH), sb.size.height - 20);
        panel.frame = CGRectMake(panel.frame.origin.x, panel.frame.origin.y, newW, newH);
        [self resizePanelLayout:panel];
        g.scale = 1.0;
    }
}

- (void)resizePanelLayout:(UIView *)panel {
    // 面板固定尺寸，不缩放
    CGFloat pw = 300, ph = 420;
    // 标题栏
    UIView *head = [panel viewWithTag:1000];
    head.frame = CGRectMake(0, 0, pw, 44);
    // 标题 - 自适应宽度
    UILabel *title = head.subviews.firstObject;
    if ([title isKindOfClass:UILabel.class]) title.frame = CGRectMake(8, 0, 140, 44);
    // 设置按钮
    UIButton *settingsBtn = [head viewWithTag:951];
    settingsBtn.frame = CGRectMake(152, 6, 36, 32);
    // 录制按钮
    UIButton *recBtn = [head viewWithTag:950];
    recBtn.frame = CGRectMake(192, 6, 36, 32);
    // 状态指示器
    UIView *statusDot = [head viewWithTag:900];
    statusDot.frame = CGRectMake(pw-44, 16, 8, 8);
    // 关闭按钮
    UIButton *close = head.subviews.lastObject;
    close.frame = CGRectMake(pw-32, 0, 32, 44);
    // 左侧动作栏（全高，均匀分布）
    CGFloat leftW = 40;
    CGFloat actionBarH = ph - 44 - 44 - 46;
    CGFloat btnH = actionBarH / 10;
    UIView *actionBar = [panel viewWithTag:1100];
    actionBar.frame = CGRectMake(0, 44, leftW, actionBarH);
    // 调整动作按钮高度
    NSArray *actionBtns = actionBar.subviews;
    for (int i = 0; i < actionBtns.count; i++) {
        UIView *btn = actionBtns[i];
        btn.frame = CGRectMake(0, i*btnH, leftW, btnH);
        for (UILabel *sv in btn.subviews) {
            if ([sv isKindOfClass:UILabel.class]) {
                sv.frame = CGRectMake(0, 0, leftW, btnH);
                sv.textAlignment = NSTextAlignmentCenter;
                sv.font = [UIFont boldSystemFontOfSize:15];
            }
        }
    }
    // 任务列表
    CGFloat listX = leftW, listW = pw - leftW;
    CGFloat listH = ph - 44 - 44 - 46;
    UIScrollView *scroll = [panel viewWithTag:500];
    scroll.frame = CGRectMake(listX, 44, listW, listH);
    // 底部操作栏（只剩清空和开始）
    UIView *bottomBar = [panel viewWithTag:1101];
    CGFloat bottomBarY = ph - 44 - 46;
    bottomBar.frame = CGRectMake(0, bottomBarY, pw, 44);
    // 日志区域
    UIView *logView = [panel viewWithTag:801];
    logView.frame = CGRectMake(0, ph-46, pw, 46);
    UIScrollView *logScroll = [logView viewWithTag:800];
    logScroll.frame = CGRectMake(0, 22, pw, 22);
    [self refreshTaskList];
}

- (void)refreshTaskList {
    UIScrollView *scroll = [g_panel viewWithTag:500];
    if (!scroll) return;
    for (UIView *v in scroll.subviews) [v removeFromSuperview];
    CGFloat lw = scroll.frame.size.width - 8, ly = 6;
    // 紧凑条目高度
    CGFloat itemH = 38;
    if (g_taskList.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(8, 20, lw, 40)];
        empty.text = @"点击左侧功能添加任务"; empty.textColor = [UIColor grayColor];
        empty.textAlignment = NSTextAlignmentCenter; empty.font = [UIFont systemFontOfSize:13];
        [scroll addSubview:empty]; scroll.contentSize = CGSizeMake(scroll.frame.size.width, 80);
        return;
    }
    NSDictionary *typeNames = @{@"click":@"点击", @"doubleClick":@"双击", @"longPress":@"长按", @"swipe":@"滑动", @"wait":@"等待", @"findImage":@"识图", @"ocr":@"识字"};
    for (int i = 0; i < g_taskList.count; i++) {
        ACTask *task = g_taskList[i];
        CGFloat thisItemH = itemH;
        // 整行容器
        UIView *item = [[UIView alloc] initWithFrame:CGRectMake(0, ly, lw, thisItemH)];
        item.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
        item.layer.cornerRadius = 6; item.userInteractionEnabled = YES; item.tag = i;
        
        // 序号
        UILabel *idxLb = [[UILabel alloc] initWithFrame:CGRectMake(4, (thisItemH-16)/2, 20, 16)];
        idxLb.text = [NSString stringWithFormat:@"%d", i+1];
        idxLb.textColor = [UIColor colorWithRed:0.3 green:0.7 blue:1 alpha:1];
        idxLb.font = [UIFont boldSystemFontOfSize:11];
        [item addSubview:idxLb];
        
        NSString *typeName = typeNames[task.type] ?: task.type;
        NSString *descText = task.desc.length > 0 ? task.desc : typeName;
        NSString *repeatStr = task.repeatCount == 0 ? @"无限" : [NSString stringWithFormat:@"%ld次", (long)task.repeatCount];
        NSString *detail = @"";
        if ([task.type isEqual:@"click"] || [task.type isEqual:@"doubleClick"] || [task.type isEqual:@"longPress"]) {
            detail = [NSString stringWithFormat:@"(%.0f,%.0f)", task.x, task.y];
        } else if ([task.type isEqual:@"swipe"]) {
            detail = [NSString stringWithFormat:@"(%.0f,%.0f)→(%.0f,%.0f)", task.x, task.y, task.x2, task.y2];
        } else if ([task.type isEqual:@"wait"]) {
            detail = [NSString stringWithFormat:@"%.1fs", task.duration];
        } else if ([task.type isEqual:@"ocr"]) {
            detail = [NSString stringWithFormat:@"\"%@\"", task.targetText ?: @"任意文字"];
        } else if ([task.type isEqual:@"findImage"]) {
            detail = [NSString stringWithFormat:@"%.0f%%", task.threshold*100];
        }
        
        // 信息行：类型:备注 | 执行:次数 后等待:xxms 详情
        UILabel *infoLb = [[UILabel alloc] initWithFrame:CGRectMake(26, 0, lw-66, thisItemH)];
        infoLb.text = [NSString stringWithFormat:@"%@: %@", typeName, descText];
        infoLb.textColor = UIColor.whiteColor;
        infoLb.font = [UIFont boldSystemFontOfSize:12];
        infoLb.adjustsFontSizeToFitWidth = YES; infoLb.minimumScaleFactor = 0.6;
        [item addSubview:infoLb];
        // 第二行小字
        UILabel *subLb = [[UILabel alloc] initWithFrame:CGRectMake(26, 0, lw-66, thisItemH)];
        subLb.text = [NSString stringWithFormat:@"执行:%@ 后等待:%.0fms %@", repeatStr, task.postWait, detail];
        subLb.textColor = [UIColor lightGrayColor];
        subLb.font = [UIFont systemFontOfSize:10];
        subLb.adjustsFontSizeToFitWidth = YES; subLb.minimumScaleFactor = 0.6;
        [item addSubview:subLb];
        infoLb.frame = CGRectMake(26, 2, lw-66, 18);
        subLb.frame = CGRectMake(26, thisItemH-16, lw-66, 14);
        
        // ⋮ 更多按钮
        UIButton *moreBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        moreBtn.frame = CGRectMake(lw-36, 0, 36, thisItemH);
        [moreBtn setTitle:@"⋮" forState:UIControlStateNormal];
        [moreBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
        moreBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        moreBtn.tag = i;
        [moreBtn addTarget:self action:@selector(onTaskMore:) forControlEvents:UIControlEventTouchUpInside];
        [item addSubview:moreBtn];
        
        // 长按排序
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onItemLongPress:)];
        [item addGestureRecognizer:longPress];
        
        [scroll addSubview:item];
        ly += thisItemH + 4;
    }
    scroll.contentSize = CGSizeMake(scroll.frame.size.width, ly + 4);
}

// 任务条目⋮更多按钮：原地弹出菜单（编辑/复制/删除）
- (void)onTaskMore:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (g_isRunning) {
        [self addLog:@"运行中不可编辑"];
        return;
    }
    if (idx < 0 || idx >= g_taskList.count) return;
    
    // 移除已有菜单
    UIView *oldMenu = [g_panel viewWithTag:777];
    [oldMenu removeFromSuperview];
    
    // 获取按钮在面板中的位置
    CGRect btnFrame = [sender convertRect:sender.bounds toView:g_panel];
    CGFloat menuX = CGRectGetMaxX(btnFrame) + 4;
    CGFloat menuY = btnFrame.origin.y;
    CGFloat menuW = 110;
    // 检查右边界，超出则向左弹出
    if (menuX + menuW > g_panel.frame.size.width) {
        menuX = btnFrame.origin.x - menuW - 4;
    }
    // 检查下边界
    if (menuY + 154 > g_panel.frame.size.height) {
        menuY = g_panel.frame.size.height - 159;
    }
    
    // 菜单容器
    UIView *menu = [[UIView alloc] initWithFrame:CGRectMake(menuX, menuY, menuW, 150)];
    menu.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.98];
    menu.layer.cornerRadius = 10;
    menu.layer.shadowColor = UIColor.blackColor.CGColor;
    menu.layer.shadowOpacity = 0.4;
    menu.layer.shadowRadius = 8;
    menu.layer.shadowOffset = CGSizeMake(0, 2);
    menu.tag = 777;
    [g_panel addSubview:menu];
    
    // 透明遮罩层，点击菜单外区域关闭菜单，不拦截菜单按钮点击
    UIView *overlay = [[UIView alloc] initWithFrame:CGRectMake(0, 0, g_panel.frame.size.width, g_panel.frame.size.height)];
    overlay.tag = 778;
    overlay.backgroundColor = [UIColor clearColor];
    [g_panel addSubview:overlay];
    [g_panel bringSubviewToFront:menu];
    [overlay addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissTaskMenu)]];
    
    // 编辑
    UIButton *editBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    editBtn.frame = CGRectMake(0, 0, menuW, 30);
    [editBtn setTitle:@"📝 编辑" forState:UIControlStateNormal];
    [editBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    editBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    editBtn.tag = idx;
    [editBtn addTarget:self action:@selector(onEditTask:) forControlEvents:UIControlEventTouchUpInside];
    [menu addSubview:editBtn];
    
    // 复制
    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    copyBtn.frame = CGRectMake(0, 30, menuW, 30);
    [copyBtn setTitle:@"📋 复制" forState:UIControlStateNormal];
    [copyBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    copyBtn.tag = idx;
    [copyBtn addTarget:self action:@selector(onCopyTask:) forControlEvents:UIControlEventTouchUpInside];
    [menu addSubview:copyBtn];
    
    // 运行
    UIButton *runBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    runBtn.frame = CGRectMake(0, 60, menuW, 30);
    [runBtn setTitle:@"▶ 运行" forState:UIControlStateNormal];
    [runBtn setTitleColor:[UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:1] forState:UIControlStateNormal];
    runBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    runBtn.tag = idx;
    [runBtn addTarget:self action:@selector(onRunTask:) forControlEvents:UIControlEventTouchUpInside];
    [menu addSubview:runBtn];
    
    UIView *sep1 = [[UIView alloc] initWithFrame:CGRectMake(8, 30, menuW-16, 0.5)];
    sep1.backgroundColor = [UIColor colorWithWhite:0.4 alpha:1];
    [menu addSubview:sep1];
    UIView *sep2 = [[UIView alloc] initWithFrame:CGRectMake(8, 60, menuW-16, 0.5)];
    sep2.backgroundColor = [UIColor colorWithWhite:0.4 alpha:1];
    [menu addSubview:sep2];
    UIView *sep3 = [[UIView alloc] initWithFrame:CGRectMake(8, 90, menuW-16, 0.5)];
    sep3.backgroundColor = [UIColor colorWithWhite:0.4 alpha:1];
    [menu addSubview:sep3];
    
    // 删除
    UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    delBtn.frame = CGRectMake(0, 90, menuW, 30);
    [delBtn setTitle:@"🗑 删除" forState:UIControlStateNormal];
    [delBtn setTitleColor:[UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1] forState:UIControlStateNormal];
    delBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    delBtn.tag = idx;
    [delBtn addTarget:self action:@selector(onDeleteTask:) forControlEvents:UIControlEventTouchUpInside];
    [menu addSubview:delBtn];
}

- (void)dismissTaskMenu {
    [[g_panel viewWithTag:777] removeFromSuperview];
    [[g_panel viewWithTag:778] removeFromSuperview];
}

// 复制任务
- (void)onCopyTask:(UIButton *)sender {
    NSInteger idx = sender.tag;
    [self dismissTaskMenu];
    if (idx < 0 || idx >= g_taskList.count) return;
    ACTask *orig = g_taskList[idx];
    ACTask *copy = [[ACTask alloc] init];
    copy.type = orig.type;
    copy.x = orig.x; copy.y = orig.y;
    copy.x2 = orig.x2; copy.y2 = orig.y2;
    copy.duration = orig.duration;
    copy.postWait = orig.postWait;
    copy.repeatCount = orig.repeatCount;
    copy.desc = orig.desc;
    copy.threshold = orig.threshold;
    copy.targetText = orig.targetText;
    copy.templateData = orig.templateData;
    [g_taskList addObject:copy];
    [self saveTasks];
    [self refreshTaskList];
    [self addLog:[NSString stringWithFormat:@"已复制任务 %ld", (long)idx+1]];
    [self dismissTaskMenu];
}

// 立即运行单个任务
- (void)onRunTask:(UIButton *)sender {
    NSInteger idx = sender.tag;
    [self dismissTaskMenu];
    if (idx < 0 || idx >= g_taskList.count) return;
    [self startTasksAt:idx];
}

// 任务条目长按：拖拽排序（优化流畅度）
- (void)onItemLongPress:(UILongPressGestureRecognizer *)g {
    UIScrollView *scroll = [g_panel viewWithTag:500];
    if (!scroll) return;
    static UIView *snapView;
    static int snapIndex;
    UIView *item = g.view;
    if (g.state == UIGestureRecognizerStateBegan) {
        snapIndex = (int)item.tag;
        snapView = [item snapshotViewAfterScreenUpdates:NO];
        snapView.frame = item.frame;
        snapView.alpha = 0.85;
        snapView.transform = CGAffineTransformMakeScale(1.05, 1.05);
        snapView.layer.shadowColor = UIColor.blackColor.CGColor;
        snapView.layer.shadowOpacity = 0.5;
        snapView.layer.shadowRadius = 8;
        [scroll addSubview:snapView];
        item.hidden = YES;
        [UIView animateWithDuration:0.15 animations:^{ snapView.alpha = 1; }];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (!snapView) return;
        CGPoint pt = [g locationInView:scroll];
        snapView.center = CGPointMake(snapView.frame.size.width/2, pt.y);
        // 计算新位置，只交换数组，不刷新视图
        CGFloat itemH = item.frame.size.height + 4;
        int newIndex = (int)(pt.y / itemH);
        newIndex = MAX(0, MIN((int)g_taskList.count-1, newIndex));
        if (newIndex != snapIndex) {
            [g_taskList exchangeObjectAtIndex:snapIndex withObjectAtIndex:newIndex];
            snapIndex = newIndex;
        }
    } else {
        if (!snapView) return;
        [UIView animateWithDuration:0.15 animations:^{
            snapView.alpha = 0;
        } completion:^(BOOL f) {
            [snapView removeFromSuperview];
            snapView = nil;
            item.hidden = NO;
            [self refreshTaskList];
            [self saveTasks];
        }];
    }
}

- (void)dismissPanel {
    g_panelVisible = NO;
    [UIView animateWithDuration:0.2 animations:^{ g_panel.alpha = 0; } completion:^(BOOL f) {
        [g_panel removeFromSuperview]; g_panel = nil;
    }];
}

// ==================== 动作菜单 ====================
- (void)showActionMenu {
    [[g_panel viewWithTag:700] removeFromSuperview];
    [[g_panel viewWithTag:701] removeFromSuperview];
    [[g_panel viewWithTag:702] removeFromSuperview];
    [[g_panel viewWithTag:703] removeFromSuperview];
    // 点击面板空白区域关闭菜单
    UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissActionMenu)];
    bgTap.cancelsTouchesInView = NO;
    [g_panel addGestureRecognizer:bgTap];

    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat mw = 200, mh = 260;
    CGFloat mx = (sb.size.width-mw)/2, my = (sb.size.height-mh)/2;
    UIView *menu = [[UIView alloc] initWithFrame:CGRectMake(mx, my, mw, mh)];
    menu.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    menu.layer.cornerRadius = 14; menu.clipsToBounds = YES;
    menu.tag = 700;
    [g_panel addSubview:menu];

    // 返回按钮
    UIButton *backBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    backBtn.frame = CGRectMake(0, 0, 44, 36);
    [backBtn setTitle:@"✕" forState:UIControlStateNormal];
    [backBtn setTitleColor:[UIColor grayColor] forState:UIControlStateNormal];
    backBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [backBtn addTarget:self action:@selector(dismissActionMenu) forControlEvents:UIControlEventTouchUpInside];
    [menu addSubview:backBtn];

    NSArray *items = @[@"点击", @"双击", @"长按", @"滑动", @"等待", @"识图", @"识字"];
    NSArray *types = @[@"click", @"doubleClick", @"longPress", @"swipe", @"wait", @"findImage", @"ocr"];
    for (int i = 0; i < items.count; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, i*36, mw, 36);
        [btn setTitle:items[i] forState:UIControlStateNormal];
        [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:14];
        btn.tag = i;
        [btn addTarget:self action:@selector(onActionSelected:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(btn, "type", types[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (i < items.count-1) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(20, 35, mw-40, 0.5)];
            line.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
            [btn addSubview:line];
        }
        [menu addSubview:btn];
    }
}

- (void)dismissActionMenu {
    [[g_panel viewWithTag:700] removeFromSuperview];
    [[g_panel viewWithTag:701] removeFromSuperview];
    [[g_panel viewWithTag:702] removeFromSuperview];
    [[g_panel viewWithTag:703] removeFromSuperview];
    // 移除手势
    NSMutableArray *toRemove = [NSMutableArray array];
    for (UIGestureRecognizer *g in g_panel.gestureRecognizers) {
        if ([g isKindOfClass:UITapGestureRecognizer.class]) [toRemove addObject:g];
    }
    for (UIGestureRecognizer *g in toRemove) [g_panel removeGestureRecognizer:g];
}

- (void)onActionSelected:(UIButton *)sender {
    NSString *type = objc_getAssociatedObject(sender, "type");
    [[g_panel viewWithTag:700] removeFromSuperview];
    ACTask *task = [[ACTask alloc] init];
    task.type = type;
    if ([type isEqual:@"click"] || [type isEqual:@"doubleClick"] || [type isEqual:@"longPress"] || [type isEqual:@"swipe"]) {
        [self showCoordPicker:task];
    } else if ([type isEqual:@"wait"]) {
        [self showWaitConfig:task];
    } else if ([type isEqual:@"ocr"]) {
        [self showOCRConfig:task];
    } else if ([type isEqual:@"findImage"]) {
        // 识图：先显示子菜单，选方式
        [self showImageSourceMenu:task];
    }
}

// ==================== 识图方式选择 ====================
- (void)showImageSourceMenu:(ACTask *)task {
    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat mw = 220, mh = 140;
    UIView *mask = [[UIView alloc] initWithFrame:sb];
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    mask.tag = 996;
    [g_panel.superview addSubview:mask];
    UIView *menu = [[UIView alloc] initWithFrame:CGRectMake((sb.size.width-mw)/2, (sb.size.height-mh)/2, mw, mh)];
    menu.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    menu.layer.cornerRadius = 14; menu.clipsToBounds = YES;
    [mask addSubview:menu];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 12, mw, 24)];
    title.text = @"选择识图方式"; title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter; title.font = [UIFont boldSystemFontOfSize:15];
    [menu addSubview:title];
    NSArray *items = @[@"截图选取", @"从相册选择"];
    for (int i = 0; i < 2; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(20, 48 + i*42, mw-40, 36);
        btn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        btn.layer.cornerRadius = 10;
        [btn setTitle:items[i] forState:UIControlStateNormal];
        [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:14];
        btn.tag = i;
        objc_setAssociatedObject(btn, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [btn addTarget:self action:@selector(onImageSourceSelected:) forControlEvents:UIControlEventTouchUpInside];
        [menu addSubview:btn];
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissImageSourceMenu)];
    tap.cancelsTouchesInView = NO;
    [mask addGestureRecognizer:tap];
}
- (void)dismissImageSourceMenu {
    [[g_panel.superview viewWithTag:996] removeFromSuperview];
}
- (void)onImageSourceSelected:(UIButton *)sender {
    ACTask *task = objc_getAssociatedObject(sender, "task");
    [self dismissImageSourceMenu];
    if (sender.tag == 0) {
        // 截图选取
        [self showRegionSelector:task];
    } else {
        // 从相册选择
        [self pickImageFromLibrary:task];
    }
}
- (void)pickImageFromLibrary:(ACTask *)task {
    [self dismissPanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 创建临时窗口呈现UIImagePickerController
        UIWindow *pickerWin = [[ACPassThroughWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        pickerWin.windowLevel = UIWindowLevelAlert;
        pickerWin.hidden = NO;
        pickerWin.backgroundColor = UIColor.clearColor;
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = UIColor.clearColor;
        pickerWin.rootViewController = vc;
        g_pickerWin = pickerWin;
        objc_setAssociatedObject(pickerWin, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // 用UIImagePickerController选取照片
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.delegate = (id)self;
        objc_setAssociatedObject(picker, "pickerWin", pickerWin, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [vc presentViewController:picker animated:YES completion:nil];
    });
}
// UIImagePickerController 回调
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    UIWindow *pw = objc_getAssociatedObject(picker, "pickerWin");
    ACTask *task = objc_getAssociatedObject(pw, "task");
    [picker dismissViewControllerAnimated:YES completion:^{
        [pw setHidden:YES];
        g_pickerWin = nil;
        if (img) {
            task.templateData = UIImagePNGRepresentation(img);
            task.threshold = 0.7;
            // 设置识图阈值
            [self showThresholdConfig:task];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; [self refreshTaskList]; });
        }
    }];
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    UIWindow *pw = objc_getAssociatedObject(picker, "pickerWin");
    [picker dismissViewControllerAnimated:YES completion:^{
        [pw setHidden:YES];
        g_pickerWin = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; [self refreshTaskList]; });
    }];
}

// ==================== 坐标拾取（参考老贝贝的准心拖动）====================
- (void)showCoordPicker:(ACTask *)task {
    [self dismissPanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGRect sb = UIScreen.mainScreen.bounds;
        g_pickerWin = [[ACPassThroughWindow alloc] initWithFrame:sb];
        g_pickerWin.windowLevel = UIWindowLevelAlert - 1;
        g_pickerWin.backgroundColor = UIColor.clearColor;
        g_pickerWin.hidden = NO;
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = UIColor.clearColor;
        g_pickerWin.rootViewController = vc;

        // 半透明遮罩层
        UIView *overlay = [[UIView alloc] initWithFrame:sb];
        overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        [vc.view addSubview:overlay];

        // 十字光标（从中心延伸40px）
        UIView *hLine = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-40, sb.size.height/2-0.5, 80, 1)];
        hLine.backgroundColor = [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.9]; hLine.tag = 901;
        [overlay addSubview:hLine];
        UIView *vLine = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-0.5, sb.size.height/2-40, 1, 80)];
        vLine.backgroundColor = [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.9]; vLine.tag = 902;
        [overlay addSubview:vLine];
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-8, sb.size.height/2-8, 16, 16)];
        dot.layer.cornerRadius = 8; dot.layer.borderColor = [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.9].CGColor;
        dot.layer.borderWidth = 2; dot.tag = 903;
        [overlay addSubview:dot];

        // 顶部提示
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, sb.size.width-40, 36)];
        hint.text = [task.type isEqual:@"swipe"] ? @"点击选择起点" : @"点击选择位置";
        hint.textColor = UIColor.whiteColor; hint.textAlignment = NSTextAlignmentCenter;
        hint.font = [UIFont boldSystemFontOfSize:16]; hint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        hint.layer.cornerRadius = 10; hint.clipsToBounds = YES; hint.tag = 904;
        [overlay addSubview:hint];

        // 取消按钮
        UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
        cancel.frame = CGRectMake(sb.size.width/2-50, sb.size.height-100, 100, 36);
        cancel.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1];
        cancel.layer.cornerRadius = 18;
        [cancel setTitle:@"取消" forState:UIControlStateNormal];
        [cancel setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        cancel.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [cancel addTarget:self action:@selector(onPickerCancel) forControlEvents:UIControlEventTouchUpInside];
        [overlay addSubview:cancel];

        objc_setAssociatedObject(overlay, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        g_pickerPhase = 0;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pickerPan:)];
        [overlay addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(pickerTap:)];
        [overlay addGestureRecognizer:tap];
    });
}

- (void)pickerPan:(UIPanGestureRecognizer *)g {
    CGPoint pt = [g locationInView:g.view];
    UIView *bg = g.view;
    [bg viewWithTag:901].frame = CGRectMake(pt.x-40, pt.y-0.5, 80, 1);
    [bg viewWithTag:902].frame = CGRectMake(pt.x-0.5, pt.y-40, 1, 80);
    [bg viewWithTag:903].center = pt;
    UILabel *hint = [bg viewWithTag:904];
    hint.text = [NSString stringWithFormat:@"选中: (%.0f, %.0f)", pt.x, pt.y];
    if (g.state == UIGestureRecognizerStateEnded) [self pickerConfirm:pt];
}

- (void)pickerTap:(UITapGestureRecognizer *)g {
    [self pickerConfirm:[g locationInView:g.view]];
}

- (void)pickerConfirm:(CGPoint)pt {
    if (g_pickerPhase == 99) return;
    UIView *bg = g_pickerWin.rootViewController.view.subviews.firstObject;
    if (!bg) return;
    ACTask *task = objc_getAssociatedObject(bg, "task");
    if ([task.type isEqual:@"swipe"]) {
        if (g_pickerPhase == 0) {
            task.x = pt.x; task.y = pt.y;
            g_pickerPhase = 1;
            UILabel *hint = [bg viewWithTag:904];
            hint.text = [NSString stringWithFormat:@"起点(%.0f,%.0f) 再点选终点", pt.x, pt.y];
            return;
        }
        task.x2 = pt.x; task.y2 = pt.y;
    } else {
        task.x = pt.x; task.y = pt.y;
    }
    g_pickerPhase = 99;
    [g_pickerWin setHidden:YES]; g_pickerWin = nil;
    [g_taskList addObject:task]; [self saveTasks];
    [self addLog:[NSString stringWithFormat:@"已添加: %@", task.type]];
    dispatch_async(dispatch_get_main_queue(), ^{
        g_pickerPhase = 0;
        [self showPanel]; [self refreshTaskList];
    });
}

- (void)onPickerCancel {
    [g_pickerWin setHidden:YES]; g_pickerWin = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; [self refreshTaskList]; });
}

// ==================== 等待配置 ====================
- (void)showWaitConfig:(ACTask *)task {
    [self dismissPanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGRect sb = UIScreen.mainScreen.bounds;
        g_configWin = [[ACPassThroughWindow alloc] initWithFrame:sb];
        g_configWin.windowLevel = UIWindowLevelAlert - 1;
        g_configWin.backgroundColor = UIColor.clearColor; g_configWin.hidden = NO;
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = UIColor.clearColor; g_configWin.rootViewController = vc;
        // 遮罩
        UIView *bg = [[UIView alloc] initWithFrame:sb];
        bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        [vc.view addSubview:bg];
        // 卡片
        CGFloat cw = 280, ch = 200;
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake((sb.size.width-cw)/2, (sb.size.height-ch)/2, cw, ch)];
        card.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
        card.layer.cornerRadius = 14; card.clipsToBounds = YES; [bg addSubview:card];
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 20, cw, 24)];
        title.text = @"等待时间"; title.textColor = UIColor.whiteColor;
        title.textAlignment = NSTextAlignmentCenter; title.font = [UIFont boldSystemFontOfSize:17];
        [card addSubview:title];
        UILabel *valLb = [[UILabel alloc] initWithFrame:CGRectMake(0, 55, cw, 30)];
        valLb.text = [NSString stringWithFormat:@"%.1f 秒", task.duration];
        valLb.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.3 alpha:1];
        valLb.textAlignment = NSTextAlignmentCenter; valLb.font = [UIFont boldSystemFontOfSize:22];
        valLb.tag = 9201; [card addSubview:valLb];
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(20, 95, cw-40, 30)];
        slider.minimumValue = 0.1; slider.maximumValue = 10.0; slider.value = task.duration;
        slider.minimumTrackTintColor = [UIColor systemBlueColor];
        slider.tag = 9202;
        [slider addTarget:self action:@selector(waitSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [card addSubview:slider];
        UIButton *okBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        okBtn.frame = CGRectMake(cw/2-60, 150, 120, 34);
        okBtn.backgroundColor = [UIColor systemBlueColor]; okBtn.layer.cornerRadius = 17;
        [okBtn setTitle:@"确定" forState:UIControlStateNormal];
        [okBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        okBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        objc_setAssociatedObject(okBtn, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(okBtn, "win", g_configWin, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(okBtn, "slider", slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [okBtn addTarget:self action:@selector(onWaitConfirm:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:okBtn];
    });
}
- (void)waitSliderChanged:(UISlider *)slider {
    UILabel *lb = [slider.superview viewWithTag:9201];
    lb.text = [NSString stringWithFormat:@"%.1f 秒", slider.value];
}
- (void)onWaitConfirm:(UIButton *)btn {
    ACTask *task = objc_getAssociatedObject(btn, "task");
    UISlider *slider = objc_getAssociatedObject(btn, "slider");
    UIWindow *w = objc_getAssociatedObject(btn, "win");
    task.duration = slider.value;
    [g_taskList addObject:task]; [self saveTasks];
    [self addLog:[NSString stringWithFormat:@"已添加等待 (%.1fs)", task.duration]];
    [w setHidden:YES]; w = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; [self refreshTaskList]; });
}

// ==================== 识图区域框选 ====================
- (void)showRegionSelector:(ACTask *)task {
    [self dismissPanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGRect sb = UIScreen.mainScreen.bounds;
        g_regionWin = [[ACPassThroughWindow alloc] initWithFrame:sb];
        g_regionWin.windowLevel = UIWindowLevelAlert - 1;
        g_regionWin.backgroundColor = UIColor.clearColor;
        g_regionWin.hidden = NO;
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = UIColor.clearColor;
        g_regionWin.rootViewController = vc;

        UIView *bg = [[UIView alloc] initWithFrame:sb];
        bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        bg.userInteractionEnabled = YES;
        [vc.view addSubview:bg];

        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, sb.size.width-40, 36)];
        hint.text = @"拖动选框移动，拖拽角/边调整大小"; hint.textColor = UIColor.whiteColor;
        hint.textAlignment = NSTextAlignmentCenter;
        hint.font = [UIFont boldSystemFontOfSize:15];
        hint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        hint.layer.cornerRadius = 10; hint.clipsToBounds = YES; hint.tag = 5001;
        [bg addSubview:hint];

        // 选择框
        UIView *box = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/4, sb.size.height/4, sb.size.width/2, sb.size.height/4)];
        box.layer.borderColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:0.9].CGColor;
        box.layer.borderWidth = 2.5;
        box.layer.cornerRadius = 4;
        box.backgroundColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:0.08];
        box.tag = 5002;
        bg.userInteractionEnabled = YES;
        [bg addSubview:box];

        // 尺寸标签
        UILabel *sizeLb = [[UILabel alloc] initWithFrame:CGRectMake(0, -20, 120, 18)];
        sizeLb.text = [NSString stringWithFormat:@"%.0fx%.0f", box.frame.size.width, box.frame.size.height];
        sizeLb.textColor = UIColor.whiteColor; sizeLb.font = [UIFont systemFontOfSize:11];
        sizeLb.textAlignment = NSTextAlignmentCenter;
        sizeLb.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        sizeLb.layer.cornerRadius = 4; sizeLb.clipsToBounds = YES;
        sizeLb.tag = 5003;
        [box addSubview:sizeLb];

        // 8个拖拽手柄（四角+四边中点）
        CGFloat handleSize = 24;
        NSArray *handles = @[
            @[@0, @0, @(NSTextAlignmentLeft),    @"topLeft"],
            @[@(box.frame.size.width/2-handleSize/2), @(-handleSize/2), @(NSTextAlignmentCenter), @"top"],
            @[@(box.frame.size.width-handleSize), @0, @(NSTextAlignmentRight), @"topRight"],
            @[@(box.frame.size.width-handleSize/2), @(box.frame.size.height/2-handleSize/2), @(NSTextAlignmentCenter), @"right"],
            @[@(box.frame.size.width-handleSize), @(box.frame.size.height-handleSize), @(NSTextAlignmentRight), @"bottomRight"],
            @[@(box.frame.size.width/2-handleSize/2), @(box.frame.size.height-handleSize/2), @(NSTextAlignmentCenter), @"bottom"],
            @[@0, @(box.frame.size.height-handleSize), @(NSTextAlignmentLeft), @"bottomLeft"],
            @[@(-handleSize/2), @(box.frame.size.height/2-handleSize/2), @(NSTextAlignmentCenter), @"left"],
        ];
        for (NSArray *h in handles) {
            CGFloat hx = [h[0] floatValue], hy = [h[1] floatValue];
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(hx, hy, handleSize, handleSize)];
            dot.backgroundColor = [UIColor whiteColor];
            dot.layer.cornerRadius = handleSize/2;
            dot.layer.borderColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1].CGColor;
            dot.layer.borderWidth = 2;
            dot.tag = [handles indexOfObject:h] + 5100;
            objc_setAssociatedObject(dot, "dir", h[3], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // 注意：此处先不关联box，因为box还没加到bg上
            UIPanGestureRecognizer *ph = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrag:)];
            [dot addGestureRecognizer:ph];
            [box addSubview:dot];
        }

        // 框拖动
        UIPanGestureRecognizer *boxPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(boxPan:)];
        [box addGestureRecognizer:boxPan];

        // 确认/取消按钮
        UIButton *confirmBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        confirmBtn.frame = CGRectMake(sb.size.width/2-110, sb.size.height-130, 100, 36);
        confirmBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:1];
        confirmBtn.layer.cornerRadius = 18;
        [confirmBtn setTitle:@"确认" forState:UIControlStateNormal];
        [confirmBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        confirmBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [confirmBtn addTarget:self action:@selector(onRegionConfirm) forControlEvents:UIControlEventTouchUpInside];
        [bg addSubview:confirmBtn];

        UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        cancelBtn.frame = CGRectMake(sb.size.width/2+10, sb.size.height-130, 100, 36);
        cancelBtn.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1];
        cancelBtn.layer.cornerRadius = 18;
        [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
        [cancelBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [cancelBtn addTarget:self action:@selector(onRegionCancel) forControlEvents:UIControlEventTouchUpInside];
        [bg addSubview:cancelBtn];

        objc_setAssociatedObject(bg, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

// 框拖动
- (void)boxPan:(UIPanGestureRecognizer *)g {
    UIView *box = g.view;
    UIView *bg = box.superview;
    CGPoint t = [g translationInView:bg];
    CGRect frame = box.frame;
    frame.origin.x += t.x; frame.origin.y += t.y;
    CGRect sb = UIScreen.mainScreen.bounds;
    frame.origin.x = MAX(10, MIN(sb.size.width - frame.size.width - 10, frame.origin.x));
    frame.origin.y = MAX(100, MIN(sb.size.height - frame.size.height - 160, frame.origin.y));
    box.frame = frame;
    [g setTranslation:CGPointZero inView:bg];
    [self updateRegionHandles:box];
    UILabel *sl = [box viewWithTag:5003];
    sl.text = [NSString stringWithFormat:@"%.0fx%.0f", frame.size.width, frame.size.height];
}

// 手柄拖拽
- (void)handleDrag:(UIPanGestureRecognizer *)g {
    UIView *dot = g.view;
    UIView *box = dot.superview;
    UIView *bg = box.superview;
    if (!bg) return;
    NSString *dir = objc_getAssociatedObject(dot, "dir");
    CGPoint t = [g translationInView:bg];
    CGRect f = box.frame;
    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat minSize = 30;
    if ([dir isEqual:@"left"]) {
        f.origin.x += t.x; f.size.width -= t.x;
        if (f.size.width < minSize) { f.size.width = minSize; f.origin.x = box.frame.origin.x + box.frame.size.width - minSize; }
    } else if ([dir isEqual:@"right"]) {
        f.size.width += t.x;
        if (f.size.width < minSize) f.size.width = minSize;
    } else if ([dir isEqual:@"top"]) {
        f.origin.y += t.y; f.size.height -= t.y;
        if (f.size.height < minSize) { f.size.height = minSize; f.origin.y = box.frame.origin.y + box.frame.size.height - minSize; }
    } else if ([dir isEqual:@"bottom"]) {
        f.size.height += t.y;
        if (f.size.height < minSize) f.size.height = minSize;
    } else if ([dir isEqual:@"topLeft"]) {
        f.origin.x += t.x; f.size.width -= t.x;
        f.origin.y += t.y; f.size.height -= t.y;
        if (f.size.width < minSize) { f.size.width = minSize; f.origin.x = box.frame.origin.x + box.frame.size.width - minSize; }
        if (f.size.height < minSize) { f.size.height = minSize; f.origin.y = box.frame.origin.y + box.frame.size.height - minSize; }
    } else if ([dir isEqual:@"topRight"]) {
        f.origin.y += t.y; f.size.height -= t.y;
        f.size.width += t.x;
        if (f.size.width < minSize) f.size.width = minSize;
        if (f.size.height < minSize) { f.size.height = minSize; f.origin.y = box.frame.origin.y + box.frame.size.height - minSize; }
    } else if ([dir isEqual:@"bottomLeft"]) {
        f.origin.x += t.x; f.size.width -= t.x;
        f.size.height += t.y;
        if (f.size.width < minSize) { f.size.width = minSize; f.origin.x = box.frame.origin.x + box.frame.size.width - minSize; }
        if (f.size.height < minSize) f.size.height = minSize;
    } else if ([dir isEqual:@"bottomRight"]) {
        f.size.width += t.x; f.size.height += t.y;
        if (f.size.width < minSize) f.size.width = minSize;
        if (f.size.height < minSize) f.size.height = minSize;
    }
    // 限制在屏幕内
    if (f.origin.x < 10) { f.origin.x = 10; }
    if (f.origin.y < 100) { f.origin.y = 100; }
    if (f.origin.x + f.size.width > sb.size.width - 10) { f.size.width = sb.size.width - 10 - f.origin.x; }
    if (f.origin.y + f.size.height > sb.size.height - 160) { f.size.height = sb.size.height - 160 - f.origin.y; }
    box.frame = f;
    [g setTranslation:CGPointZero inView:bg];
    [self updateRegionHandles:box];
    UILabel *sl = [box viewWithTag:5003];
    sl.text = [NSString stringWithFormat:@"%.0fx%.0f", f.size.width, f.size.height];
}

- (void)updateRegionHandles:(UIView *)box {
    CGFloat hs = 24;
    NSArray *pos = @[
        @[@0, @0],
        @[@(box.frame.size.width/2-hs/2), @(-hs/2)],
        @[@(box.frame.size.width-hs), @0],
        @[@(box.frame.size.width-hs/2), @(box.frame.size.height/2-hs/2)],
        @[@(box.frame.size.width-hs), @(box.frame.size.height-hs)],
        @[@(box.frame.size.width/2-hs/2), @(box.frame.size.height-hs/2)],
        @[@0, @(box.frame.size.height-hs)],
        @[@(-hs/2), @(box.frame.size.height/2-hs/2)],
    ];
    for (int i = 0; i < 8; i++) {
        UIView *dot = [box viewWithTag:i+5100];
        dot.frame = CGRectMake([pos[i][0] floatValue], [pos[i][1] floatValue], hs, hs);
    }
}

- (void)onRegionConfirm {
    if (!g_regionWin) return;
    UIView *bg = g_regionWin.rootViewController.view.subviews.firstObject;
    if (!bg) return;
    ACTask *task = objc_getAssociatedObject(bg, "task");
    if (!task) return;
    UIView *box = [bg viewWithTag:5002];
    if (!box) return;
    CGRect frame = box.frame;
    UIImage *fullSS = takeScreenshot();
    if (!fullSS) return;
    CGFloat scale = UIScreen.mainScreen.scale;
    CGRect cropRect = CGRectMake(frame.origin.x*scale, frame.origin.y*scale, frame.size.width*scale, frame.size.height*scale);
    CGImageRef cgCrop = CGImageCreateWithImageInRect(fullSS.CGImage, cropRect);
    if (!cgCrop) return;
    UIImage *template = [UIImage imageWithCGImage:cgCrop scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(cgCrop);
    task.templateData = UIImagePNGRepresentation(template);
    task.threshold = 0.7;
    [g_regionWin setHidden:YES]; g_regionWin = nil;
    [self showThresholdConfig:task];
}

- (void)onRegionCancel {
    [g_regionWin setHidden:YES]; g_regionWin = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; [self refreshTaskList]; });
}

// ==================== 阈值配置 ====================
- (void)showThresholdConfig:(ACTask *)task {
    CGRect sb = UIScreen.mainScreen.bounds;
    g_configWin = [[ACPassThroughWindow alloc] initWithFrame:sb];
    g_configWin.windowLevel = UIWindowLevelAlert - 1;
    g_configWin.backgroundColor = UIColor.clearColor; g_configWin.hidden = NO;
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = UIColor.clearColor; g_configWin.rootViewController = vc;
    UIView *bg = [[UIView alloc] initWithFrame:sb];
    bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    [vc.view addSubview:bg];
    CGFloat cw = 280, ch = 200;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((sb.size.width-cw)/2, (sb.size.height-ch)/2, cw, ch)];
    card.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    card.layer.cornerRadius = 14; card.clipsToBounds = YES; [bg addSubview:card];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 16, cw, 24)];
    title.text = @"设置识别率"; title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter; title.font = [UIFont boldSystemFontOfSize:17];
    [card addSubview:title];
    UILabel *valLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 50, cw, 30)];
    valLabel.text = [NSString stringWithFormat:@"%.0f%%", task.threshold * 100];
    valLabel.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.3 alpha:1];
    valLabel.textAlignment = NSTextAlignmentCenter; valLabel.font = [UIFont boldSystemFontOfSize:24];
    valLabel.tag = 5101; [card addSubview:valLabel];
    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(20, 90, cw-40, 30)];
    slider.minimumValue = 0.1; slider.maximumValue = 0.99; slider.value = task.threshold;
    slider.minimumTrackTintColor = [UIColor systemBlueColor]; slider.maximumTrackTintColor = [UIColor grayColor];
    slider.tag = 5102;
    [slider addTarget:self action:@selector(thresholdSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:slider];
    UILabel *desc = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, cw-40, 20)];
    desc.text = @"越高越精确，越低越容易匹配"; desc.textColor = [UIColor lightGrayColor];
    desc.textAlignment = NSTextAlignmentCenter; desc.font = [UIFont systemFontOfSize:11];
    [card addSubview:desc];
    UIButton *okBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    okBtn.frame = CGRectMake(cw/2-60, 155, 120, 32);
    okBtn.backgroundColor = [UIColor systemBlueColor]; okBtn.layer.cornerRadius = 16;
    [okBtn setTitle:@"确定" forState:UIControlStateNormal];
    [okBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    okBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    objc_setAssociatedObject(okBtn, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(okBtn, "win", g_configWin, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(okBtn, "slider", slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [okBtn addTarget:self action:@selector(onThresholdConfirm:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:okBtn];
}
- (void)thresholdSliderChanged:(UISlider *)slider {
    UIView *card = slider.superview;
    UILabel *vl = [card viewWithTag:5101];
    vl.text = [NSString stringWithFormat:@"%.0f%%", slider.value * 100];
}
- (void)onThresholdConfirm:(UIButton *)btn {
    ACTask *task = objc_getAssociatedObject(btn, "task");
    UISlider *slider = objc_getAssociatedObject(btn, "slider");
    UIWindow *w = objc_getAssociatedObject(btn, "win");
    task.threshold = slider.value;
    [g_taskList addObject:task]; [self saveTasks];
    [self addLog:[NSString stringWithFormat:@"已添加识图 (%.0f%%)", task.threshold*100]];
    [w setHidden:YES]; w = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; [self refreshTaskList]; });
}

// ==================== 识字配置 ====================
- (void)showOCRConfig:(ACTask *)task {
    [self dismissPanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGRect sb = UIScreen.mainScreen.bounds;
        g_configWin = [[ACPassThroughWindow alloc] initWithFrame:sb];
        g_configWin.windowLevel = UIWindowLevelAlert - 1;
        g_configWin.backgroundColor = UIColor.clearColor; g_configWin.hidden = NO;
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = UIColor.clearColor; g_configWin.rootViewController = vc;
        UIView *bg = [[UIView alloc] initWithFrame:sb];
        bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        [vc.view addSubview:bg];
        CGFloat cw = 280, ch = 260;
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake((sb.size.width-cw)/2, (sb.size.height-ch)/2, cw, ch)];
        card.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
        card.layer.cornerRadius = 14; card.clipsToBounds = YES; [bg addSubview:card];
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 16, cw, 24)];
        title.text = @"输入要识别的文字"; title.textColor = UIColor.whiteColor;
        title.textAlignment = NSTextAlignmentCenter; title.font = [UIFont boldSystemFontOfSize:17];
        [card addSubview:title];
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(20, 52, cw-40, 36)];
        tf.placeholder = @"例如: 确认"; tf.textColor = UIColor.whiteColor;
        tf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        tf.layer.cornerRadius = 8; tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,10,36)];
        tf.leftViewMode = UITextFieldViewModeAlways; tf.font = [UIFont systemFontOfSize:15];
        tf.tag = 5201; [card addSubview:tf];
        UILabel *hint2 = [[UILabel alloc] initWithFrame:CGRectMake(20, 92, cw-40, 18)];
        hint2.text = @"留空则点击任意识别的文字"; hint2.textColor = [UIColor lightGrayColor];
        hint2.textAlignment = NSTextAlignmentCenter; hint2.font = [UIFont systemFontOfSize:11];
        [card addSubview:hint2];
        UILabel *valLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 118, cw, 24)];
        valLabel.text = [NSString stringWithFormat:@"识别率: %.0f%%", task.threshold * 100];
        valLabel.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.3 alpha:1];
        valLabel.textAlignment = NSTextAlignmentCenter; valLabel.font = [UIFont boldSystemFontOfSize:15];
        valLabel.tag = 5202; [card addSubview:valLabel];
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(20, 145, cw-40, 24)];
        slider.minimumValue = 0.1; slider.maximumValue = 0.99; slider.value = task.threshold;
        slider.minimumTrackTintColor = [UIColor systemBlueColor]; slider.maximumTrackTintColor = [UIColor grayColor];
        slider.tag = 5203;
        [slider addTarget:self action:@selector(ocrSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [card addSubview:slider];
        UIButton *okBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        okBtn.frame = CGRectMake(20, 185, cw-40, 36);
        okBtn.backgroundColor = [UIColor systemBlueColor]; okBtn.layer.cornerRadius = 18;
        [okBtn setTitle:@"确定" forState:UIControlStateNormal];
        [okBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        okBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        objc_setAssociatedObject(okBtn, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(okBtn, "win", g_configWin, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(okBtn, "tf", tf, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(okBtn, "slider", slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [okBtn addTarget:self action:@selector(onOCRConfirm:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:okBtn];
        UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        cancelBtn.frame = CGRectMake(cw-80, 0, 80, 40);
        [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
        [cancelBtn setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
        cancelBtn.titleLabel.font = [UIFont systemFontOfSize:14];
        objc_setAssociatedObject(cancelBtn, "win", g_configWin, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cancelBtn addTarget:self action:@selector(onOCRConfigCancel:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:cancelBtn];
        [tf becomeFirstResponder];
    });
}
- (void)ocrSliderChanged:(UISlider *)slider {
    UILabel *vl = [slider.superview viewWithTag:5202];
    vl.text = [NSString stringWithFormat:@"识别率: %.0f%%", slider.value * 100];
}
- (void)onOCRConfirm:(UIButton *)btn {
    ACTask *task = objc_getAssociatedObject(btn, "task");
    UITextField *tf = objc_getAssociatedObject(btn, "tf");
    UISlider *slider = objc_getAssociatedObject(btn, "slider");
    UIWindow *w = objc_getAssociatedObject(btn, "win");
    task.targetText = tf.text ?: @""; task.threshold = slider.value;
    [g_taskList addObject:task]; [self saveTasks];
    [self addLog:[NSString stringWithFormat:@"已添加识字: \"%@\" (%.0f%%)", task.targetText, task.threshold*100]];
    [w setHidden:YES]; w = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; [self refreshTaskList]; });
}
- (void)onOCRConfigCancel:(UIButton *)btn {
    UIWindow *w = objc_getAssociatedObject(btn, "win");
    [w setHidden:YES]; w = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; });
}

// ==================== 录制功能 ====================
- (void)onRecordTap {
    if (g_isRecording) {
        [self stopRecording];
    } else {
        [self startRecording];
    }
}
- (void)startRecording {
    g_isRecording = YES;
    [g_recordedEvents removeAllObjects];
    // Hook sendEvent: to capture touches
    MSHookMessageEx(objc_getClass("UIApplication"), @selector(sendEvent:), (IMP)&hook_sendEvent, (IMP*)&orig_sendEvent);
    // 更新录制按钮状态
    UIButton *recBtn = [g_panel viewWithTag:950];
    [recBtn setTitle:@"⏹" forState:UIControlStateNormal];
    [recBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    recBtn.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1];
    [self addLog:@"开始录制..."];
}
- (void)stopRecording {
    g_isRecording = NO;
    // 恢复sendEvent
    MSHookMessageEx(objc_getClass("UIApplication"), @selector(sendEvent:), (IMP)orig_sendEvent, NULL);
    UIButton *recBtn = [g_panel viewWithTag:950];
    [recBtn setTitle:@"⏺" forState:UIControlStateNormal];
    [recBtn setTitleColor:[UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:1] forState:UIControlStateNormal];
    recBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    if (g_recordedEvents.count > 0) {
        [self addLog:[NSString stringWithFormat:@"录制完成: %lu个事件", (unsigned long)g_recordedEvents.count]];
        // 生成点击任务
        for (NSDictionary *evt in g_recordedEvents) {
            ACTask *t = [[ACTask alloc] init];
            t.type = @"click";
            t.x = [evt[@"x"] floatValue];
            t.y = [evt[@"y"] floatValue];
            t.holdMs = 30;
            [g_taskList addObject:t];
        }
        [self saveTasks];
        [self refreshTaskList];
        [self addLog:@"已转换为点击任务"];
    } else {
        [self addLog:@"录制无事件"];
    }
}

// ==================== 编辑/删除/清空 ====================
- (void)onEditTask:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx >= g_taskList.count) return;
    ACTask *task = g_taskList[idx];
    [self showEditPanel:task];
}

- (void)onDeleteTask:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx >= g_taskList.count) return;
    [g_taskList removeObjectAtIndex:idx];
    [self saveTasks];
    [self addLog:@"已删除任务"];
    [self refreshTaskList];
    [self dismissTaskMenu];
}

- (void)clearAllTasks {
    [g_taskList removeAllObjects];
    [self saveTasks];
    [self addLog:@"已清空所有任务"];
    [self refreshTaskList];
}

// ==================== 开始/停止 ====================
- (void)startTasksAt:(NSInteger)idx {
    if (g_isRunning) {
        [self addLog:@"运行中，请先停止"];
        return;
    }
    if (idx < 0 || idx >= g_taskList.count) return;
    resolveIOHID();
    g_isRunning = YES;
    [self dismissPanel];
    [self updateStatus:1];
    [self addLog:[NSString stringWithFormat:@"从第%ld个任务开始执行", (long)(idx+1)]];
    NSArray *sub = [g_taskList subarrayWithRange:NSMakeRange(idx, g_taskList.count - idx)];
    g_engine = [[ScriptEngine alloc] initWithTasks:sub];
    [g_engine run];
    [self setFloatIndicator:YES];
}

- (void)onStartTasks {
    if (g_taskList.count == 0) { [self addLog:@"没有任务，请先添加"]; return; }
    if (g_isRunning) {
        [g_engine stop];
        g_isRunning = NO;
        UIButton *btn = [g_panel viewWithTag:600];
        [btn setTitle:@"▶开始" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:1];
        [self addLog:@"已停止"];
        [self setFloatIndicator:NO];
        [self updateStatus:0];
        return;
    }
    resolveIOHID();
    g_isRunning = YES;
    [self dismissPanel];
    // 更新按钮状态
    UIButton *btn = [g_panel viewWithTag:600];
    [btn setTitle:@"⏹停止" forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1];
    [self updateStatus:1];
    [self addLog:@"开始执行任务序列"];
    // 创建引擎，包含重复次数和后等待逻辑
    g_engine = [[ScriptEngine alloc] initWithTasks:[g_taskList copy]];
    [g_engine run];
    [self setFloatIndicator:YES];
}

- (void)onScriptDone:(NSNotification *)n {
    g_isRunning = NO;
    [self addLog:@"全部任务完成"];
    [self setFloatIndicator:NO];
    [self updateStatus:0];
    // 更新面板按钮（如果面板打开）
    UIButton *btn = [g_panel viewWithTag:600];
    [btn setTitle:@"▶开始" forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:1];
    
    // 自动关闭app
    if (g_autoClose) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [NSThread sleepForTimeInterval:g_autoCloseDelay];
            dispatch_async(dispatch_get_main_queue(), ^{
                exit(0);
            });
        });
    }
}

- (void)setFloatIndicator:(BOOL)running {
    UIView *ind = [g_floatBall viewWithTag:999];
    ind.hidden = !running;
    ind.backgroundColor = running ? UIColor.redColor : UIColor.greenColor;
}

// ==================== 日志 ====================
- (void)addLog:(NSString *)msg {
    NSString *line = [NSString stringWithFormat:@"[AC] %@", msg];
    @synchronized(g_logs) {
        [g_logs addObject:line];
        if (g_logs.count > 50) [g_logs removeObjectAtIndex:0];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScrollView *logScroll = [g_panel viewWithTag:800];
        if (logScroll) {
            // 清除旧标签
            for (UIView *v in logScroll.subviews) [v removeFromSuperview];
            UILabel *logLb = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, logScroll.frame.size.width-16, 20)];
            logLb.text = msg;
            logLb.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.3 alpha:1];
            logLb.font = [UIFont fontWithName:@"Menlo" size:10];
            [logScroll addSubview:logLb];
            logScroll.contentSize = CGSizeMake(logScroll.frame.size.width, 20);
            // 自动滚动到底部
            [logScroll setContentOffset:CGPointMake(0, MAX(0, logScroll.contentSize.height - logScroll.frame.size.height)) animated:YES];
        }
        NSLog(@"%@", line);
    });
}
- (void)onLog:(NSNotification *)n { [self addLog:n.object]; }

// ==================== 持久化 ====================
static NSString *tasksArchivePath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [[paths.firstObject stringByAppendingPathComponent:@"autoclicker_tasks"] stringByAppendingPathExtension:@"archive"];
}
- (void)saveTasks {
    @synchronized(g_taskList) {
        // 更新当前profile
        if (g_currentProfileIndex < g_profiles.count) {
            NSMutableDictionary *prof = g_profiles[g_currentProfileIndex];
            prof[@"tasks"] = g_taskList;
        }
        [self saveProfiles];
    }
}
- (void)loadTasks {
    // load from current profile
    if (g_currentProfileIndex < g_profiles.count) {
        NSMutableDictionary *prof = g_profiles[g_currentProfileIndex];
        NSArray *tasks = prof[@"tasks"];
        if (tasks) {
            [g_taskList addObjectsFromArray:tasks];
        }
    }
}

// ==================== 多脚本持久化 ====================
static NSString *profilesArchivePath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [[paths.firstObject stringByAppendingPathComponent:@"autoclicker_profiles"] stringByAppendingPathExtension:@"archive"];
}
- (void)saveProfiles {
    @synchronized(g_profiles) {
        NSError *err = nil;
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:g_profiles requiringSecureCoding:NO error:&err];
        if (data) [data writeToFile:profilesArchivePath() atomically:YES];
    }
}
- (void)loadProfiles {
    NSString *path = profilesArchivePath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        NSError *err = nil;
        NSSet *classes = [NSSet setWithObjects:[NSMutableArray class], [NSMutableDictionary class], [NSString class], [NSArray class], [ACTask class], [NSData class], nil];
        NSArray *loaded = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:&err];
        if (loaded) {
            [g_profiles removeAllObjects];
            for (id item in loaded) {
                [g_profiles addObject:[item mutableCopy]];
            }
            if (g_currentProfileIndex < g_profiles.count) {
                NSMutableDictionary *prof = g_profiles[g_currentProfileIndex];
                g_taskList = prof[@"tasks"];
            }
        }
    }
}

// ==================== 脚本切换 ====================
- (void)updateProfileButton {
    UIButton *btn = [g_panel viewWithTag:980];
    if (g_currentProfileIndex < g_profiles.count) {
        NSDictionary *prof = g_profiles[g_currentProfileIndex];
        [btn setTitle:prof[@"name"] forState:UIControlStateNormal];
    } else {
        [btn setTitle:@"脚本" forState:UIControlStateNormal];
    }
}
- (void)onProfileTap {
    // 弹出菜单选择脚本
    CGRect sb = UIScreen.mainScreen.bounds;
    UIView *mask = [[UIView alloc] initWithFrame:sb];
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    mask.tag = 888;
    mask.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissProfileMenu)];
    [mask addGestureRecognizer:tap];
    [g_panel.superview addSubview:mask];
    
    CGFloat mw = 220, mh = MIN(300, sb.size.height - 200);
    CGFloat mx = (sb.size.width - mw)/2, my = (sb.size.height - mh)/2;
    UIView *menu = [[UIView alloc] initWithFrame:CGRectMake(mx, my, mw, mh)];
    menu.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    menu.layer.cornerRadius = 14; menu.clipsToBounds = YES;
    menu.tag = 889;
    [mask addSubview:menu];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, mw, 30)];
    title.text = @"选择脚本"; title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter; title.font = [UIFont boldSystemFontOfSize:16];
    [menu addSubview:title];
    
    UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    addBtn.frame = CGRectMake(10, 45, mw-20, 34);
    addBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:1];
    addBtn.layer.cornerRadius = 8;
    [addBtn setTitle:@"+ 新建脚本" forState:UIControlStateNormal];
    [addBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    addBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    [addBtn addTarget:self action:@selector(onNewProfile) forControlEvents:UIControlEventTouchUpInside];
    [menu addSubview:addBtn];
    
    CGFloat y = 86;
    for (int i = 0; i < g_profiles.count; i++) {
        NSDictionary *prof = g_profiles[i];
        UIButton *itemBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        itemBtn.frame = CGRectMake(10, y, mw-20, 36);
        itemBtn.backgroundColor = i == g_currentProfileIndex ? [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:0.3] : [UIColor colorWithWhite:0.2 alpha:1];
        itemBtn.layer.cornerRadius = 8;
        [itemBtn setTitle:prof[@"name"] forState:UIControlStateNormal];
        [itemBtn setTitleColor:i == g_currentProfileIndex ? UIColor.greenColor : UIColor.lightGrayColor forState:UIControlStateNormal];
        itemBtn.titleLabel.font = [UIFont systemFontOfSize:14];
        itemBtn.tag = i;
        [itemBtn addTarget:self action:@selector(onProfileSelected:) forControlEvents:UIControlEventTouchUpInside];
        [menu addSubview:itemBtn];
        y += 40;
    }
}
- (void)dismissProfileMenu {
    [[g_panel.superview viewWithTag:888] removeFromSuperview];
    [[g_panel.superview viewWithTag:889] removeFromSuperview];
}
- (void)onProfileSelected:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx >= g_profiles.count) return;
    // 保存当前profile
    if (g_currentProfileIndex < g_profiles.count) {
        NSMutableDictionary *old = g_profiles[g_currentProfileIndex];
        old[@"tasks"] = g_taskList;
    }
    // 加载选中
    g_currentProfileIndex = idx;
    NSMutableDictionary *newProf = g_profiles[idx];
    [g_taskList removeAllObjects];
    g_taskList = [newProf[@"tasks"] mutableCopy];
    [self refreshTaskList];
    [self updateProfileButton];
    [self addLog:[NSString stringWithFormat:@"已切换到: %@", newProf[@"name"]]];
    [self dismissProfileMenu];
}
- (void)onNewProfile {
    [self dismissProfileMenu];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建脚本" message:@"输入脚本名称" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"例如: 副本";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        if (!name.length) name = [NSString stringWithFormat:@"脚本%ld", (long)g_profiles.count+1];
        NSMutableDictionary *prof = [@{@"name":name, @"tasks":[NSMutableArray array]} mutableCopy];
        [g_profiles addObject:prof];
        [self saveProfiles];
        [self updateProfileButton];
        [self addLog:[NSString stringWithFormat:@"已新建: %@", name]];
    }]];
    UIViewController *vc = [[UIViewController alloc] init];
    UIWindow *win = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    win.windowLevel = UIWindowLevelAlert;
    win.rootViewController = vc;
    win.hidden = NO;
    [vc presentViewController:alert animated:YES completion:nil];
}

// ==================== 脚本管理面板 ====================
- (void)onScriptManage {
    [self dismissSettings];
    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat pw = 280, ph = 400;
    UIView *mask = [[UIView alloc] initWithFrame:sb];
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    mask.tag = 997;
    [g_panel.superview addSubview:mask];
    
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((sb.size.width-pw)/2, (sb.size.height-ph)/2, pw, ph)];
    card.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    card.layer.cornerRadius = 14;
    card.clipsToBounds = YES;
    [mask addSubview:card];
    
    // 标题栏
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 12, pw, 28)];
    title.text = @"📦 脚本管理";
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:17];
    [card addSubview:title];
    
    // 当前脚本指示
    UILabel *curLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 44, pw-32, 18)];
    NSString *curName = (g_currentProfileIndex < g_profiles.count) ? g_profiles[g_currentProfileIndex][@"name"] : @"默认";
    curLabel.text = [NSString stringWithFormat:@"当前: %@", curName];
    curLabel.textColor = [UIColor colorWithRed:0.3 green:0.7 blue:1 alpha:1];
    curLabel.font = [UIFont systemFontOfSize:12];
    [card addSubview:curLabel];
    
    // 脚本列表
    CGFloat listY = 66;
    CGFloat listH = ph - 66 - 50;
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, listY, pw, listH)];
    scroll.showsVerticalScrollIndicator = NO;
    [card addSubview:scroll];
    
    CGFloat sy = 0;
    CGFloat itemH = 44;
    CGFloat sw = pw - 32;
    
    // 默认脚本
    UIView *defaultRow = [self createScriptRow:scroll y:sy w:sw h:itemH name:@"默认" idx:-1];
    [scroll addSubview:defaultRow];
    sy += itemH + 4;
    
    for (int i = 0; i < g_profiles.count; i++) {
        NSDictionary *prof = g_profiles[i];
        NSString *name = prof[@"name"] ?: [NSString stringWithFormat:@"脚本%d", i];
        UIView *row = [self createScriptRow:scroll y:sy w:sw h:itemH name:name idx:i];
        [scroll addSubview:row];
        sy += itemH + 4;
    }
    
    // 新建脚本按钮
    UIButton *newBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    newBtn.frame = CGRectMake(16, sy, sw, 38);
    newBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:1];
    newBtn.layer.cornerRadius = 10;
    [newBtn setTitle:@"+ 新建脚本" forState:UIControlStateNormal];
    [newBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    newBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [newBtn addTarget:self action:@selector(onScriptMgrNew) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:newBtn];
    sy += 44;
    
    scroll.contentSize = CGSizeMake(sw, sy);
    
    // 关闭按钮 - 红色醒目
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(pw/2-60, ph-48, 120, 34);
    closeBtn.backgroundColor = [UIColor colorWithRed:0.75 green:0.15 blue:0.15 alpha:1];
    closeBtn.layer.cornerRadius = 17;
    [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    [closeBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [closeBtn addTarget:self action:@selector(dismissScriptMgr) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeBtn];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissScriptMgr)];
    tap.cancelsTouchesInView = NO;
    [mask addGestureRecognizer:tap];
}
- (UIView *)createScriptRow:(UIScrollView *)scroll y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h name:(NSString *)name idx:(NSInteger)idx {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(16, y, w, h)];
    row.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    row.layer.cornerRadius = 8;
    row.tag = idx + 2000;
    
    // 名称
    UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, w-120, h)];
    nameLabel.text = (idx < 0) ? @"默认脚本" : name;
    nameLabel.textColor = UIColor.whiteColor;
    nameLabel.font = [UIFont systemFontOfSize:14];
    nameLabel.adjustsFontSizeToFitWidth = YES;
    nameLabel.minimumScaleFactor = 0.7;
    [row addSubview:nameLabel];
    
    // 加载按钮
    UIButton *loadBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    loadBtn.frame = CGRectMake(w-112, 6, 50, h-12);
    loadBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:1];
    loadBtn.layer.cornerRadius = 6;
    [loadBtn setTitle:@"加载" forState:UIControlStateNormal];
    [loadBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    loadBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    loadBtn.tag = idx + 3000;
    [loadBtn addTarget:self action:@selector(onScriptMgrLoad:) forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:loadBtn];
    
    // 删除按钮
    UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    delBtn.frame = CGRectMake(w-56, 6, 40, h-12);
    delBtn.backgroundColor = [UIColor colorWithRed:0.6 green:0.15 blue:0.15 alpha:1];
    delBtn.layer.cornerRadius = 6;
    [delBtn setTitle:@"删" forState:UIControlStateNormal];
    [delBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    delBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    delBtn.tag = idx + 4000;
    [delBtn addTarget:self action:@selector(onScriptMgrDelete:) forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:delBtn];
    
    // 默认脚本和当前使用中的脚本不允许删除
    if (idx < 0 || idx == g_currentProfileIndex) {
        delBtn.hidden = YES;
    }
    
    return row;
}
- (void)onScriptMgrLoad:(UIButton *)sender {
    NSInteger idx = sender.tag - 3000;
    [self dismissScriptMgr];
    if (idx < 0) {
        // 加载默认
        [g_taskList removeAllObjects];
        g_currentProfileIndex = -1;
        [self setTitleText:@"默认"];
        [self saveTasks];
        [self refreshTaskList];
        [self addLog:@"已加载: 默认脚本"];
        return;
    }
    if (idx >= g_profiles.count) return;
    NSDictionary *prof = g_profiles[idx];
    g_currentProfileIndex = idx;
    g_taskList = [[prof[@"tasks"] mutableCopy] ?: [NSMutableArray array] mutableCopy];
    [self setTitleText:prof[@"name"]];
    [self saveTasks];
    [self refreshTaskList];
    [self addLog:[NSString stringWithFormat:@"已加载: %@", prof[@"name"]]];
}
- (void)onScriptMgrDelete:(UIButton *)sender {
    NSInteger idx = sender.tag - 4000;
    if (idx < 0 || idx >= g_profiles.count) return;
    if (idx == g_currentProfileIndex) return;
    NSString *name = g_profiles[idx][@"name"];
    [g_profiles removeObjectAtIndex:idx];
    if (g_currentProfileIndex > idx) g_currentProfileIndex--;
    [self saveProfiles];
    [self addLog:[NSString stringWithFormat:@"已删除: %@", name]];
    [self dismissScriptMgr];
    [self onScriptManage];
}
- (void)onScriptMgrNew {
    [self dismissScriptMgr];
    // 直接创建新脚本
    NSString *name = [NSString stringWithFormat:@"脚本%ld", (long)g_profiles.count+1];
    NSMutableDictionary *prof = [@{@"name":name, @"tasks":[NSMutableArray array]} mutableCopy];
    [g_profiles addObject:prof];
    [self saveProfiles];
    [self addLog:[NSString stringWithFormat:@"已新建: %@", name]];
    [self onScriptManage];
}
- (void)dismissScriptMgr {
    UIView *mask = [g_panel.superview viewWithTag:997];
    [mask removeFromSuperview];
}
- (void)setTitleText:(NSString *)text {
    UIView *head = [g_panel viewWithTag:1000];
    UILabel *title = head.subviews.firstObject;
    if ([title isKindOfClass:UILabel.class]) title.text = [NSString stringWithFormat:@"胖虎连点器 - %@", text];
}
- (void)onSaveCurrentScript {
    if (g_currentProfileIndex < g_profiles.count) {
        NSMutableDictionary *prof = g_profiles[g_currentProfileIndex];
        prof[@"tasks"] = [g_taskList mutableCopy];
        [self saveProfiles];
        [self addLog:[NSString stringWithFormat:@"已保存脚本: %@ (%lu个任务)", prof[@"name"], (unsigned long)g_taskList.count]];
    } else {
        [self addLog:@"保存失败: 无当前脚本"];
    }
}

// ==================== 导出/导入 ====================
- (void)onExportTasks {
    // 导出当前任务为JSON文件到Documents
    NSMutableArray *jsonArr = [NSMutableArray array];
    for (ACTask *t in g_taskList) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        if (t.type) d[@"type"] = t.type;
        if (t.desc) d[@"desc"] = t.desc;
        d[@"repeatCount"] = @(t.repeatCount);
        d[@"postWait"] = @(t.postWait);
        d[@"x"] = @(t.x); d[@"y"] = @(t.y);
        d[@"x2"] = @(t.x2); d[@"y2"] = @(t.y2);
        d[@"holdMs"] = @(t.holdMs);
        d[@"doubleClickInterval"] = @(t.doubleClickInterval);
        d[@"duration"] = @(t.duration);
        if (t.targetText) d[@"targetText"] = t.targetText;
        if (t.templateData) d[@"templateData"] = [t.templateData base64EncodedStringWithOptions:0];
        d[@"threshold"] = @(t.threshold);
        d[@"actionAfterFound"] = @(t.actionAfterFound);
        d[@"r"] = @(t.r); d[@"g"] = @(t.g); d[@"b"] = @(t.b);
        d[@"conditionType"] = @(t.conditionType);
        d[@"gotoIndex"] = @(t.gotoIndex);
        [jsonArr addObject:d];
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:jsonArr options:NSJSONWritingPrettyPrinted error:&err];
    if (!data) { [self addLog:@"导出失败: 序列化错误"]; return; }
    // 保存到文件
    NSString *name = @"胖虎脚本";
    if (g_currentProfileIndex < g_profiles.count) {
        name = g_profiles[g_currentProfileIndex][@"name"];
    }
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *fname = [NSString stringWithFormat:@"%@_%@.json", name, [fmt stringFromDate:[NSDate date]]];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *fpath = [paths.firstObject stringByAppendingPathComponent:fname];
    [data writeToFile:fpath atomically:YES];
    [self addLog:[NSString stringWithFormat:@"已导出: %@ (%lu bytes)", fname, (unsigned long)data.length]];
}
- (void)onImportTasks {
    // 从文件导入 - 显示Documents目录下的JSON文件列表供选择
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = paths.firstObject;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docDir error:nil];
    NSMutableArray *jsonFiles = [NSMutableArray array];
    for (NSString *f in files) {
        if ([f hasSuffix:@".json"]) [jsonFiles addObject:f];
    }
    if (jsonFiles.count == 0) {
        [self addLog:@"没有可导入的JSON文件"];
        return;
    }
    // 弹出选择列表
    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat mw = 240, mh = MIN(300, jsonFiles.count * 44 + 50);
    CGFloat mx = (sb.size.width-mw)/2, my = (sb.size.height-mh)/2;
    UIView *mask = [[UIView alloc] initWithFrame:sb];
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    mask.tag = 997;
    [g_panel.superview addSubview:mask];
    
    UIView *menu = [[UIView alloc] initWithFrame:CGRectMake(mx, my, mw, mh)];
    menu.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    menu.layer.cornerRadius = 14; menu.clipsToBounds = YES;
    [mask addSubview:menu];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, mw, 30)];
    title.text = @"选择导入文件"; title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter; title.font = [UIFont boldSystemFontOfSize:15];
    [menu addSubview:title];
    
    CGFloat y = 44;
    for (NSString *f in jsonFiles) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(10, y, mw-20, 36);
        btn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        btn.layer.cornerRadius = 8;
        [btn setTitle:f forState:UIControlStateNormal];
        [btn setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:12];
        objc_setAssociatedObject(btn, "fpath", [docDir stringByAppendingPathComponent:f], OBJC_ASSOCIATION_RETAIN);
        [btn addTarget:self action:@selector(doImportFile:) forControlEvents:UIControlEventTouchUpInside];
        [menu addSubview:btn];
        y += 40;
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissImportMenu)];
    [mask addGestureRecognizer:tap];
}
- (void)dismissImportMenu {
    [[g_panel.superview viewWithTag:997] removeFromSuperview];
}
- (void)doImportFile:(UIButton *)sender {
    NSString *fpath = objc_getAssociatedObject(sender, "fpath");
    [self dismissImportMenu];
    if (!fpath) return;
    NSData *data = [NSData dataWithContentsOfFile:fpath];
    if (!data) { [self addLog:@"文件读取失败"]; return; }
    NSError *err = nil;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!arr || ![arr isKindOfClass:NSArray.class]) { [self addLog:@"导入失败: JSON格式错误"]; return; }
    NSMutableArray *tasks = [NSMutableArray array];
    for (NSDictionary *dict in arr) {
        ACTask *t = [[ACTask alloc] init];
        t.type = dict[@"type"];
        t.desc = dict[@"desc"];
        if (dict[@"repeatCount"]) t.repeatCount = [dict[@"repeatCount"] integerValue];
        if (dict[@"postWait"]) t.postWait = [dict[@"postWait"] doubleValue];
        if (dict[@"x"]) t.x = [dict[@"x"] doubleValue];
        if (dict[@"y"]) t.y = [dict[@"y"] doubleValue];
        if (dict[@"x2"]) t.x2 = [dict[@"x2"] doubleValue];
        if (dict[@"y2"]) t.y2 = [dict[@"y2"] doubleValue];
        if (dict[@"holdMs"]) t.holdMs = [dict[@"holdMs"] doubleValue];
        if (dict[@"doubleClickInterval"]) t.doubleClickInterval = [dict[@"doubleClickInterval"] doubleValue];
        if (dict[@"duration"]) t.duration = [dict[@"duration"] doubleValue];
        if (dict[@"targetText"]) t.targetText = dict[@"targetText"];
        if (dict[@"templateData"]) t.templateData = [[NSData alloc] initWithBase64EncodedString:dict[@"templateData"] options:0];
        if (dict[@"threshold"]) t.threshold = [dict[@"threshold"] doubleValue];
        if (dict[@"r"]) t.r = [dict[@"r"] integerValue];
        if (dict[@"g"]) t.g = [dict[@"g"] integerValue];
        if (dict[@"b"]) t.b = [dict[@"b"] integerValue];
        if (dict[@"conditionType"]) t.conditionType = [dict[@"conditionType"] integerValue];
        if (dict[@"gotoIndex"]) t.gotoIndex = [dict[@"gotoIndex"] integerValue];
        [tasks addObject:t];
    }
    [g_taskList addObjectsFromArray:tasks];
    [self saveTasks];
    [self refreshTaskList];
    [self addLog:[NSString stringWithFormat:@"导入完成: %lu个任务", (unsigned long)tasks.count]];
}

// ==================== 设置面板 ====================
- (void)onSettingsTap {
    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat cw = 280, ch = 380;
    UIView *mask = [[UIView alloc] initWithFrame:sb];
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    mask.tag = 998;
    [g_panel.superview addSubview:mask];
    
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((sb.size.width-cw)/2, (sb.size.height-ch)/2, cw, ch)];
    card.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    card.layer.cornerRadius = 14;
    card.clipsToBounds = YES;
    [mask addSubview:card];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 12, cw, 28)];
    title.text = @"设置"; title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter; title.font = [UIFont boldSystemFontOfSize:17];
    [card addSubview:title];
    
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 44, cw, ch-100)];
    scroll.showsVerticalScrollIndicator = NO;
    [card addSubview:scroll];
    
    CGFloat y = 0;
    CGFloat lh = 34;
    CGFloat btnW = (cw - 48) / 2;
    CGFloat labelW = 95;
    
    // ====== 1. 定时启动 ======
    UILabel *sec1 = [[UILabel alloc] initWithFrame:CGRectMake(16, y, cw-32, 20)];
    sec1.text = @"⏰ 定时启动"; sec1.textColor = [UIColor colorWithRed:0.3 green:0.7 blue:1 alpha:1];
    sec1.font = [UIFont boldSystemFontOfSize:13];
    [scroll addSubview:sec1];
    y += 22;
    
    // 开关
    UISwitch *timerSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(16, y, 50, lh)];
    timerSwitch.on = g_timerEnabled;
    timerSwitch.tag = 830;
    timerSwitch.onTintColor = [UIColor systemGreenColor];
    [timerSwitch addTarget:self action:@selector(onTimerSwitch:) forControlEvents:UIControlEventValueChanged];
    [scroll addSubview:timerSwitch];
    
    UILabel *timerLabel = [[UILabel alloc] initWithFrame:CGRectMake(72, y, 60, lh)];
    timerLabel.text = @"启用";
    timerLabel.textColor = UIColor.lightGrayColor;
    timerLabel.font = [UIFont systemFontOfSize:12];
    [scroll addSubview:timerLabel];
    
    // 添加时间按钮
    UIButton *addTimeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    addTimeBtn.frame = CGRectMake(140, y, 60, lh);
    addTimeBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:1];
    addTimeBtn.layer.cornerRadius = 8;
    [addTimeBtn setTitle:@"+添加" forState:UIControlStateNormal];
    [addTimeBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    addTimeBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    [addTimeBtn addTarget:self action:@selector(onTimerPick) forControlEvents:UIControlEventTouchUpInside];
    [addTimeBtn setHidden:!g_timerEnabled];
    [scroll addSubview:addTimeBtn];
    y += lh + 2;
    
    // 已添加的时间列表
    if (g_timerEnabled && g_timerTimes.count > 0) {
        for (int i = 0; i < g_timerTimes.count; i++) {
            NSString *t = g_timerTimes[i];
            UIView *row = [[UIView alloc] initWithFrame:CGRectMake(16, y, cw-32, 28)];
            row.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
            row.layer.cornerRadius = 6;
            [scroll addSubview:row];
            
            UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 80, 28)];
            tl.text = t;
            tl.textColor = UIColor.whiteColor;
            tl.font = [UIFont boldSystemFontOfSize:14];
            [row addSubview:tl];
            
            UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeCustom];
            delBtn.frame = CGRectMake(cw-56, 0, 36, 28);
            [delBtn setTitle:@"✕" forState:UIControlStateNormal];
            [delBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            delBtn.backgroundColor = [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:1];
            delBtn.layer.cornerRadius = 6;
            delBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
            delBtn.tag = i;
            [delBtn addTarget:self action:@selector(deleteTimerTime:) forControlEvents:UIControlEventTouchUpInside];
            [row addSubview:delBtn];
            
            y += 32;
        }
    }
    y += 6;
    
    // ====== 2. 自动运行 ======
    UILabel *sec2 = [[UILabel alloc] initWithFrame:CGRectMake(16, y, cw-32, 20)];
    sec2.text = @"▶ 自动运行"; sec2.textColor = [UIColor colorWithRed:0.3 green:0.7 blue:1 alpha:1];
    sec2.font = [UIFont boldSystemFontOfSize:13];
    [scroll addSubview:sec2];
    y += 22;
    
    UISwitch *autoRunSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(16, y, 50, lh)];
    autoRunSwitch.on = g_autoRun;
    autoRunSwitch.tag = 810;
    autoRunSwitch.onTintColor = [UIColor systemGreenColor];
    [autoRunSwitch addTarget:self action:@selector(onAutoRunSwitch:) forControlEvents:UIControlEventValueChanged];
    [scroll addSubview:autoRunSwitch];
    
    UILabel *autoRunLabel = [[UILabel alloc] initWithFrame:CGRectMake(72, y, 60, lh)];
    autoRunLabel.text = @"延时(秒)";
    autoRunLabel.textColor = UIColor.lightGrayColor;
    autoRunLabel.font = [UIFont systemFontOfSize:12];
    [scroll addSubview:autoRunLabel];
    
    UITextField *autoRunTF = [[UITextField alloc] initWithFrame:CGRectMake(136, y+3, 60, 28)];
    autoRunTF.text = [NSString stringWithFormat:@"%.0f", g_autoRunDelay];
    autoRunTF.textColor = UIColor.whiteColor;
    autoRunTF.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    autoRunTF.layer.cornerRadius = 6;
    autoRunTF.keyboardType = UIKeyboardTypeDecimalPad;
    autoRunTF.textAlignment = NSTextAlignmentCenter;
    autoRunTF.font = [UIFont boldSystemFontOfSize:14];
    autoRunTF.tag = 812;
    autoRunTF.hidden = !g_autoRun;
    [scroll addSubview:autoRunTF];
    
    UILabel *label2 = [[UILabel alloc] initWithFrame:CGRectMake(204, y, 60, lh)];
    label2.text = @"秒";
    label2.textColor = UIColor.lightGrayColor;
    label2.font = [UIFont systemFontOfSize:12];
    [scroll addSubview:label2];
    
    y += lh + 6;
    
    // ====== 3. 结束后关闭 ======
    UILabel *sec3 = [[UILabel alloc] initWithFrame:CGRectMake(16, y, cw-32, 20)];
    sec3.text = @"⏹ 结束后关闭"; sec3.textColor = [UIColor colorWithRed:0.3 green:0.7 blue:1 alpha:1];
    sec3.font = [UIFont boldSystemFontOfSize:13];
    [scroll addSubview:sec3];
    y += 22;
    
    UISwitch *autoCloseSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(16, y, 50, lh)];
    autoCloseSwitch.on = g_autoClose;
    autoCloseSwitch.tag = 820;
    autoCloseSwitch.onTintColor = [UIColor systemGreenColor];
    [autoCloseSwitch addTarget:self action:@selector(onAutoCloseSwitch:) forControlEvents:UIControlEventValueChanged];
    [scroll addSubview:autoCloseSwitch];
    
    UILabel *autoCloseLabel = [[UILabel alloc] initWithFrame:CGRectMake(72, y, 60, lh)];
    autoCloseLabel.text = @"延时(秒)";
    autoCloseLabel.textColor = UIColor.lightGrayColor;
    autoCloseLabel.font = [UIFont systemFontOfSize:12];
    [scroll addSubview:autoCloseLabel];
    
    UITextField *closeDelayTF = [[UITextField alloc] initWithFrame:CGRectMake(136, y+3, 60, 28)];
    closeDelayTF.text = [NSString stringWithFormat:@"%.0f", g_autoCloseDelay];
    closeDelayTF.textColor = UIColor.whiteColor;
    closeDelayTF.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    closeDelayTF.layer.cornerRadius = 6;
    closeDelayTF.keyboardType = UIKeyboardTypeDecimalPad;
    closeDelayTF.textAlignment = NSTextAlignmentCenter;
    closeDelayTF.font = [UIFont boldSystemFontOfSize:14];
    closeDelayTF.tag = 822;
    closeDelayTF.hidden = !g_autoClose;
    [scroll addSubview:closeDelayTF];
    
    UILabel *label3 = [[UILabel alloc] initWithFrame:CGRectMake(204, y, 60, lh)];
    label3.text = @"秒";
    label3.textColor = UIColor.lightGrayColor;
    label3.font = [UIFont systemFontOfSize:12];
    [scroll addSubview:label3];
    
    y += lh + 6;
    
    // ====== 4. 脚本管理 ======
    UILabel *sec4 = [[UILabel alloc] initWithFrame:CGRectMake(16, y, cw-32, 20)];
    sec4.text = @"📦 脚本管理"; sec4.textColor = [UIColor colorWithRed:0.3 green:0.7 blue:1 alpha:1];
    sec4.font = [UIFont boldSystemFontOfSize:13];
    [scroll addSubview:sec4];
    y += 22;
    
    // 点击进入脚本管理面板
    UIButton *scriptMgrBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    scriptMgrBtn.frame = CGRectMake(16, y, cw-32, 44);
    scriptMgrBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    scriptMgrBtn.layer.cornerRadius = 10;
    [scriptMgrBtn setTitle:@"📋 管理脚本 (>保存的脚本)" forState:UIControlStateNormal];
    [scriptMgrBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    scriptMgrBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    scriptMgrBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    scriptMgrBtn.titleLabel.minimumScaleFactor = 0.7;
    [scriptMgrBtn addTarget:self action:@selector(onScriptManage) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:scriptMgrBtn];
    y += 50;
    
    // 导入导出快捷按钮
    UIButton *exportBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    exportBtn.frame = CGRectMake(16, y, btnW, 38);
    exportBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    exportBtn.layer.cornerRadius = 8;
    [exportBtn setTitle:@"⇧导出" forState:UIControlStateNormal];
    [exportBtn setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
    exportBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [exportBtn addTarget:self action:@selector(onExportTasks) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:exportBtn];
    
    UIButton *importBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    importBtn.frame = CGRectMake(16 + btnW + 8, y, btnW, 38);
    importBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    importBtn.layer.cornerRadius = 8;
    [importBtn setTitle:@"⇩导入" forState:UIControlStateNormal];
    [importBtn setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
    importBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [importBtn addTarget:self action:@selector(onImportTasks) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:importBtn];
    y += 46;
    
    scroll.contentSize = CGSizeMake(cw-32, y);
    
    // 关闭按钮 - 红色醒目
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(cw/2-60, ch-42, 120, 34);
    closeBtn.backgroundColor = [UIColor colorWithRed:0.75 green:0.15 blue:0.15 alpha:1];
    closeBtn.layer.cornerRadius = 17;
    [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    [closeBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [closeBtn addTarget:self action:@selector(dismissSettings) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeBtn];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissSettings)];
    tap.cancelsTouchesInView = NO;
    [mask addGestureRecognizer:tap];
}
- (void)dismissSettings {
    [[g_panel.superview viewWithTag:998] removeFromSuperview];
}
- (void)deleteTimerTime:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < g_timerTimes.count) {
        [g_timerTimes removeObjectAtIndex:idx];
        // 刷新设置面板
        [self dismissSettings];
        [self onSettingsTap];
    }
}
- (void)onTimerSwitch:(UISwitch *)s {
    g_timerEnabled = s.on;
    [self dismissSettings];
    [self onSettingsTap];
    if (g_timerEnabled && g_timerTimes.count > 0) {
        [self startTimerCheck];
    }
}
- (void)onTimerPick {
    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat pw = 260, ph = 280;
    UIView *mask = [[UIView alloc] initWithFrame:sb];
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    mask.tag = 999;
    [g_panel.superview addSubview:mask];
    
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((sb.size.width-pw)/2, (sb.size.height-ph)/2, pw, ph)];
    card.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.98];
    card.layer.cornerRadius = 16;
    card.clipsToBounds = YES;
    [mask addSubview:card];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 16, pw, 24)];
    title.text = @"添加定时启动时间";
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:16];
    [card addSubview:title];
    
    // 滚轮时间选择器 (类似苹果闹钟) - 居中放置
    UIDatePicker *picker = [[UIDatePicker alloc] initWithFrame:CGRectMake(20, 55, pw-40, 150)];
    picker.datePickerMode = UIDatePickerModeTime;
    picker.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    picker.minuteInterval = 1;
    if (@available(iOS 13.4, *)) {
        picker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    }
    picker.tag = 888;
    [card addSubview:picker];
    
    // 确定按钮
    UIButton *confirmBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    confirmBtn.frame = CGRectMake(pw/2-90, ph-60, 80, 36);
    confirmBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:1];
    confirmBtn.layer.cornerRadius = 18;
    [confirmBtn setTitle:@"确定" forState:UIControlStateNormal];
    [confirmBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    confirmBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [confirmBtn addTarget:self action:@selector(confirmTimerPick:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:confirmBtn];
    
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    cancelBtn.frame = CGRectMake(pw/2+10, ph-60, 80, 36);
    cancelBtn.backgroundColor = [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:1];
    cancelBtn.layer.cornerRadius = 18;
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [cancelBtn addTarget:self action:@selector(cancelTimerPick) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancelBtn];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cancelTimerPick)];
    tap.cancelsTouchesInView = NO;
    [mask addGestureRecognizer:tap];
}
- (void)confirmTimerPick:(UIButton *)sender {
    UIView *card = sender.superview;
    UIDatePicker *picker = [card viewWithTag:888];
    if (!picker) return;
    NSDate *date = picker.date;
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *comp = [cal components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:date];
    NSString *timeStr = [NSString stringWithFormat:@"%02ld:%02ld:00", (long)comp.hour, (long)comp.minute];
    [g_timerTimes addObject:timeStr];
    [self addLog:[NSString stringWithFormat:@"已添加定时: %@", timeStr]];
    if (g_timerEnabled) {
        [self startTimerCheck];
    }
    // 关闭弹出
    UIView *mask = [card superview];
    [mask removeFromSuperview];
}
- (void)cancelTimerPick {
    UIView *mask = [g_panel.superview viewWithTag:999];
    [mask removeFromSuperview];
}
- (void)startTimerCheck {
    if (!g_timerEnabled || g_timerTimes.count == 0) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (g_timerEnabled && g_timerTimes.count > 0) {
            NSDate *now = [NSDate date];
            NSCalendar *cal = [NSCalendar currentCalendar];
            NSDateComponents *nowComp = [cal components:NSCalendarUnitHour|NSCalendarUnitMinute|NSCalendarUnitSecond fromDate:now];
            NSInteger nowSecs = nowComp.hour * 3600 + nowComp.minute * 60 + nowComp.second;
            
            for (int i = 0; i < g_timerTimes.count; i++) {
                NSString *t = g_timerTimes[i];
                NSArray *parts = [t componentsSeparatedByString:@":"];
                if (parts.count >= 2) {
                    NSInteger th = [parts[0] integerValue];
                    NSInteger tm = [parts[1] integerValue];
                    NSInteger ts = (parts.count >= 3) ? [parts[2] integerValue] : 0;
                    NSInteger targetSecs = th * 3600 + tm * 60 + ts;
                    if (abs((int)(nowSecs - targetSecs)) <= 1) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self addLog:[NSString stringWithFormat:@"定时触发: %@", t]];
                            [self onStartTasks];
                        });
                        [g_timerTimes removeObjectAtIndex:i];
                        break;
                    }
                }
            }
            [NSThread sleepForTimeInterval:1.0];
        }
    });
}
- (void)onAutoRunSwitch:(UISwitch *)s {
    g_autoRun = s.on;
    UIScrollView *scroll = (UIScrollView *)[s superview];
    UITextField *tf = [scroll viewWithTag:812];
    tf.hidden = !s.on;
}
- (void)onAutoCloseSwitch:(UISwitch *)s {
    g_autoClose = s.on;
    UIScrollView *scroll = (UIScrollView *)[s superview];
    UITextField *tf = [scroll viewWithTag:822];
    tf.hidden = !s.on;
}

// ==================== 颜色拾取编辑面板 ====================
- (void)colorPickerPan:(UIPanGestureRecognizer *)g {
    CGPoint pt = [g locationInView:g.view];
    UIView *bg = g.view;
    [bg viewWithTag:901].frame = CGRectMake(pt.x-40, pt.y-0.5, 80, 1);
    [bg viewWithTag:902].frame = CGRectMake(pt.x-0.5, pt.y-40, 1, 80);
    [bg viewWithTag:903].center = pt;
    // 用缓存的截图取色，避免卡顿
    UIImage *ss = objc_getAssociatedObject(bg, "cachedScreenshot");
    if (ss) {
        CGImageRef cg = ss.CGImage;
        int w = (int)CGImageGetWidth(cg), h = (int)CGImageGetHeight(cg);
        int px = (int)(pt.x * UIScreen.mainScreen.scale);
        int py = (int)(pt.y * UIScreen.mainScreen.scale);
        int r = 0, g = 0, b = 0;
        if (px >= 0 && px < w && py >= 0 && py < h) {
            CGDataProviderRef dp = CGImageGetDataProvider(cg);
            CFDataRef data = CGDataProviderCopyData(dp);
            if (data) {
                const uint8_t *bytes = CFDataGetBytePtr(data);
                int bpp = 4;
                int offset = (py * w + px) * bpp;
                if (offset + 3 < CFDataGetLength(data)) {
                    r = bytes[offset+1]; g = bytes[offset+2]; b = bytes[offset+3];
                }
                CFRelease(data);
            }
        }
        // 更新颜色预览
        UIView *preview = [bg viewWithTag:905];
        preview.backgroundColor = [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1];
        // 保存临时值到 task
        ACTask *task = objc_getAssociatedObject(bg, "task");
        task.x = pt.x; task.y = pt.y;
        task.r = r; task.g = g; task.b = b;
    }
}
- (void)colorPickerTap:(UITapGestureRecognizer *)g {
    [self colorPickerConfirm:[g locationInView:g.view]];
}
- (void)onColorPickerConfirmTap {
    UIView *bg = g_configWin.rootViewController.view.subviews.firstObject;
    ACTask *task = objc_getAssociatedObject(bg, "task");
    if (!task) return;
    [g_configWin setHidden:YES]; g_configWin = nil;
    [self showColorToleranceConfig:task];
}

- (void)onColorPickerCancel {
    UIView *bg = g_configWin.rootViewController.view.subviews.firstObject;
    ACTask *task = objc_getAssociatedObject(bg, "task");
    [g_configWin setHidden:YES]; g_configWin = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showPanel];
        if (task) [self showEditPanel:task];
    });
}
- (void)colorPickerConfirm:(CGPoint)pt {
    UIImage *ss = takeScreenshot();
    if (!ss) { [self onPickerForEditCancel]; return; }
    CGImageRef cg = ss.CGImage;
    int w = (int)CGImageGetWidth(cg), h = (int)CGImageGetHeight(cg);
    int px = (int)(pt.x * UIScreen.mainScreen.scale);
    int py = (int)(pt.y * UIScreen.mainScreen.scale);
    int r = 0, g = 0, b = 0;
    if (px >= 0 && px < w && py >= 0 && py < h) {
        CGDataProviderRef dp = CGImageGetDataProvider(cg);
        CFDataRef data = CGDataProviderCopyData(dp);
        if (data) {
            const uint8_t *bytes = CFDataGetBytePtr(data);
            int bpp = 4;
            int offset = (py * w + px) * bpp;
            if (offset + 3 < CFDataGetLength(data)) {
                r = bytes[offset+1]; g = bytes[offset+2]; b = bytes[offset+3];
            }
            CFRelease(data);
        }
    }
    ACTask *task = objc_getAssociatedObject(g_configWin.rootViewController.view.subviews.firstObject, "task");
    task.x = pt.x; task.y = pt.y;
    task.r = r; task.g = g; task.b = b;
    [g_configWin setHidden:YES]; g_configWin = nil;
    // 显示容差配置
    [self showColorToleranceConfig:task];
}
- (void)showColorToleranceConfig:(ACTask *)task {
    CGRect sb = UIScreen.mainScreen.bounds;
    g_configWin = [[ACPassThroughWindow alloc] initWithFrame:sb];
    g_configWin.windowLevel = UIWindowLevelAlert - 1;
    g_configWin.backgroundColor = UIColor.clearColor; g_configWin.hidden = NO;
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = UIColor.clearColor; g_configWin.rootViewController = vc;
    UIView *bg = [[UIView alloc] initWithFrame:sb];
    bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    [vc.view addSubview:bg];
    CGFloat cw = 260, ch = 220;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((sb.size.width-cw)/2, (sb.size.height-ch)/2, cw, ch)];
    card.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    card.layer.cornerRadius = 14; [bg addSubview:card];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 16, cw, 24)];
    title.text = @"取色结果"; title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter; title.font = [UIFont boldSystemFontOfSize:16];
    [card addSubview:title];
    // 颜色预览
    UIView *preview = [[UIView alloc] initWithFrame:CGRectMake(cw/2-40, 50, 80, 40)];
    preview.backgroundColor = [UIColor colorWithRed:task.r/255.0 green:task.g/255.0 blue:task.b/255.0 alpha:1];
    preview.layer.cornerRadius = 6; preview.layer.borderWidth = 2; preview.layer.borderColor = UIColor.whiteColor.CGColor;
    [card addSubview:preview];
    UILabel *rgbLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 95, cw, 20)];
    rgbLabel.text = [NSString stringWithFormat:@"RGB: %ld %ld %ld", (long)task.r, (long)task.g, (long)task.b];
    rgbLabel.textColor = UIColor.whiteColor;
    rgbLabel.textAlignment = NSTextAlignmentCenter; rgbLabel.font = [UIFont systemFontOfSize:14];
    [card addSubview:rgbLabel];
    // 容差
    UILabel *toleranceLb = [[UILabel alloc] initWithFrame:CGRectMake(20, 125, 60, 30)];
    toleranceLb.text = @"容差"; toleranceLb.textColor = UIColor.lightGrayColor;
    toleranceLb.font = [UIFont systemFontOfSize:12];
    [card addSubview:toleranceLb];
    UILabel *valLb = [[UILabel alloc] initWithFrame:CGRectMake(cw-80, 125, 60, 30)];
    valLb.text = [NSString stringWithFormat:@"%.0f%%", task.threshold * 100];
    valLb.textAlignment = NSTextAlignmentRight; valLb.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.3 alpha:1];
    valLb.font = [UIFont systemFontOfSize:12]; valLb.tag = 5101;
    [card addSubview:valLb];
    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(20, 155, cw-40, 30)];
    slider.minimumValue = 0; slider.maximumValue = 0.3; slider.value = task.threshold;
    slider.minimumTrackTintColor = [UIColor systemBlueColor];
    slider.tag = 5102;
    [slider addTarget:self action:@selector(colorToleranceChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:slider];
    // 确定
    UIButton *ok = [UIButton buttonWithType:UIButtonTypeCustom];
    ok.frame = CGRectMake(cw/2-60, 190, 120, 26);
    ok.backgroundColor = [UIColor systemBlueColor];
    ok.layer.cornerRadius = 13;
    [ok setTitle:@"保存" forState:UIControlStateNormal];
    [ok setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    ok.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    objc_setAssociatedObject(ok, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [ok addTarget:self action:@selector(onColorMatchConfirm:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:ok];
}
- (void)colorToleranceChanged:(UISlider *)slider {
    UILabel *val = [slider.superview viewWithTag:5101];
    val.text = [NSString stringWithFormat:@"%.0f%%", slider.value * 100];
}
- (void)onColorMatchConfirm:(UIButton *)btn {
    ACTask *task = objc_getAssociatedObject(btn, "task");
    UISlider *slider = [btn.superview viewWithTag:5102];
    task.threshold = slider.value;
    [g_taskList addObject:task];
    [self saveTasks];
    [self addLog:[NSString stringWithFormat:@"已添加取色: RGB(%d,%d,%d) 容差:%.0f%%", task.r, task.g, task.b, task.threshold*100]];
    [g_configWin setHidden:YES]; g_configWin = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; [self refreshTaskList]; });
}

// ==================== 跳转编辑面板 ====================
- (void)showGotoEditPanel:(ACTask *)task {
    UIView *card = [self createEditPanelOverlay:task title:@"编辑 - 跳转"];
    CGFloat cw = card.frame.size.width;
    CGFloat y = 158;
    
    // 跳转目标
    UILabel *targetLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 80, 28)];
    targetLb.text = @"目标序号";
    targetLb.textColor = [UIColor lightGrayColor];
    targetLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:targetLb];
    UITextField *gotoTf = [[UITextField alloc] initWithFrame:CGRectMake(100, y, 80, 28)];
    gotoTf.text = [NSString stringWithFormat:@"%ld", (long)task.gotoIndex + 1];
    gotoTf.textColor = UIColor.whiteColor;
    gotoTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    gotoTf.layer.cornerRadius = 6;
    gotoTf.font = [UIFont systemFontOfSize:13];
    gotoTf.keyboardType = UIKeyboardTypeNumberPad;
    gotoTf.textAlignment = NSTextAlignmentCenter;
    gotoTf.tag = 10010;
    gotoTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    gotoTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:gotoTf];
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(190, y, 80, 28)];
    hint.text = @"(从1开始)";
    hint.textColor = [UIColor grayColor];
    hint.font = [UIFont systemFontOfSize:10];
    [card addSubview:hint];
    
    // 取消/保存
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    cancelBtn.frame = CGRectMake(cw/2-100, y+50, 90, 34);
    cancelBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    cancelBtn.layer.cornerRadius = 17;
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [cancelBtn addTarget:self action:@selector(onEditPanelCancel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancelBtn];
    
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.frame = CGRectMake(cw/2+10, y+50, 90, 34);
    saveBtn.backgroundColor = [UIColor systemBlueColor];
    saveBtn.layer.cornerRadius = 17;
    [saveBtn setTitle:@"保存" forState:UIControlStateNormal];
    [saveBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    objc_setAssociatedObject(saveBtn, "card", card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "gotoField", @(10010), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [saveBtn addTarget:self action:@selector(onGotoEditSave:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:saveBtn];
    
    ((UIScrollView *)card).contentSize = CGSizeMake(cw, y+100);
}

- (void)onGotoEditSave:(UIButton *)btn {
    UIView *card = objc_getAssociatedObject(btn, "card");
    ACTask *task = objc_getAssociatedObject(card, "task");
    [self saveEditPanel:card];
    UITextField *gotoTf = [card viewWithTag:10010];
    task.gotoIndex = [gotoTf.text integerValue] - 1;
    if (task.gotoIndex < 0) task.gotoIndex = 0;
    [self saveTasks];
    [self refreshTaskList];
    [self dismissEditPanel];
    [self addLog:[NSString stringWithFormat:@"已保存跳转: 第 %ld 条", (long)task.gotoIndex + 1]];
}

// ==================== 条件编辑面板 ====================
- (void)showConditionEditPanel:(ACTask *)task {
    UIView *card = [self createEditPanelOverlay:task title:@"编辑 - 条件"];
    CGFloat cw = card.frame.size.width;
    CGFloat y = 158;
    
    // 条件类型
    UILabel *typeLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 80, 28)];
    typeLb.text = @"条件类型";
    typeLb.textColor = [UIColor lightGrayColor];
    typeLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:typeLb];
    
    UISegmentedControl *typeSeg = [[UISegmentedControl alloc] initWithItems:@[@"如果匹配", @"如果不匹配"]];
    typeSeg.frame = CGRectMake(20, y+32, cw-40, 32);
    typeSeg.selectedSegmentIndex = task.conditionType == 2 ? 1 : 0;
    typeSeg.tintColor = [UIColor systemBlueColor];
    typeSeg.tag = 10030;
    [card addSubview:typeSeg];
    
    // 跳转目标
    UILabel *targetLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y+74, 80, 28)];
    targetLb.text = @"跳转到";
    targetLb.textColor = [UIColor lightGrayColor];
    targetLb.font = [UIFont systemFontOfSize:13];
    [card addSubview:targetLb];
    UITextField *gotoTf = [[UITextField alloc] initWithFrame:CGRectMake(100, y+74, 80, 28)];
    gotoTf.text = [NSString stringWithFormat:@"%ld", (long)task.gotoIndex + 1];
    gotoTf.textColor = UIColor.whiteColor;
    gotoTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    gotoTf.layer.cornerRadius = 6;
    gotoTf.font = [UIFont systemFontOfSize:13];
    gotoTf.keyboardType = UIKeyboardTypeNumberPad;
    gotoTf.textAlignment = NSTextAlignmentCenter;
    gotoTf.tag = 10010;
    gotoTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
    gotoTf.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:gotoTf];
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(190, y+74, 80, 28)];
    hint.text = @"(从1开始)";
    hint.textColor = [UIColor grayColor];
    hint.font = [UIFont systemFontOfSize:10];
    [card addSubview:hint];
    
    UILabel *desc = [[UILabel alloc] initWithFrame:CGRectMake(20, y+110, cw-40, 28)];
    desc.text = @"条件判断前一条任务的结果";
    desc.textColor = [UIColor grayColor];
    desc.font = [UIFont systemFontOfSize:11];
    desc.textAlignment = NSTextAlignmentCenter;
    [card addSubview:desc];
    
    // 取消/保存
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    cancelBtn.frame = CGRectMake(cw/2-100, y+150, 90, 34);
    cancelBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    cancelBtn.layer.cornerRadius = 17;
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [cancelBtn addTarget:self action:@selector(onEditPanelCancel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancelBtn];
    
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    saveBtn.frame = CGRectMake(cw/2+10, y+150, 90, 34);
    saveBtn.backgroundColor = [UIColor systemBlueColor];
    saveBtn.layer.cornerRadius = 17;
    [saveBtn setTitle:@"保存" forState:UIControlStateNormal];
    [saveBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    objc_setAssociatedObject(saveBtn, "card", card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "gotoField", @(10010), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, "typeSeg", @(10030), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [saveBtn addTarget:self action:@selector(onConditionEditSave:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:saveBtn];
    
    ((UIScrollView *)card).contentSize = CGSizeMake(cw, y+200);
}

- (void)onConditionEditSave:(UIButton *)btn {
    UIView *card = objc_getAssociatedObject(btn, "card");
    ACTask *task = objc_getAssociatedObject(card, "task");
    [self saveEditPanel:card];
    UITextField *gotoTf = [card viewWithTag:10010];
    UISegmentedControl *typeSeg = [card viewWithTag:10030];
    task.gotoIndex = [gotoTf.text integerValue] - 1;
    if (task.gotoIndex < 0) task.gotoIndex = 0;
    task.conditionType = typeSeg.selectedSegmentIndex == 0 ? 1 : 2;
    [self saveTasks];
    [self refreshTaskList];
    [self dismissEditPanel];
    [self addLog:[NSString stringWithFormat:@"已保存条件: %@时跳转第%ld条",
        task.conditionType == 1 ? @"匹配" : @"不匹配", (long)task.gotoIndex + 1]];
}

// 取色编辑面板（复用已有颜色拾取流程）
- (void)showColorMatchEditPanel:(ACTask *)task {
    // 如果已有坐标数据，直接显示编辑面板
    if (task.x > 0 || task.y > 0) {
        // 显示取色编辑面板（带颜色预览和容差设置）
        UIView *card = [self createEditPanelOverlay:task title:@"编辑 - 取色"];
        CGFloat cw = card.frame.size.width;
        CGFloat y = 158;
        
        // 坐标
        UILabel *coordLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y, 60, 28)];
        coordLb.text = @"坐标X";
        coordLb.textColor = [UIColor lightGrayColor];
        coordLb.font = [UIFont systemFontOfSize:13];
        [card addSubview:coordLb];
        UITextField *xTf = [[UITextField alloc] initWithFrame:CGRectMake(80, y, 60, 28)];
        xTf.text = [NSString stringWithFormat:@"%.0f", task.x];
        xTf.textColor = UIColor.whiteColor;
        xTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        xTf.layer.cornerRadius = 6;
        xTf.font = [UIFont systemFontOfSize:13];
        xTf.keyboardType = UIKeyboardTypeNumberPad;
        xTf.textAlignment = NSTextAlignmentCenter;
        xTf.tag = 10010;
        xTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
        xTf.leftViewMode = UITextFieldViewModeAlways;
        [card addSubview:xTf];
        
        UILabel *coordY = [[UILabel alloc] initWithFrame:CGRectMake(150, y, 20, 28)];
        coordY.text = @"Y";
        coordY.textColor = [UIColor lightGrayColor];
        coordY.font = [UIFont systemFontOfSize:13];
        [card addSubview:coordY];
        UITextField *yTf = [[UITextField alloc] initWithFrame:CGRectMake(170, y, 60, 28)];
        yTf.text = [NSString stringWithFormat:@"%.0f", task.y];
        yTf.textColor = UIColor.whiteColor;
        yTf.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        yTf.layer.cornerRadius = 6;
        yTf.font = [UIFont systemFontOfSize:13];
        yTf.keyboardType = UIKeyboardTypeNumberPad;
        yTf.textAlignment = NSTextAlignmentCenter;
        yTf.tag = 10011;
        yTf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,28)];
        yTf.leftViewMode = UITextFieldViewModeAlways;
        [card addSubview:yTf];
        
        // 颜色预览
        UILabel *colorLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y+36, 80, 28)];
        colorLb.text = @"颜色预览";
        colorLb.textColor = [UIColor lightGrayColor];
        colorLb.font = [UIFont systemFontOfSize:13];
        [card addSubview:colorLb];
        
        UIView *preview = [[UIView alloc] initWithFrame:CGRectMake(100, y+36, 40, 28)];
        preview.backgroundColor = [UIColor colorWithRed:task.r/255.0 green:task.g/255.0 blue:task.b/255.0 alpha:1];
        preview.layer.cornerRadius = 6;
        preview.layer.borderWidth = 1;
        preview.layer.borderColor = [UIColor whiteColor].CGColor;
        [card addSubview:preview];
        
        UILabel *rgbLabel = [[UILabel alloc] initWithFrame:CGRectMake(150, y+36, 120, 28)];
        rgbLabel.text = [NSString stringWithFormat:@"RGB(%d,%d,%d)", task.r, task.g, task.b];
        rgbLabel.textColor = [UIColor lightGrayColor];
        rgbLabel.font = [UIFont systemFontOfSize:11];
        [card addSubview:rgbLabel];
        
        // 容差
        UILabel *tolLb = [[UILabel alloc] initWithFrame:CGRectMake(20, y+72, 60, 28)];
        tolLb.text = @"容差";
        tolLb.textColor = [UIColor lightGrayColor];
        tolLb.font = [UIFont systemFontOfSize:13];
        [card addSubview:tolLb];
        UILabel *tolVal = [[UILabel alloc] initWithFrame:CGRectMake(cw-80, y+72, 60, 28)];
        tolVal.text = [NSString stringWithFormat:@"%.0f%%", task.threshold * 100];
        tolVal.textAlignment = NSTextAlignmentRight;
        tolVal.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.3 alpha:1];
        tolVal.font = [UIFont systemFontOfSize:12];
        tolVal.tag = 10020;
        [card addSubview:tolVal];
        UISlider *tolSlider = [[UISlider alloc] initWithFrame:CGRectMake(20, y+100, cw-40, 24)];
        tolSlider.minimumValue = 0;
        tolSlider.maximumValue = 0.3;
        tolSlider.value = task.threshold;
        tolSlider.minimumTrackTintColor = [UIColor systemBlueColor];
        tolSlider.tag = 10021;
        [tolSlider addTarget:self action:@selector(colorMatchEditSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [card addSubview:tolSlider];
        
        // 重新拾取按钮
        UIButton *pickBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        pickBtn.frame = CGRectMake(20, y+132, cw-40, 32);
        pickBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:1];
        pickBtn.layer.cornerRadius = 16;
        [pickBtn setTitle:@"重新拾取颜色" forState:UIControlStateNormal];
        [pickBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        pickBtn.titleLabel.font = [UIFont systemFontOfSize:13];
        objc_setAssociatedObject(pickBtn, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [pickBtn addTarget:self action:@selector(onColorMatchRePick:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:pickBtn];
        
        // 取消/确定
        UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        cancelBtn.frame = CGRectMake(cw/2-100, y+176, 90, 34);
        cancelBtn.backgroundColor = [UIColor colorWithRed:0.75 green:0.15 blue:0.15 alpha:1];
        cancelBtn.layer.cornerRadius = 17;
        [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
        [cancelBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [cancelBtn addTarget:self action:@selector(onEditPanelCancel) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:cancelBtn];
        
        UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        saveBtn.frame = CGRectMake(cw/2+10, y+176, 90, 34);
        saveBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:1];
        saveBtn.layer.cornerRadius = 17;
        [saveBtn setTitle:@"确定" forState:UIControlStateNormal];
        [saveBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        objc_setAssociatedObject(saveBtn, "card", card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [saveBtn addTarget:self action:@selector(onColorMatchEditSave:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:saveBtn];
        
        ((UIScrollView *)card).contentSize = CGSizeMake(cw, y+220);
    } else {
        // 新任务，走颜色拾取流程
        [self showColorMatchPicker:task];
    }
}

- (void)colorMatchEditSliderChanged:(UISlider *)slider {
    UILabel *val = [slider.superview viewWithTag:10020];
    val.text = [NSString stringWithFormat:@"%.0f%%", slider.value * 100];
}

- (void)onColorMatchEditSave:(UIButton *)btn {
    UIView *card = objc_getAssociatedObject(btn, "card");
    ACTask *task = objc_getAssociatedObject(card, "task");
    [self saveEditPanel:card];
    UISlider *tolSlider = [card viewWithTag:10021];
    task.threshold = tolSlider.value;
    [self saveTasks];
    [self refreshTaskList];
    [self dismissEditPanel];
    [self addLog:[NSString stringWithFormat:@"已保存取色: RGB(%d,%d,%d) 容差:%.0f%%", task.r, task.g, task.b, task.threshold*100]];
}

- (void)onColorMatchRePick:(UIButton *)sender {
    ACTask *task = objc_getAssociatedObject(sender, "task");
    [self dismissEditPanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self showColorMatchPicker:task];
    });
}

- (void)showColorMatchPicker:(ACTask *)task {
    [self dismissPanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGRect sb = UIScreen.mainScreen.bounds;
        g_configWin = [[ACPassThroughWindow alloc] initWithFrame:sb];
        g_configWin.windowLevel = UIWindowLevelAlert - 1;
        g_configWin.backgroundColor = UIColor.clearColor;
        g_configWin.hidden = NO;
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = UIColor.clearColor;
        g_configWin.rootViewController = vc;
        
        UIView *bg = [[UIView alloc] initWithFrame:sb];
        bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        [vc.view addSubview:bg];
        
        // 十字光标
        UIView *hLine = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-40, sb.size.height/2-0.5, 80, 1)];
        hLine.backgroundColor = [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.9]; hLine.tag = 901;
        [bg addSubview:hLine];
        UIView *vLine = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-0.5, sb.size.height/2-40, 1, 80)];
        vLine.backgroundColor = [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.9]; vLine.tag = 902;
        [bg addSubview:vLine];
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-8, sb.size.height/2-8, 16, 16)];
        dot.layer.cornerRadius = 8; dot.layer.borderColor = [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.9].CGColor;
        dot.layer.borderWidth = 2; dot.tag = 903;
        [bg addSubview:dot];
        
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, sb.size.width-40, 36)];
        hint.text = @"拖动光标取色，自动显示颜色";
        hint.textColor = UIColor.whiteColor; hint.textAlignment = NSTextAlignmentCenter;
        hint.font = [UIFont boldSystemFontOfSize:16]; hint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        hint.layer.cornerRadius = 10; hint.clipsToBounds = YES; hint.tag = 904;
        [bg addSubview:hint];
        
        // 颜色预览条
        UIView *colorPreview = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width/2-30, sb.size.height/2-30, 60, 60)];
        colorPreview.layer.cornerRadius = 8;
        colorPreview.layer.borderColor = [UIColor whiteColor].CGColor;
        colorPreview.layer.borderWidth = 2;
        colorPreview.tag = 905;
        colorPreview.backgroundColor = [UIColor grayColor];
        [bg addSubview:colorPreview];
        
        // 确定按钮
        UIButton *confirmBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        confirmBtn.frame = CGRectMake(sb.size.width/2-110, sb.size.height-100, 100, 36);
        confirmBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:1];
        confirmBtn.layer.cornerRadius = 18;
        [confirmBtn setTitle:@"确定" forState:UIControlStateNormal];
        [confirmBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        confirmBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [confirmBtn addTarget:self action:@selector(onColorPickerConfirmTap) forControlEvents:UIControlEventTouchUpInside];
        [bg addSubview:confirmBtn];
        
        UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
        cancel.frame = CGRectMake(sb.size.width/2+10, sb.size.height-100, 100, 36);
        cancel.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1];
        cancel.layer.cornerRadius = 18;
        [cancel setTitle:@"取消" forState:UIControlStateNormal];
        [cancel setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        cancel.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [cancel addTarget:self action:@selector(onColorPickerCancel) forControlEvents:UIControlEventTouchUpInside];
        [bg addSubview:cancel];
        
        objc_setAssociatedObject(bg, "task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // 只截图一次避免卡顿
        UIImage *ss = takeScreenshot();
        objc_setAssociatedObject(bg, "cachedScreenshot", ss, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(colorPickerPan:)];
        [bg addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(colorPickerTap:)];
        [bg addGestureRecognizer:tap];
    });
}
@end

// ==================== sendEvent Hook（录制用）====================
static void hook_sendEvent(id self, SEL _cmd, UIEvent *event) {
    orig_sendEvent(self, _cmd, event);
    if (!g_isRecording || !event) return;
    if (event.type == UIEventTypeTouches) {
        UITouch *touch = event.allTouches.anyObject;
        if (touch.phase == UITouchPhaseBegan) {
            CGPoint pt = [touch locationInView:nil];
            @synchronized(g_recordedEvents) {
                [g_recordedEvents addObject:@{@"x":@(pt.x), @"y":@(pt.y), @"t":@([[NSDate date] timeIntervalSince1970])}];
            }
        }
    }
}

// ==================== 锁屏hook ====================
static void (*orig_SpringBoard_locked)(id, SEL);
static void hook_SpringBoard_locked(id self, SEL _cmd) {
    orig_SpringBoard_locked(self, _cmd);
    if (g_isRunning) {
        [g_engine stop];
        g_isRunning = NO;
        [[ACCtrl shared] addLog:@"锁屏自动停止"];
        [[ACCtrl shared] setFloatIndicator:NO];
    }
}

// ==================== 音量键监听 ====================
@interface ACVolumeMonitor : NSObject
@property (nonatomic, assign) BOOL listening;
@property (nonatomic, copy) void (^callback)(void);
@end
@implementation ACVolumeMonitor
- (void)startListening:(void(^)(void))cb {
    self.callback = cb;
    self.listening = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(volumeChanged:)
        name:@"AVSystemController_SystemVolumeDidChangeNotification" object:nil];
}
- (void)volumeChanged:(NSNotification *)n {
    if (!g_isRunning && g_taskList.count > 0 && self.callback) self.callback();
}
@end
static ACVolumeMonitor *g_volMon;

// ==================== 初始化 ====================
__attribute__((constructor))
static void init() {
    dispatch_async(dispatch_get_main_queue(), ^{
        static void (^trySetup)(void);
        trySetup = ^{
            UIWindow *kw = [UIApplication sharedApplication].keyWindow;
            if (!kw) {
                for (UIWindow *w in [UIApplication sharedApplication].windows)
                    if (!w.hidden) { kw = w; break; }
            }
            if (!kw) {
                id del = [UIApplication sharedApplication].delegate;
                if ([del respondsToSelector:@selector(window)]) kw = [del window];
            }
            if (kw) {
                @try {
                    resolveIOHID();
                    [[ACCtrl shared] setupFloatUI];
                    // Hook SpringBoard 锁屏（仅当运行在SpringBoard进程时）
                    Class sbClass = objc_getClass("SpringBoard");
                    if (sbClass) {
                        MSHookMessageEx(sbClass, @selector(_locked),
                            (IMP)&hook_SpringBoard_locked, (IMP*)&orig_SpringBoard_locked);
                    }
                    // 音量键启动
                    g_volMon = [[ACVolumeMonitor alloc] init];
                    [g_volMon startListening:^{
                        [[ACCtrl shared] onStartTasks];
                    }];
                    NSLog(@"[AC] 初始化完成，参考老贝贝连点器架构");
                } @catch (NSException *e) {
                    NSLog(@"[AC] 初始化异常: %@", e.reason);
                }
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)),
                               dispatch_get_main_queue(), trySetup);
            }
        };
        trySetup();
    });
}
