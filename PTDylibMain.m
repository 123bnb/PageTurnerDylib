// ============================================================
// PTDylibMain.m —— PageTurnerDylib 入口（v1.0.5）
//
// 注入即生效：constructor → 主队列安装 hook → keyWindow 装三指长按手势。
// 三指长按 0.5s → 弹出独立覆盖窗口（UINavigationController 包主菜单），
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
    PTDylibLog(@"三指长按 → 弹出主菜单");
}

// 手势 target（保持的实例，避免 static 函数无法做 selector target）
@interface PTDylibGestureTarget : NSObject
- (void)handle:(UILongPressGestureRecognizer *)g;
@end
@implementation PTDylibGestureTarget
- (void)handle:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    // 手势挂在旧 keyWindow 时重装到当前 keyWindow
    UIWindow *kw = PTDylibKeyWindow();
    if (g.view != kw) {
        [g.view removeGestureRecognizer:g];
        if (kw) [kw addGestureRecognizer:g];
    }
    PTDylibShowMenu();
}
@end

static PTDylibGestureTarget *gGestureTarget = nil;

// 安装三指长按手势（App 前台、keyWindow 就绪后调用）
static void PTDylibInstallGesture(void) {
    UIWindow *kw = PTDylibKeyWindow();
    if (!kw) {
        // keyWindow 还没就绪：500ms 后再试
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ PTDylibInstallGesture(); });
        return;
    }
    for (UIGestureRecognizer *g in kw.gestureRecognizers) {
        if ([g isKindOfClass:[UILongPressGestureRecognizer class]]
            && ((UILongPressGestureRecognizer *)g).numberOfTouchesRequired == 3) return;   // 已装
    }
    if (!gGestureTarget) gGestureTarget = [PTDylibGestureTarget new];
    UILongPressGestureRecognizer *gr = [[UILongPressGestureRecognizer alloc] initWithTarget:gGestureTarget action:@selector(handle:)];
    gr.numberOfTouchesRequired = 3;
    gr.minimumPressDuration = 0.5;
    [kw addGestureRecognizer:gr];
    PTDylibLog(@"三指长按手势已安装（keyWindow=%@）", kw);
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
                PTDylibLog(@"PageTurnerDylib v1.0.5 已注入 %@ (pid=%d) 配置来源=%@",
                    bid, getpid(), PTDylibUsingDebConfig() ? @"复用deb配置" : @"独立配置");
                PTDylibLog(@"配置路径=%@ 防抖=%.0fms 方案数=%lu",
                    PTDylibCfgPath(),
                    [PTDylibReadCfg()[@"debounceMs"] doubleValue] ?: 300,
                    (unsigned long)([PTDylibReadCfg()[@"plans"] count] ?: 0));
                PTDylibLog(@"==================================================");
                // 延迟 1.0s：等 UIApplication/keyWindow 就绪后再装手势（照 DirectVolumeTap）
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ PTDylibInstallGesture(); });
            });
        }
    });
}
