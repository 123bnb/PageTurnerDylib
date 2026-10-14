// ============================================================
// PTDylibMain.m —— PageTurnerDylib 入口（v1.0.12）
//
// 注入即生效：constructor → 主队列安装 hook。
// v1.0.12：不再用手势识别器（会被 App 手势仲裁抢）——双指长按改由
// PTDylibSendEvent（sendEvent 层）检测：两指同时按下 0.5s 不动 → 弹出菜单，
// App 任何页面任何角落都能触发。
// 菜单 = 独立覆盖窗口（UINavigationController 包主菜单）。
// 可视化/录制 = keyWindow 上的覆盖层（不建窗口，不碰状态栏）。
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

// v1.0.12：判断是否菜单窗口（Core 双指检测排除菜单上的触摸）
BOOL PTDylibIsMenuWindow(UIWindow *w) {
    return w == gMenuWindow;
}

// 弹出主菜单（v1.0.12 起由 sendEvent 双指检测调用）
void PTDylibShowMenu(void) {
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

// 注入入口：TrollStore/巨魔注入 dylib 后立即执行
__attribute__((constructor))
static void PTDylibInit(void) {
    dispatch_once(&gInitOnce, ^{
        @autoreleasepool {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
                PTDylibInstallHooks();
                PTDylibLog(@"==================================================");
                PTDylibLog(@"PageTurnerDylib v1.0.12 已注入 %@ (pid=%d) 配置来源=%@",
                    bid, getpid(), PTDylibUsingDebConfig() ? @"复用deb配置" : @"独立配置");
                PTDylibLog(@"配置路径=%@ 防抖=%.0fms 方案数=%lu",
                    PTDylibCfgPath(),
                    [PTDylibReadCfg()[@"debounceMs"] doubleValue] ?: 300,
                    (unsigned long)([PTDylibReadCfg()[@"plans"] count] ?: 0));
                PTDylibLog(@"==================================================");
                // v1.0.7→v1.0.12：keyWindow 变化（App 切阅读页全屏窗口等）时——
                // 迁移可视化覆盖层 & 录制覆盖层（若在录制）
                [[NSNotificationCenter defaultCenter]
                    addObserverForName:UIWindowDidBecomeKeyNotification
                    object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                        PTDebugMigrateOverlay();
                        PTRecMigrateOverlay();
                    }];
            });
        }
    });
}
