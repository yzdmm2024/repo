//
//  ROARandomScheduler.h
//  随机开启app - 随机调度引擎
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ROARandomScheduler : NSObject

@property (nonatomic, class, readonly) ROARandomScheduler *sharedInstance;

// 启动 / 停止调度
- (void)start;
- (void)stop;

// 重新读取设置并重算（设置变更后调用）
- (void)reloadSettings;

@end

NS_ASSUME_NONNULL_END