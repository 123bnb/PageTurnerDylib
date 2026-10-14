// ============================================================
// PTDylibShared.h —— PageTurnerDylib 跨文件共享符号
// core（运行端/采集/hook 装配）↔ UI（设置页/主菜单）↔ main（入口/手势）
// ============================================================
#ifndef PTDylibShared_h
#define PTDylibShared_h

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// ---------- 配置 ----------
// 当前实际使用的配置文件路径（deb 配置存在则复用 deb，否则 dylib 独立配置）
extern NSString *PTDylibCfgPath(void);
extern BOOL PTDylibUsingDebConfig(void);   // YES=复用 deb 版配置；NO=独立配置
extern NSMutableDictionary *PTDylibReadCfg(void);
extern void PTDylibWriteCfg(NSDictionary *cfg);

// ---------- 日志 ----------
extern void PTDylibLog(NSString *fmt, ...);
extern NSArray *PTDylibLogLines(void);   // 内存日志副本（日志页显示）

// ---------- hook 装配 ----------
extern void PTDylibInstallHooks(void);

// ---------- 学习/测试会话状态（core 定义，UI 读写） ----------
extern BOOL sCollectArmed;     // 学习页打开 = YES
extern BOOL sTestArmed;        // 测试页打开 = YES
extern double sLastSampleAt;   // 最近样本时间（学习页诊断）
extern UIView *sTestDot;       // 测试页绿点视图
extern __weak id sTestLogSink;   // 测试页实时记录区（弱引用）
extern void PTDylibSetLearningLocal(BOOL on);   // 写 learning.active + 清样本

// ---------- 工具（core 定义，UI 复用） ----------
extern double PTNowC(void);
extern NSString *PTDirName(double dir);
extern NSString *PTActionText(NSDictionary *a);
extern NSArray *PTFeaturesOfPlan(NSDictionary *p);
extern NSString *PTDuplicate(NSDictionary *s, NSArray *plans);
extern BOOL PTStable(NSArray *mem, NSString *sender);
extern void PTTestOnEnded(int phase, double dir, double dist, uint64_t sender, int tapDx);
extern void PTTestShowDot(CGPoint from, CGPoint to, BOOL animate, double dur);

// ---------- 手动滑动录制（v1.0.8，滑动(手动)动作） ----------
// 录制页打开：topY = 录制区上边界（完成按钮行往下），done 每次滑动结束回调（传轨迹点 x/y/t毫秒）
extern void PTRecStart(double topY, void (^done)(NSArray *pts));
extern void PTRecStop(void);

// ---------- 主菜单窗口（main 实现，UI 关闭按钮调用） ----------
extern void PTDylibCloseMenu(void);

#endif
