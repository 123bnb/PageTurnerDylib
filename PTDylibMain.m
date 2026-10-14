// ============================================================
// PTDylibMain.m —— PageTurnerDylib 入口（v1.0.11）
//
// 注入即生效：constructor → 主队列安装 hook → keyWindow 装双指长按手势。
// 双指长按 0.5s → 弹出独立覆盖窗口（UINavigationController 包主菜单），
// 在目标 App 内完成防抖/记录映射/调试可视化/调试日志的全部配置。
// 无总开关：不按翻页器键 = 不启用；关闭菜单 = 停止本次配置会话。
// 手势与 hook 参考 DirectVolumeTap 注入方案（constructor + dispatch_once）。
// ============================================================

#import <UIKit/UIKit.h>
#import "PTDylibShared.h"

// 主菜单类在 PTDylibUI.m 实现
@interface PTDylibMenuVC : UITableViewController
@end

static UIWindow *gMenuWindow = nil;
static dispatch_once_t gInitOnce;

// 找当前 keyWindow（多 scene 兼容）
static UIWindow *PTDylibKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app.connectedScenes) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
            return [ws.windows firstObject];
        }
    }
    return app.keyWindow ?: app.windows.firstObject;
}

// 关闭菜单（UI 层关闭按钮调用）
void PTDylibCloseMenu(void) {
    if (!gMenuWindow) return;
    UIWindow *w = gMenuWindow;
    gMenuWindow = nil;
    w.hidden = YES;
    w.rootViewController = nil;
    [w removeFromSuperview];
}

// 弹出主菜单
static void PTDylibShowMenu(void) {
    if (gMenuWindow) {
        gMenuWindow.hidden = NO;
        return;
    }
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelAlert + 1;
    w.backgroundColor = [UIColor systemBackgroundColor];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[PTDylibMenuVC new]];
    w.rootViewController = nav;
    w.hidden = NO;
    gMenuWindow = w;
    PTDylibLog(@"双指长按 → 弹出主菜单");
}

// 手势 target（保持的实例，避免 static 函数无法做 selector target）
@interface PTDylibGestureTarget : NSObject
- (void)handle:(UILongPressGestureRecognizer *)g;
@end
@implementation PTDylibGestureTarget
- (void)handle:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    PTDylibShowMenu();
}
@end

static PTDylibGestureTarget *gGestureTarget = nil;
static NSMutableArray *gGestures = nil;   // v1.0.11：每个窗口装一个双指长按（共享 target）

// v1.0.11：取 scene 内全部前台窗口（不止 keyWindow——App 阅读页可能用独立窗口，
// 只挂 keyWindow 会在窗口切换后失效，这就是"除了启动外难启动"的根因）
static NSArray *PTDylibAllWindows(void) {
    NSMutableArray *ws = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    if (app.connectedScenes) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *wsc = (UIWindowScene *)scene;
            if (wsc.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in wsc.windows) if (![ws containsObject:w]) [ws addObject:w];
        }
    }
    for (UIWindow *w in app.windows) if (![ws containsObject:w]) [ws addObject:w];
    return ws;
}

// v1.0.7→v1.0.11：手势装到所有窗口（双指长按），watchdog 定时补装；窗口切换不再丢手势
static void PTDylibInstallGesture(void) {
    NSArray *ws = PTDylibAllWindows();
    if (!ws.count) {
        // 窗口还没就绪：500ms 后再试
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ PTDylibInstallGesture(); });
        return;
    }
    if (!gGestureTarget) gGestureTarget = [PTDylibGestureTarget new];
    if (!gGestures) gGestures = [NSMutableArray array];
    // 清理已失效手势（窗口已释放）
    NSMutableArray *dead = [NSMutableArray array];
    for (UIGestureRecognizer *g in gGestures) {
        if (!g.view) [dead addObject:g];
    }
    if (dead.count) [gGestures removeObjectsInArray:dead];
    for (UIWindow *w in ws) {
        if (w == gMenuWindow) continue;   // 菜单窗口不装（装了也没用）
        BOOL has = NO;
        for (UIGestureRecognizer *g in gGestures) { if (g.view == w) { has = YES; break; } }
        if (has) continue;
        UILongPressGestureRecognizer *gr = [[UILongPressGestureRecognizer alloc]
            initWithTarget:gGestureTarget action:@selector(handle:)];
        gr.numberOfTouchesRequired = 2;   // v1.0.10：双指长按（更少冲突）
        gr.minimumPressDuration = 0.5;
        [w addGestureRecognizer:gr];
        [gGestures addObject:gr];
        PTDylibLog(@"双指长按手势已安装（window=%@）", w);
    }
}

// v1.0.10：3 秒定时兜底（通知漏掉/新窗口出现时也能补装）
static void PTDylibScheduleGestureWatchdog(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PTDylibInstallGesture();
        PTDylibScheduleGestureWatchdog();
    });
}

// 注入入口：TrollStore/巨魔注入 dylib 后立即执行
__attribute__((constructor))
static void PTDylibInit(void) {
    dispatch_once(&gInitOnce, ^{
        @autoreleasepool {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
                PTDylibInstallHooks();
                PTDylibLog(@"==================================================");
                PTDylibLog(@"PageTurnerDylib v1.0.11 已注入 %@ (pid=%d) 配置来源=%@",
                    bid, getpid(), PTDylibUsingDebConfig() ? @"复用deb配置" : @"独立配置");
                PTDylibLog(@"配置路径=%@ 防抖=%.0fms 方案数=%lu",
                    PTDylibCfgPath(),
                    [PTDylibReadCfg()[@"debounceMs"] doubleValue] ?: 300,
                    (unsigned long)([PTDylibReadCfg()[@"plans"] count] ?: 0));
                PTDylibLog(@"==================================================");
                // 延迟 1.0s：等 UIApplication/keyWindow 就绪后再装手势（照 DirectVolumeTap）
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ PTDylibInstallGesture(); });
                // v1.0.7：keyWindow 变化（App 切阅读页全屏窗口等）时自动迁移手势，
                // 否则手势留在旧窗口上触发不了（只在触发时迁移的旧逻辑无法自愈）
                [[NSNotificationCenter defaultCenter]
                    addObserverForName:UIWindowDidBecomeKeyNotification
                    object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                        PTDylibInstallGesture();
                    }];
                // v1.0.10：3s 定时兜底（通知漏掉时也能迁移）
                PTDylibScheduleGestureWatchdog();
            });
        }
    });
}
