// ============================================================
// PTDylibMain.m —— PageTurnerDylib 入口（v1.0.10）
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
static UILongPressGestureRecognizer *gGesture = nil;   // v1.0.7：记录手势实例，keyWindow 变化时迁移

// v1.0.7：把手势迁到当前 keyWindow（keyWindow 变化时由通知驱动，不再等手势触发——
// 此前手势挂在旧 keyWindow 上触发不了就永远自愈不了）
// v1.0.10：改双指（三指在阅读 App 里易被系统/App 手势抢）+ 3s 定时兜底迁移
static void PTDylibInstallGesture(void) {
    UIWindow *kw = PTDylibKeyWindow();
    if (!kw) {
        // keyWindow 还没就绪：500ms 后再试
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ PTDylibInstallGesture(); });
        return;
    }
    if (kw == gMenuWindow) return;   // 菜单窗口不是 App 窗口，手势不装它上面
    if (gGesture && gGesture.view == kw) return;   // 已装在当前 keyWindow
    if (gGesture) {
        [gGesture.view removeGestureRecognizer:gGesture];
        gGesture = nil;
    }
    if (!gGestureTarget) gGestureTarget = [PTDylibGestureTarget new];
    gGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:gGestureTarget action:@selector(handle:)];
    gGesture.numberOfTouchesRequired = 2;   // v1.0.10：双指长按（更少冲突）
    gGesture.minimumPressDuration = 0.5;
    [kw addGestureRecognizer:gGesture];
    PTDylibLog(@"双指长按手势已安装（keyWindow=%@）", kw);
}

// v1.0.10：3 秒定时兜底迁移（通知漏掉 keyWindow 变化时也能跟上）
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
                PTDylibLog(@"PageTurnerDylib v1.0.10 已注入 %@ (pid=%d) 配置来源=%@",
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
