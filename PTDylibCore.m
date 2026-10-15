// ============================================================
// PTDylibCore.m —— PageTurnerDylib 运行端核心（v1.0.20）
//
// 从 deb 版 PageTurner v1.0.43 移植：
//   · Tweak.xm 的运行拦截/匹配/执行/可视化（去掉 Preferences 进程分支、总开关、
//     指定 App 生效、探针、注入标记——dylib 注入即生效）
//   · RootListController.m 的学习/测试采集 + 测试执行（S 系列）
// 与 deb 版的关键差异：
//   · hook 用 method_getImplementation + method_setImplementation（无 ellekit，
//     参考 DirectVolumeTap 纯 clang + ldid 注入方案）
//   · 学习/测试采集与运行拦截合并为同一对 hook（PTDylibAddEvent/PTDylibSendEvent）：
//     学习/测试激活时只采集放行不拦截；否则正常运行拦截
//   · 配置：有 deb 版配置（com.yourname.pageturner.plist 5 候选路径）就复用；
//     没有则自建独立配置 com.yourname.pageturnerdylib.plist
//   · 日志：统一 PTDylibLog（内存 200 条 + 文件 PageTurnerDylib.log 1000 行循环）
// ============================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/time.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <stdarg.h>
#import <unistd.h>
#import "ptftouch/PTFakeMetaTouch.h"
#import "PTDylibShared.h"

// 测试 sink 协议方法（sTestLogSink 为 id 类型，需编译器可见的声明才能调用）
@interface NSObject (PTTestSink)
- (void)appendLog:(NSString *)s;
- (void)drawTrailWithDirection:(double)dir dist:(double)dist phase:(int)phase;
@end

// ============================================================
// 常量
// ============================================================
static NSString *kDylibPrefsName = @"com.yourname.pageturnerdylib.plist";
static NSString *kDylibLogName = @"PageTurnerDylib.log";
static const double kPagerWindowSec = 0.4;       // 翻页器活跃窗口（已学 sender 开窗）
static const double kCollectWindowSec = 0.30;    // v1.0.19：学习/测试采集窗口放宽到 0.3s，减少系统繁忙时丢样本、便于"特征已稳定"达成（原 0.05s 过短）
static const double kTapDistThreshold = 30.0;    // 位移 <30pt 判定 tap
static const double kDirTolerance = 15.0;        // 方向容差 ±15°
static const double kDistSlack = 30.0;           // 位移区间匹配裕度
static const double kTapDistSlack = 0.15;        // 点击位移区间容差
static const double kTapDxThresh = 0.05;         // 点击位移方向判定阈值
static const int kLearnMin = 5;                  // 学习下限
static const int kLearnMax = 15;                 // 学习上限
static const double kConverge = 60.0;            // 位移收敛阈值
static const int kMaxLearnedSenders = 64;        // 已学 sender 上限

// ptftouch/Compat.h 声明了 extern gInjectSender（本库未使用，补实体防止动态查找落空）
uint64_t gInjectSender = 0;

// ============================================================
// 日志（内存 200 条 + 文件 PageTurnerDylib.log 1000 行循环，受 debugLogEnabled 控制）
// ============================================================
static NSMutableArray *sLogLines = nil;
static NSString *sLogFile = nil;
static double sLogCfgMtime = -1;
static BOOL sLogEnabled = YES;

// v1.0.2：日志文件固定 App 容器 Documents（TrollStore 注入无沙盒外权限，/var/mobile/Documents
// 与 jbroot 变体均不可写，不再探测）
static NSString *PTDylibLogFilePath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!dir.length) dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    if (![fm fileExistsAtPath:dir]) [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if ([fm isWritableFileAtPath:dir]) return [dir stringByAppendingPathComponent:kDylibLogName];
    return nil;
}

static void PTDylibEnsureLogFile(NSString *path) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [path stringByDeletingLastPathComponent];
        if (dir.length && ![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    } @catch (NSException *e) {}
}

static void PTDylibTrimLogFile(NSString *path) {
    @try {
        NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!content) return;
        NSArray *lines = [content componentsSeparatedByString:@"\n"];
        if (lines.count > 1000) {
            NSArray *keep = [lines subarrayWithRange:NSMakeRange(lines.count - 1000, 1000)];
            [[keep componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (NSException *e) {}
}

// 开关改动即时生效（mtime 缓存）
static void PTDylibLogRefreshCfg(void) {
    NSString *p = PTDylibCfgPath();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    double mtime = attrs ? [attrs.fileModificationDate timeIntervalSince1970] : 0;
    if (mtime == sLogCfgMtime) return;
    sLogCfgMtime = mtime;
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:p];
    sLogEnabled = (cfg[@"debugLogEnabled"] == nil) ? YES : [cfg[@"debugLogEnabled"] boolValue];
}

void PTDylibLog(NSString *fmt, ...) {
    // v1.0.19：关日志即零 IO——直接返回，不再读 plist/写文件。开启时才按 mtime 探测运行时切换。
    if (!sLogEnabled) return;
    PTDylibLogRefreshCfg();
    if (!sLogLines) sLogLines = [NSMutableArray array];
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv; gettimeofday(&tv, NULL);
    time_t sec = tv.tv_sec; struct tm tmv; localtime_r(&sec, &tmv);
    char tbuf[64]; strftime(tbuf, sizeof(tbuf), "%H:%M:%S", &tmv);
    NSString *line = [NSString stringWithFormat:@"%s.%03d %@", tbuf, (int)(tv.tv_usec / 1000), msg];
    if (sLogLines.count >= 200) [sLogLines removeObjectsInRange:NSMakeRange(0, 100)];
    [sLogLines addObject:line];
    if (!sLogFile) sLogFile = PTDylibLogFilePath();
    if (sLogFile) {
        static int sFileLines = 0;
        PTDylibEnsureLogFile(sLogFile);
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:sLogFile];
        if (fh) {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
                sFileLines++;
            } @catch (NSException *e) {}
        }
        if (sFileLines > 1000) { PTDylibTrimLogFile(sLogFile); sFileLines = 1000; }
    }
}

NSArray *PTDylibLogLines(void) {
    return sLogLines ? [sLogLines copy] : @[];
}

// v1.0.19：日志总开关运行时即时生效（菜单开关调用）；关日志后 PTDylibLog 直接返回，零 IO。
void PTDylibLogSetEnabled(BOOL on) {
    sLogEnabled = on;
}

double PTNowC(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

// ============================================================
// 配置路径选择
// v1.0.2（用户定稿）：去掉 deb 版 5 候选路径探测 / jbroot 镜像推断 / 双写——
//   TrollStore 注入的 App 无沙盒外权限，那些路径全部访问不到（读重定向/写失败），
//   统一固定为 App 容器内自己的配置文件，读写自洽。
// ============================================================
static NSString *gCfgPath = nil;

static void PTDylibInitConfigPath(void) {
    if (gCfgPath) return;
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    if (!dir.length) dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    gCfgPath = [dir stringByAppendingPathComponent:[@"Preferences" stringByAppendingPathComponent:kDylibPrefsName]];
    // 容器 Library/Preferences 目录可能不存在，确保可写
    [[NSFileManager defaultManager] createDirectoryAtPath:[gCfgPath stringByDeletingLastPathComponent]
                             withIntermediateDirectories:YES attributes:nil error:nil];
}

NSString *PTDylibCfgPath(void) {
    PTDylibInitConfigPath();
    return gCfgPath;
}

BOOL PTDylibUsingDebConfig(void) {
    return NO;   // v1.0.2：不再复用 deb 配置（沙盒读不到），恒为独立容器配置
}

// ============================================================
// 配置读写（v1.0.2：只写容器内单一路径，原子写）
// ============================================================
NSMutableDictionary *PTDylibReadCfg(void) {
    NSString *p = PTDylibCfgPath();
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    return d ? [NSMutableDictionary dictionaryWithDictionary:d] : [NSMutableDictionary dictionary];
}

void PTDylibWriteCfg(NSDictionary *cfg) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cfg
        format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    NSString *p = PTDylibCfgPath();
    NSString *tmp = [p stringByAppendingString:@".tmp"];
    [data writeToFile:tmp atomically:YES];
    [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:p error:nil];
}

void PTDylibSetLearningLocal(BOOL on) {
    NSMutableDictionary *cfg = PTDylibReadCfg();
    cfg[@"learning"] = @{ @"active": @(on) };
    if (on) cfg[@"learningSamples"] = @[];
    PTDylibWriteCfg(cfg);
}

// ============================================================
// 运行端配置缓存（mtime；无总开关/无指定 App——dylib 注入即生效）
// ============================================================
static NSDictionary *gConfig = nil;
static double gConfigMtime = 0;
static double gDebounceMs = 300;
static BOOL gDebugDots = NO;
static BOOL gDebugLogEnabled = YES;
static void PTDebugDestroyOverlay(void);    // v1.0.12：可视化覆盖层销毁（前向声明）
static void PTFakeRecSwipeAsync(NSArray *pts, int token, void (^done)(void));  // v1.0.13：测试区回放前向声明
static int gExecToken;   // v1.0.13：前向声明（定义在运行拦截段，测试区 recSwipe 回放需要）
static NSMutableDictionary *gPlans = nil;      // name -> dict
static BOOL gLearnActive = NO;
static uint64_t gLearnedSenders[kMaxLearnedSenders];
static int gLearnedSenderCount = 0;

static void PTDylibLoadConfig(BOOL force) {
    NSString *p = PTDylibCfgPath();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    double mtime = attrs ? [attrs.fileModificationDate timeIntervalSince1970] : 0;
    if (!force && gConfig && mtime == gConfigMtime) return;
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:p];
    gConfig = cfg ? cfg : @{};
    gConfigMtime = mtime;
    double db = [gConfig[@"debounceMs"] doubleValue];
    gDebounceMs = (db > 0) ? db : 300;
    gDebugDots = [gConfig[@"debugDots"] boolValue];
    // v1.0.12：可视化开关关掉 → 销毁绿点覆盖层（覆盖层不碰状态栏，开关只控制显示）
    if (!gDebugDots) PTDebugDestroyOverlay();
    gDebugLogEnabled = (gConfig[@"debugLogEnabled"] == nil) ? YES : [gConfig[@"debugLogEnabled"] boolValue];
    gPlans = [NSMutableDictionary dictionary];
    gLearnedSenderCount = 0;
    for (NSDictionary *pl in gConfig[@"plans"] ?: @[]) {
        if (!pl[@"name"]) continue;
        gPlans[pl[@"name"]] = pl;
        NSArray *fts = pl[@"features"] ?: (pl[@"feature"] ? @[pl[@"feature"]] : @[]);
        for (NSDictionary *ft in fts) {
            if (ft[@"sender"]) {
                unsigned long long s = 0;
                NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
                if ([sc scanHexLongLong:&s] && gLearnedSenderCount < kMaxLearnedSenders) {
                    gLearnedSenders[gLearnedSenderCount++] = s;
                }
            }
        }
    }
    gLearnActive = [gConfig[@"learning"][@"active"] boolValue];
}

// ============================================================
// IOKit（sender 读取）
// ============================================================
typedef uint32_t (*IOHIDEventGetType_t)(void *);
typedef uint64_t (*IOHIDEventGetSenderID_t)(void *);
typedef double (*IOHIDEventGetFloatValue_t)(void *, uint32_t);
static IOHIDEventGetType_t pGetType = NULL;
static IOHIDEventGetSenderID_t pGetSender = NULL;
static IOHIDEventGetFloatValue_t pGetFloat = NULL;

// ============================================================
// 会话状态（学习/测试，UI 层读写 → extern）
// ============================================================
BOOL sCollectArmed = NO;
BOOL sTestArmed = NO;
double sLastSampleAt = 0;
UIView *sTestDot = nil;
__weak id sTestLogSink = nil;

static uint64_t sCurSender = 0;
static double sWindowUntil = 0;
static BOOL sSessActive = NO;
static double sSessDist = 0, sSessFirstDir = 0;
static BOOL sSessHasMove = NO;
static CGPoint sSessLast = {0, 0};
static CGPoint sSessStart = {0, 0};
static BOOL sTestInjecting = NO;      // 测试执行注入保护
static double sLastTestExec = 0;      // 测试防抖

// 学习样本写入 plist（learningSamples，学习页轮询读取）
static void SAppendSample(int phase, double dir, double dist, int tapDx) {
    NSMutableDictionary *cfg = PTDylibReadCfg();
    if (![cfg[@"learning"][@"active"] boolValue]) return;
    NSMutableArray *samples = [NSMutableArray arrayWithArray:cfg[@"learningSamples"] ?: @[]];
    [samples addObject:@{
        @"sender": [NSString stringWithFormat:@"0x%llx", sCurSender],
        @"phase": @(phase), @"direction": @(dir), @"dist": @(dist),
        @"tapDx": @(tapDx),
    }];
    cfg[@"learningSamples"] = samples;
    PTDylibWriteCfg(cfg);
    PTDylibLog(@"sample: sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d (总数%lu)",
        sCurSender, phase, dir, dist, tapDx, (unsigned long)samples.count);
    sLastSampleAt = PTNowC();
}

// ============================================================
// 工具（UI 层复用）
// ============================================================
NSArray *PTFeaturesOfPlan(NSDictionary *p) {
    if (p[@"features"]) return p[@"features"];
    if (p[@"feature"]) return @[p[@"feature"]];
    return @[];
}

NSString *PTDirName(double dir) {
    if (dir >= 45 && dir <= 135) return @"下";
    if (dir > 135 || dir < -135) return @"左";
    if (dir >= -135 && dir < -45) return @"上";
    return @"右";
}

NSString *PTActionText(NSDictionary *a) {
    NSString *t = a[@"type"];
    if ([t isEqualToString:@"tap"]) return [NSString stringWithFormat:@"点击(%d, %d)", (int)[a[@"x"] doubleValue], (int)[a[@"y"] doubleValue]];
    if ([t isEqualToString:@"doubleTap"]) return [NSString stringWithFormat:@"双击(%d, %d)", (int)[a[@"x"] doubleValue], (int)[a[@"y"] doubleValue]];
    if ([t isEqualToString:@"swipe"]) return [NSString stringWithFormat:@"滑动 (%d,%d)→(%d,%d)", (int)[a[@"x1"] doubleValue], (int)[a[@"y1"] doubleValue], (int)[a[@"x2"] doubleValue], (int)[a[@"y2"] doubleValue]];
    if ([t isEqualToString:@"recSwipe"]) return [NSString stringWithFormat:@"滑动(手动) %lu点", (unsigned long)[a[@"pts"] count]];   // v1.0.8
    if ([t isEqualToString:@"tapManual"]) {   // v1.0.12
        NSArray *pts = a[@"pts"];
        return pts.count ? [NSString stringWithFormat:@"点击(手动)(%d, %d)", (int)[pts[0][@"x"] doubleValue], (int)[pts[0][@"y"] doubleValue]] : @"点击(手动)";
    }
    if ([t isEqualToString:@"doubleTapManual"]) {   // v1.0.12
        NSArray *pts = a[@"pts"];
        if (pts.count >= 2) return [NSString stringWithFormat:@"双击(手动)(%d, %d)+(%d, %d)",
            (int)[pts[0][@"x"] doubleValue], (int)[pts[0][@"y"] doubleValue],
            (int)[pts[1][@"x"] doubleValue], (int)[pts[1][@"y"] doubleValue]];
        return [NSString stringWithFormat:@"双击(手动) %lu点", (unsigned long)pts.count];
    }
    if ([t isEqualToString:@"delay"]) return [NSString stringWithFormat:@"延迟 %.0fms", [a[@"ms"] doubleValue]];
    if ([t isEqualToString:@"volumeUp"] || [t isEqualToString:@"volumeDown"] || [t isEqualToString:@"muteToggle"])
        return [NSString stringWithFormat:@"%@（已移除）", t];   // v1.0.5：音量动作已删除，旧配置显示提示
    return t;
}

NSString *PTDuplicate(NSDictionary *s, NSArray *plans) {
    NSString *snd = s[@"sender"];
    int phase = [s[@"phase"] intValue];
    double dir = [s[@"direction"] doubleValue];
    double dist = [s[@"dist"] doubleValue];
    int tapDx = [s[@"tapDx"] intValue];
    for (NSDictionary *p in plans) {
        for (NSDictionary *ft in PTFeaturesOfPlan(p)) {
            if (![ft[@"sender"] isEqualToString:snd]) continue;
            if ([ft[@"phase"] intValue] != phase) continue;
            double pd = [ft[@"direction"] doubleValue];
            double d = fabs(fabs(dir - pd)); if (d > 180) d = 360 - d;
            if (d > kDirTolerance) continue;
            if (phase == 1) {
                double lo = [ft[@"distMin"] doubleValue], hi = [ft[@"distMax"] doubleValue];
                if (dist < lo - kDistSlack || dist > hi + kDistSlack) continue;
            } else {
                if (ft[@"tapDx"] && tapDx != [ft[@"tapDx"] intValue]) continue;
                if (ft[@"distMin"]) {
                    double lo = [ft[@"distMin"] doubleValue], hi = [ft[@"distMax"] doubleValue];
                    if (dist < lo - kTapDistSlack || dist > hi + kTapDistSlack) continue;
                }
            }
            return p[@"name"];
        }
    }
    return nil;
}

BOOL PTStable(NSArray *mem, NSString *sender) {
    NSMutableArray *same = [NSMutableArray array];
    for (NSDictionary *s in mem) if ([s[@"sender"] isEqualToString:sender]) [same addObject:s];
    if (same.count < kLearnMin) return NO;
    NSInteger n = same.count;
    double dir = [same[n-1][@"direction"] doubleValue];
    for (NSInteger i = n - kLearnMin; i < n; i++) {
        double d = [same[i][@"direction"] doubleValue];
        double diff = fabs(fabs(dir - d)); if (diff > 180) diff = 360 - diff;
        if (diff > kDirTolerance) return NO;
    }
    if ([same[n-1][@"phase"] intValue] == 1) {
        double lo = DBL_MAX, hi = 0;
        for (NSInteger i = n - kLearnMin; i < n; i++) {
            double v = [same[i][@"dist"] doubleValue];
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
        if (hi - lo > kConverge) return NO;
    }
    return YES;
}

// ============================================================
// 测试模式（大白屏 + 绿点可视化 + 执行链路验证）
// ============================================================
static NSString *PTTestMatchFeature(int phase, double dir, double dist, uint64_t sender, int tapDx) {
    NSString *best = nil; double bestScore = DBL_MAX;
    for (NSDictionary *p in (PTDylibReadCfg()[@"plans"] ?: @[])) {
        for (NSDictionary *ft in PTFeaturesOfPlan(p)) {
            if (ft[@"sender"]) {
                unsigned long long s = 0;
                NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
                if (![sc scanHexLongLong:&s] || s != sender) continue;
            }
            if ([ft[@"phase"] intValue] != phase) continue;
            double pd = [ft[@"direction"] doubleValue];
            double d = fabs(fabs(dir - pd)); if (d > 180) d = 360 - d;
            if (d > 15.0) continue;
            double lo = 0, hi = 0;
            if (phase == 1) {
                lo = [ft[@"distMin"] doubleValue];
                hi = [ft[@"distMax"] doubleValue];
                if (dist < lo - 30.0 || dist > hi + 30.0) continue;
            } else {
                if (ft[@"tapDx"]) {
                    if (tapDx != [ft[@"tapDx"] intValue]) continue;
                }
                if (ft[@"distMin"]) {
                    lo = [ft[@"distMin"] doubleValue];
                    hi = [ft[@"distMax"] doubleValue];
                    if (dist < lo - kTapDistSlack || dist > hi + kTapDistSlack) continue;
                }
            }
            double score = d + (phase == 1 ? fabs(dist - (lo + hi) / 2.0) / 100.0 : 0);
            if (score < bestScore) { bestScore = score; best = p[@"name"]; }
        }
    }
    return best;
}

void PTTestShowDot(CGPoint from, CGPoint to, BOOL animate, double dur) {
    if (!sTestDot) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        sTestDot.hidden = NO;
        sTestDot.alpha = 0.9;
        sTestDot.center = from;
        if (animate) {
            [UIView animateWithDuration:dur animations:^{ sTestDot.center = to; }
                completion:^(BOOL f) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        sTestDot.alpha = 0; sTestDot.hidden = YES;
                    });
                }];
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                sTestDot.alpha = 0; sTestDot.hidden = YES;
            });
        }
    });
}

static void PTTestTap(CGPoint p, BOOL doubleTap) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) return;
    PTTestShowDot(p, p, NO, 0);
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
    usleep(30000);
    [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseEnded];
    if (doubleTap) {
        usleep(120000);
        PTTestShowDot(p, p, NO, 0);
        NSInteger pid2 = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
        usleep(30000);
        [PTFakeMetaTouch fakeTouchId:pid2 AtPoint:p withTouchPhase:UITouchPhaseEnded];
    }
}

// v1.0.5（与 deb v1.0.48 同步）：音量动作类型（音量+/音量-/静音切换）整体删除——
// 第三方 App 进程无激活音频会话时，系统音量读取接口（AVSystemController get /
// AVAudioSession.outputVolume / MPVolumeView slider 同步读）全部返回假值（四版实测），
// 写也只能靠异步 slider 兜底 → 止损删除。旧配置兼容：已保存映射里的音量动作执行时
// 被 PTRunAction/PTTestRunAction 默认分支跳过（不崩溃）。

// 执行单条动作 → 完成后 next()
static void PTTestRunAction(NSDictionary *a, void (^next)(void)) {
    NSString *type = a[@"type"];
    if ([type isEqualToString:@"tap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        PTTestTap(p, NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"doubleTap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        PTTestTap(p, YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"swipe"]) {
        CGPoint from = CGPointMake([a[@"x1"] doubleValue], [a[@"y1"] doubleValue]);
        CGPoint to = CGPointMake([a[@"x2"] doubleValue], [a[@"y2"] doubleValue]);
        double speed = [a[@"speed"] doubleValue] ?: 1000;
        double distT = hypot(to.x - from.x, to.y - from.y);
        double durMs = (distT / MAX(speed, 1.0)) * 1000.0;
        if (durMs < 50) durMs = 50;
        int holdMs = [a[@"holdMs"] intValue] ?: 20;
        int liftMs = [a[@"liftMs"] intValue] ?: 0;
        BOOL noInertia = a[@"noInertia"] ? [a[@"noInertia"] boolValue] : YES;
        PTTestShowDot(from, to, YES, durMs / 1000.0);
        double durSec = MAX(durMs / 1000.0, 0.001);
        __block NSInteger pid = -1;
        __block void (^stillAt)(CGPoint, int);
        stillAt = ^(CGPoint pos, int ms) {
            __block int n = MAX(ms, 0) / 16;
            __block void (^still)(void);
            still = ^(void) {
                if (n <= 0) {
                    [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseEnded];
                    if (next) next();
                    return;
                }
                n--;
                [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseMoved];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), still);
            };
            still();
        };
        __block CFAbsoluteTime t0;
        __block void (^step)(void);
        step = ^(void) {
            double t = MIN((CFAbsoluteTimeGetCurrent() - t0) / durSec, 1.0);
            if (t >= 1.0) {
                if (noInertia) {
                    stillAt(to, MAX(liftMs, 300));
                } else {
                    if (liftMs > 0) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(liftMs * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                            [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
                            if (next) next();
                        });
                    } else {
                        [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
                        if (next) next();
                    }
                }
                return;
            }
            CGPoint pp = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:pp withTouchPhase:UITouchPhaseMoved];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), step);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
            pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((holdMs + 20) * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                t0 = CFAbsoluteTimeGetCurrent();
                step();
            });
        });
    } else if ([type isEqualToString:@"delay"]) {
        double ms = [a[@"ms"] doubleValue] ?: 100;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"recSwipe"]) {
        // v1.0.13：测试区支持滑动(手动)回放——此前缺分支被 else 跳过，注入轨迹看不到
        // v1.0.20：补上测试页轨迹可视化——绿点沿录制起点→终点移动，时长对齐录制耗时，
        // 否则测试本方案里滑动(手动)虽正常注入、却看不到轨迹（与「滑动」类型表现一致）。
        NSArray *pts = a[@"pts"];
        if (pts.count) {
            CGPoint from = CGPointMake([pts[0][@"x"] doubleValue], [pts[0][@"y"] doubleValue]);
            CGPoint to = CGPointMake([pts[pts.count - 1][@"x"] doubleValue], [pts[pts.count - 1][@"y"] doubleValue]);
            double t0 = [pts[0][@"t"] doubleValue];
            double t1 = [pts[pts.count - 1][@"t"] doubleValue];
            PTTestShowDot(from, to, YES, MAX(t1 - t0, 50) / 1000.0);
        }
        PTFakeRecSwipeAsync(pts, gExecToken, next);
    } else if ([type isEqualToString:@"tapManual"]) {
        NSArray *pts = a[@"pts"];
        CGPoint p = pts.count ? CGPointMake([pts[0][@"x"] doubleValue], [pts[0][@"y"] doubleValue]) : CGPointMake(200, 400);
        PTTestTap(p, NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"doubleTapManual"]) {
        NSArray *pts = a[@"pts"];
        CGPoint p0 = pts.count >= 1 ? CGPointMake([pts[0][@"x"] doubleValue], [pts[0][@"y"] doubleValue]) : CGPointMake(200, 400);
        CGPoint p1 = pts.count >= 2 ? CGPointMake([pts[1][@"x"] doubleValue], [pts[1][@"y"] doubleValue]) : p0;
        double gapMs = (pts.count >= 2) ? ([pts[1][@"t"] doubleValue] - [pts[0][@"t"] doubleValue]) : 120.0;
        if (gapMs < 40) gapMs = 40;
        PTTestTap(p0, NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gapMs / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            PTTestTap(p1, NO);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
        });
    } else {
        // v1.0.5：音量+/音量-/静音切换已删除，旧配置里的这些动作在此跳过
        if (next) next();
    }
}

// 顺序执行方案动作序列（测试防抖 300ms；执行中同样忽略）
static void PTTestExecPlan(NSString *name) {
    double now = PTNowC();
    if (sTestInjecting || now - sLastTestExec < 0.3) { PTDylibLog(@"[测试] 防抖：忽略 %@", name); return; }
    sLastTestExec = now;
    NSDictionary *plan = nil;
    for (NSDictionary *p in PTDylibReadCfg()[@"plans"] ?: @[]) if ([p[@"name"] isEqualToString:name]) { plan = p; break; }
    if (!plan) return;
    NSArray *actions = plan[@"actions"] ?: @[];
    if (!actions.count) { PTDylibLog(@"[测试] %@ 无动作，跳过", name); return; }
    PTDylibLog(@"[测试] 命中「%@」，执行 %lu 条动作", name, (unsigned long)actions.count);
    sTestInjecting = YES;
    __block int idx = 0;
    __block void (^runNext)(void);
    runNext = ^(void) {
        if (idx >= (int)actions.count) { sTestInjecting = NO; PTDylibLog(@"[测试] %@ 序列完成", name); return; }
        NSDictionary *a = actions[idx++];
        PTTestRunAction(a, runNext);
    };
    runNext();
}

// 测试模式：Ended 结算 → 匹配 → 执行
void PTTestOnEnded(int phase, double dir, double dist, uint64_t sender, int tapDx) {
    NSString *plan = PTTestMatchFeature(phase, dir, dist, sender, tapDx);
    if (plan) {
        PTDylibLog(@"[测试] 特征匹配 → 方案「%@」", plan);
        PTTestExecPlan(plan);
        NSDictionary *pp = nil;
        for (NSDictionary *p in PTDylibReadCfg()[@"plans"] ?: @[]) if ([p[@"name"] isEqualToString:plan]) { pp = p; break; }
        if ([sTestLogSink respondsToSelector:@selector(appendLog:)]) {
            [sTestLogSink appendLog:[NSString stringWithFormat:@"✓ 命中「%@」→ 映射 %lu 条动作（sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d）",
                plan, (unsigned long)(pp[@"actions"] ? [pp[@"actions"] count] : 0), sender, phase, dir, dist, tapDx]];
        }
    } else {
        PTDylibLog(@"[测试] 未匹配：sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d", sender, phase, dir, dist, tapDx);
        if ([sTestLogSink respondsToSelector:@selector(appendLog:)]) {
            [sTestLogSink appendLog:[NSString stringWithFormat:@"✗ 未命中（放行）：sender=0x%llx phase=%d dir=%.1f dist=%.1f tapDx=%d",
                sender, phase, dir, dist, tapDx]];
        }
        if ([sTestLogSink respondsToSelector:@selector(drawTrailWithDirection:dist:phase:)]) {
            [sTestLogSink drawTrailWithDirection:dir dist:dist phase:phase];
        }
    }
}

// ============================================================
// 特征结构 + 触摸会话（运行拦截）
// ============================================================
typedef struct {
    int phase;        // 0=tap 1=swipe
    double direction;
    double dist;
    int tapDx;
} PagerFeature;

static void PTExecutePlan(NSString *name);
static NSString *PTMatchPlan(PagerFeature f, uint64_t sender);

typedef struct {
    BOOL active;
    int nEvents;
    CGPoint start, last;
    double totalDist;
    double firstMoveDir;
    BOOL hasMove;
} PagerSession;
static PagerSession gSession;
static NSMutableArray *gSessTrail = nil;

static uint64_t gCurSender = 0;
static double gPagerWindowUntil = 0;

static BOOL PTIsLearnedSender(uint64_t s) {
    for (int i = 0; i < gLearnedSenderCount; i++) if (gLearnedSenders[i] == s) return YES;
    return NO;
}

static void PTReplayTrailAsync(void);

// 匹配：sender + 相位 + 方向±15° + 位移区间 → 唯一方案
static NSString *PTMatchPlan(PagerFeature f, uint64_t sender) {
    NSString *best = nil;
    double bestScore = DBL_MAX;
    for (NSString *name in gPlans) {
        NSDictionary *p = gPlans[name];
        NSArray *fts = p[@"features"] ?: (p[@"feature"] ? @[p[@"feature"]] : @[]);
        for (NSDictionary *ft in fts) {
            if (ft[@"sender"]) {
                unsigned long long s = 0;
                NSScanner *sc = [NSScanner scannerWithString:ft[@"sender"]];
                if (![sc scanHexLongLong:&s] || s != sender) continue;
            }
            if ([ft[@"phase"] intValue] != f.phase) continue;
            double pd = [ft[@"direction"] doubleValue];
            double d = fabs(fabs(f.direction - pd)); if (d > 180) d = 360 - d;
            if (d > kDirTolerance) continue;
            double lo = 0, hi = 0;
            if (f.phase == 1) {
                lo = [ft[@"distMin"] doubleValue];
                hi = [ft[@"distMax"] doubleValue];
                if (f.dist < lo - kDistSlack || f.dist > hi + kDistSlack) continue;
            } else {
                if (ft[@"tapDx"]) {
                    if (f.tapDx != [ft[@"tapDx"] intValue]) continue;
                }
                if (ft[@"distMin"]) {
                    lo = [ft[@"distMin"] doubleValue];
                    hi = [ft[@"distMax"] doubleValue];
                    if (f.dist < lo - kTapDistSlack || f.dist > hi + kTapDistSlack) continue;
                }
            }
            double score = d + (f.phase == 1 ? fabs(f.dist - (lo + hi) / 2.0) / 100.0 : 0);
            if (score < bestScore) { bestScore = score; best = name; }
        }
    }
    return best;
}

// 返回 YES = 吞（命中：防 App 同时收到翻页器滚动）；NO = 放行
static BOOL PTHandlePagerEvent(UIEvent *event) {
    if (![event respondsToSelector:@selector(allTouches)]) return NO;
    if (!PTIsLearnedSender(gCurSender)) return NO;
    NSSet *touches = event.allTouches;
    if (!touches.count) return NO;
    UITouch *t = [touches anyObject];
    CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
    switch (t.phase) {
        case UITouchPhaseBegan: {
            gSession.active = YES;
            gSession.nEvents = 0;
            gSession.start = p;
            gSession.last = p;
            gSession.totalDist = 0;
            gSession.hasMove = NO;
            gSession.firstMoveDir = 0;
            gSessTrail = [NSMutableArray arrayWithObject:[NSValue valueWithCGPoint:p]];
            return YES;
        }
        case UITouchPhaseMoved: {
            if (!gSession.active) return NO;
            gSession.nEvents++;
            double dx = p.x - gSession.last.x, dy = p.y - gSession.last.y;
            double seg = hypot(dx, dy);
            if (seg > 0) {
                gSession.totalDist += seg;
                if (!gSession.hasMove && gSession.totalDist > 5) {
                    gSession.hasMove = YES;
                    gSession.firstMoveDir = atan2(dy, dx) * 180.0 / M_PI;
                }
            }
            gSession.last = p;
            if (gSessTrail && gSessTrail.count < 64) [gSessTrail addObject:[NSValue valueWithCGPoint:p]];
            return YES;
        }
        case UITouchPhaseEnded: {
            if (!gSession.active) return NO;
            gSession.active = NO;
            if (gSessTrail && gSessTrail.count < 64) [gSessTrail addObject:[NSValue valueWithCGPoint:p]];
            PagerFeature f;
            f.phase = (gSession.totalDist < kTapDistThreshold) ? 0 : 1;
            f.direction = gSession.hasMove ? gSession.firstMoveDir : 0;
            f.dist = gSession.totalDist;
            {
                double sx = gSession.start.x, ex = p.x;
                double dxv = ex - sx;
                f.tapDx = (dxv > kTapDxThresh) ? 1 : (dxv < -kTapDxThresh ? -1 : 0);
            }
            NSString *plan = PTMatchPlan(f, gCurSender);
            if (plan) {
                gSessTrail = nil;
                PTDylibLog(@"[会话] 命中「%@」→ 执行映射（原始滑动已整段吞掉）", plan);
                PTExecutePlan(plan);
                return YES;
            }
            PTDylibLog(@"[会话] 未命中：sender=0x%llx phase=%d dir=%.1f dist=%.1f → 重放轨迹放行",
                gCurSender, f.phase, f.direction, f.dist);
            PTReplayTrailAsync();
            return YES;
        }
        case UITouchPhaseCancelled:
            gSession.active = NO;
            gSessTrail = nil;
            return NO;
        default:
            return NO;
    }
}

// ============================================================
// 调试可视化（绿点 + 轨迹；只画 App 实际收到的触摸）
// ============================================================
@interface PTDebugDot : NSObject
@property (nonatomic) CGPoint pos;
@property (nonatomic) BOOL pager;
@property (nonatomic, strong) UIView *dotView;
@property (nonatomic, strong) CAShapeLayer *trailLayer;
@property (nonatomic, strong) NSMutableArray *trail;
@end
@implementation PTDebugDot
- (instancetype)initWithPoint:(CGPoint)p pager:(BOOL)pg parentView:(UIView *)pv {
    self = [super init];
    if (self) {
        _pos = p; _pager = pg;
        _trail = [NSMutableArray array];
        [_trail addObject:[NSValue valueWithCGPoint:p]];
        _dotView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        _dotView.center = p;
        _dotView.layer.cornerRadius = 22;
        _dotView.layer.borderWidth = 2;
        _dotView.layer.borderColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.8].CGColor;
        _dotView.backgroundColor = [UIColor colorWithRed:0.2 green:0.95 blue:0.3 alpha:0.85];
        if (pg) {
            UILabel *lb = [[UILabel alloc] initWithFrame:_dotView.bounds];
            lb.text = @"P";
            lb.font = [UIFont boldSystemFontOfSize:20];
            lb.textColor = [UIColor blackColor];
            lb.textAlignment = NSTextAlignmentCenter;
            [_dotView addSubview:lb];
        }
        _trailLayer = [CAShapeLayer layer];
        _trailLayer.strokeColor = [UIColor colorWithRed:0.2 green:0.95 blue:0.3 alpha:0.7].CGColor;
        _trailLayer.fillColor = [UIColor clearColor].CGColor;
        _trailLayer.lineWidth = 4;
        _trailLayer.lineCap = kCALineCapRound;
        [pv.layer addSublayer:_trailLayer];
        [pv addSubview:_dotView];
    }
    return self;
}
- (void)moveTo:(CGPoint)p {
    _pos = p;
    _dotView.center = p;
    [_trail addObject:[NSValue valueWithCGPoint:p]];
    if (_trail.count > 80) [_trail removeObjectAtIndex:0];
    CGMutablePathRef path = CGPathCreateMutable();
    BOOL first = YES;
    for (NSValue *v in _trail) {
        CGPoint q = v.CGPointValue;
        if (first) { CGPathMoveToPoint(path, NULL, q.x, q.y); first = NO; }
        else CGPathAddLineToPoint(path, NULL, q.x, q.y);
    }
    _trailLayer.path = path;
    CGPathRelease(path);
}
- (void)fadeOut {
    [_dotView.layer removeAllAnimations];
    [UIView animateWithDuration:0.5 animations:^{
        _dotView.alpha = 0.15;
    } completion:^(BOOL f) {
        [_dotView removeFromSuperview];
    }];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.toValue = @(0.0);
    fade.duration = 0.5;
    fade.removedOnCompletion = NO;
    fade.fillMode = kCAFillModeForwards;
    [_trailLayer addAnimation:fade forKey:@"fade"];
}
@end

static UIView *gDotOverlay = nil;   // v1.0.12：可视化改为 keyWindow 上的覆盖层 view（不建独立窗口）
static NSMutableDictionary *gDotViews = nil;

// v1.0.12：可视化不再用独立 UIWindow——独立窗口存在就会参与系统状态栏样式计算
// （时间/信号电量变白根因）。改为直接叠加在当前 keyWindow 上的透明 view，
// 零窗口参与状态栏判定，状态栏彻底归系统/App 管。keyWindow 变化时由通知迁移。
static void PTDebugEnsureOverlay(void) {
    if (gDotOverlay) return;
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (!kw) return;
    UIView *ov = [[UIView alloc] initWithFrame:kw.bounds];
    ov.userInteractionEnabled = NO;
    ov.backgroundColor = [UIColor clearColor];
    [kw addSubview:ov];
    gDotOverlay = ov;
    gDotViews = [NSMutableDictionary dictionary];
}

// v1.0.7：可视化开关关掉时销毁（不再永驻影响状态栏）
static void PTDebugDestroyOverlay(void) {
    [gDotOverlay removeFromSuperview];
    gDotOverlay = nil;
    gDotViews = nil;
}

// v1.0.12：keyWindow 变化时把覆盖层迁到新窗口（旧覆盖层移除重建）
void PTDebugMigrateOverlay(void) {
    if (!gDotOverlay) return;
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (!kw) return;
    if (gDotOverlay.superview == kw) return;
    PTDebugDestroyOverlay();
    PTDebugEnsureOverlay();
}

static void PTDebugUpdate(void *touchPtr, CGPoint p, UITouchPhase phase, BOOL pager) {
    if (!gDebugDots) return;
    if (![NSThread isMainThread]) return;
    PTDebugEnsureOverlay();
    if (!gDotOverlay) return;
    NSString *key = [NSString stringWithFormat:@"%p", touchPtr];
    PTDebugDot *dot = gDotViews[key];
    if (phase == UITouchPhaseBegan) {
        if (dot) return;
        dot = [[PTDebugDot alloc] initWithPoint:p pager:pager parentView:gDotOverlay];
        gDotViews[key] = dot;
    } else if (phase == UITouchPhaseMoved) {
        if (dot) [dot moveTo:p];
    } else if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        if (dot) {
            [dot moveTo:p];
            [dot fadeOut];
            [gDotViews removeObjectForKey:key];
        }
    }
}

// ============================================================
// 动作执行（PTFakeMetaTouch ＋ 延迟；v1.0.5 音量动作已删除）
// ============================================================
static BOOL gIsInjecting = NO;
static BOOL gExecRunning = NO;
static BOOL gInFakeTouch = NO;
static int gExecToken = 0;
static double gLastExec = 0;

// v1.0.8：手动滑动录制（滑动(手动)动作）——录手指真实轨迹，回放按轨迹注入
// v1.0.12：支持 点击(手动)/双击(手动)——录真实点击坐标+时间戳
static BOOL gRecArmed = NO;                 // 录制覆盖层打开
static NSString *gRecMode = nil;            // recSwipe / tapManual / doubleTapManual
static double gRecTopY = 0;                 // 录制区上边界（完成按钮行往下，窗口坐标）
static NSMutableArray *gRecPts = nil;       // 当前轨迹点 @{x,y,t(相对起点毫秒)}
static double gRecT0 = 0;
static BOOL gRecActive = NO;                // 正在录一次触摸序列
static int gRecTaps = 0;                    // doubleTapManual 已录点击次数
static void (^gRecDone)(NSArray *) = nil;

void PTRecStart(NSString *mode, double topY, void (^done)(NSArray *pts)) {
    gRecMode = mode ?: @"recSwipe";
    gRecTopY = topY;
    gRecDone = done;
    gRecPts = nil;
    gRecActive = NO;
    gRecTaps = 0;
    gRecArmed = YES;
}

void PTRecStop(void) {
    gRecArmed = NO;
    gRecActive = NO;
    gRecTaps = 0;
    gRecPts = nil;
    gRecDone = nil;
    gRecMode = nil;
}

// v1.0.10：录制页实时画轨迹用（主线程调用，返回当前轨迹副本）
NSArray *PTRecCurrentPoints(void) {
    if (!gRecArmed || !gRecPts) return nil;
    return [NSArray arrayWithArray:gRecPts];
}

// v1.0.12：点击/双击录制完成判定（tapManual=1 次点击，doubleTapManual=2 次）
static void PTRecFinishIfDone(void) {
    if (!gRecArmed || !gRecActive || !gRecPts) return;
    int need = [gRecMode isEqualToString:@"doubleTapManual"] ? 2 : 1;
    if (gRecTaps >= need) {
        gRecActive = NO;
        NSArray *pts = gRecPts;
        gRecPts = nil;
        if (gRecDone) { gRecDone(pts); }
    }
}

// 未命中：暂存轨迹重放给 App
static void PTReplayTrailAsync(void) {
    if (!gSessTrail || gSessTrail.count < 2) { gSessTrail = nil; return; }
    NSArray *pts = [gSessTrail copy];
    gSessTrail = nil;
    NSUInteger n = pts.count;
    // v1.0.18：回放「未命中」的原始轨迹时必须保持足够点密度，否则 UIScrollView 在
    // 两点之间收不到 Moved 事件而阶梯跳变（卡顿）。原先 k = MIN(n - 2, 10) 把轨迹
    // 砍到最多 10 个中间点 —— 这里改为全量回放原始采样点，密度跟随录制轨迹。
    CGPoint from = [pts.firstObject CGPointValue];
    CGPoint to = [pts.lastObject CGPointValue];
    NSMutableArray *mids = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 1; i < n - 1; i++) [mids addObject:pts[i]];

    gIsInjecting = YES;
    gInFakeTouch = YES;
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
    gInFakeTouch = NO;
    // v1.0.18：按屏幕刷新节奏（~60Hz，16.6ms/点）逐点推进，密度接近真实手指，
    // 不再把整段滑动压缩进 ~120ms。宗旨不变：未命中时仍把原始轨迹还原给 App。
    static const double kReplayStepSec = 1.0 / 60.0;
    __block NSUInteger i = 0;
    __block void (^step)(void);
    step = ^(void) {
        if (i >= mids.count) {
            gInFakeTouch = YES;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:to withTouchPhase:UITouchPhaseEnded];
            gInFakeTouch = NO;
            gIsInjecting = NO;
            PTDylibLog(@"[重放] 未命中：原始轨迹已重放给 App（%lu 点）", (unsigned long)mids.count);
            return;
        }
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:[mids[i] CGPointValue] withTouchPhase:UITouchPhaseMoved];
        gInFakeTouch = NO;
        i++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReplayStepSec * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReplayStepSec * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
}

// 点击（同步短阻塞）
static void PTFakeTap(CGPoint p, int pressMs) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) return;
    gInFakeTouch = YES;
    NSInteger pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:UITouchPhaseBegan];
    gInFakeTouch = NO;
    usleep(pressMs * 1000);
    gInFakeTouch = YES;
    [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseEnded];
    gInFakeTouch = NO;
}

// 滑动（异步分步；holdMs 按下停留，liftMs 弹起停留，noInertia 防惯性）
static void PTFakeSwipeAsync(CGPoint from, CGPoint to, double durationMs, int holdMs, int liftMs, BOOL noInertia, int token, void (^done)(void)) {
    double durSec = MAX(durationMs / 1000.0, 0.001);
    __block NSInteger pid = -1;
    __block BOOL began = NO;
    __block BOOL ended = NO;
    __block CGPoint lastP = from;
    __block void (^abortEnd)(void);
    __block void (^doEnd)(void);
    abortEnd = ^{
        if (ended) return;
        ended = YES;
        if (!began) { if (done) done(); return; }
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:lastP withTouchPhase:UITouchPhaseEnded];
        gInFakeTouch = NO;
    };
    doEnd = ^{
        if (ended) { if (done) done(); return; }
        ended = YES;
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:lastP withTouchPhase:UITouchPhaseEnded];
        gInFakeTouch = NO;
        if (done) done();
    };
    __block void (^stillAt)(CGPoint, int);
    stillAt = ^(CGPoint pos, int ms) {
        __block int n = MAX(ms, 0) / 16;
        __block void (^still)(void);
        still = ^(void) {
            if (token != gExecToken) { abortEnd(); if (done) done(); return; }
            if (n <= 0) { doEnd(); return; }
            n--;
            lastP = pos;
            gInFakeTouch = YES;
            [PTFakeMetaTouch fakeTouchId:pid AtPoint:pos withTouchPhase:UITouchPhaseMoved];
            gInFakeTouch = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), still);
        };
        still();
    };
    __block CFAbsoluteTime t0;
    __block void (^step)(void);
    step = ^(void) {
        if (token != gExecToken) { abortEnd(); if (done) done(); return; }
        double t = MIN((CFAbsoluteTimeGetCurrent() - t0) / durSec, 1.0);
        if (t >= 1.0) {
            if (noInertia) {
                stillAt(to, MAX(liftMs, 300));
            } else {
                if (liftMs > 0) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(liftMs * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
                        if (token != gExecToken) { abortEnd(); if (done) done(); return; }
                        doEnd();
                    });
                } else {
                    doEnd();
                }
            }
            return;
        }
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
        lastP = p;
        gInFakeTouch = YES;
        [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:UITouchPhaseMoved];
        gInFakeTouch = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), step);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
        if (token != gExecToken) { if (done) done(); return; }
        began = YES;
        gInFakeTouch = YES;
        pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:from withTouchPhase:UITouchPhaseBegan];
        gInFakeTouch = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((holdMs + 20) * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
            t0 = CFAbsoluteTimeGetCurrent();
            step();
        });
    });
}

// v1.0.8：手动滑动回放——按录制轨迹逐点注入（保持录制时间间隔，最短 8ms 防风暴）
static void PTFakeRecSwipeAsync(NSArray *pts, int token, void (^done)(void)) {
    if (!pts.count) { if (done) done(); return; }
    __block NSInteger pid = -1;
    __block int idx = 0;
    __block void (^step)(void);
    step = ^(void) {
        if (token != gExecToken) { if (done) done(); return; }
        if (idx >= (int)pts.count) { if (done) done(); return; }
        NSDictionary *pt = pts[idx];
        CGPoint p = CGPointMake([pt[@"x"] doubleValue], [pt[@"y"] doubleValue]);
        UITouchPhase ph = (idx == 0) ? UITouchPhaseBegan
                        : ((idx == (int)pts.count - 1) ? UITouchPhaseEnded : UITouchPhaseMoved);
        gInFakeTouch = YES;
        if (idx == 0) pid = [PTFakeMetaTouch fakeTouchId:1 AtPoint:p withTouchPhase:ph];
        else [PTFakeMetaTouch fakeTouchId:pid AtPoint:p withTouchPhase:ph];
        gInFakeTouch = NO;
        idx++;
        if (idx >= (int)pts.count) { if (done) done(); return; }
        double waitMs = [pts[idx][@"t"] doubleValue] - [pt[@"t"] doubleValue];
        if (waitMs < 8) waitMs = 8;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitMs * NSEC_PER_SEC / 1000)),
                       dispatch_get_main_queue(), step);
    };
    step();
}

// 执行单条动作 → 完成后 next()
static void PTRunAction(NSDictionary *a, int token, void (^next)(void)) {
    NSString *type = a[@"type"];
    if ([type isEqualToString:@"tap"]) {
        int pressMs = [a[@"pressMs"] intValue] ?: 30;
        PTFakeTap(CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]), pressMs);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"doubleTap"]) {
        CGPoint p = CGPointMake([a[@"x"] doubleValue], [a[@"y"] doubleValue]);
        int pressMs = [a[@"pressMs"] intValue] ?: 30;
        int gapMs = [a[@"gapMs"] intValue] ?: 120;
        PTFakeTap(p, pressMs);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gapMs * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
            if (token != gExecToken) { if (next) next(); return; }
            PTFakeTap(p, pressMs);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
        });
    } else if ([type isEqualToString:@"swipe"]) {
        CGPoint from = CGPointMake([a[@"x1"] doubleValue], [a[@"y1"] doubleValue]);
        CGPoint to = CGPointMake([a[@"x2"] doubleValue], [a[@"y2"] doubleValue]);
        double speed = [a[@"speed"] doubleValue] ?: 1000;
        int holdMs = [a[@"holdMs"] intValue] ?: 20;
        int liftMs = [a[@"liftMs"] intValue] ?: 0;
        BOOL noInertia = a[@"noInertia"] ? [a[@"noInertia"] boolValue] : YES;
        double dist = hypot(to.x - from.x, to.y - from.y);
        double durMs = (dist / MAX(speed, 1.0)) * 1000.0;
        if (durMs < 50) durMs = 50;
        PTFakeSwipeAsync(from, to, durMs, holdMs, liftMs, noInertia, token, next);
    } else if ([type isEqualToString:@"recSwipe"]) {
        // v1.0.8：滑动(手动)——按录制轨迹回放
        PTFakeRecSwipeAsync(a[@"pts"], token, next);
    } else if ([type isEqualToString:@"tapManual"]) {
        // v1.0.12：点击(手动)——按录制的真实点击点注入
        NSArray *pts = a[@"pts"];
        CGPoint p = pts.count ? CGPointMake([pts[0][@"x"] doubleValue], [pts[0][@"y"] doubleValue])
                              : CGPointMake(200, 400);
        PTFakeTap(p, 30);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else if ([type isEqualToString:@"doubleTapManual"]) {
        // v1.0.12：双击(手动)——两次点击，间隔按录制时间戳
        NSArray *pts = a[@"pts"];
        CGPoint p0 = pts.count >= 1 ? CGPointMake([pts[0][@"x"] doubleValue], [pts[0][@"y"] doubleValue]) : CGPointMake(200, 400);
        CGPoint p1 = pts.count >= 2 ? CGPointMake([pts[1][@"x"] doubleValue], [pts[1][@"y"] doubleValue]) : p0;
        double gapMs = (pts.count >= 2) ? ([pts[1][@"t"] doubleValue] - [pts[0][@"t"] doubleValue]) : 120.0;
        if (gapMs < 40) gapMs = 40;
        PTFakeTap(p0, 30);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gapMs / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token != gExecToken) { if (next) next(); return; }
            PTFakeTap(p1, 30);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
        });
    } else if ([type isEqualToString:@"delay"]) {
        double ms = [a[@"ms"] doubleValue] ?: 100;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    } else {
        // v1.0.5：音量+/音量-/静音切换已删除，旧配置里的这些动作在此跳过
        if (next) next();
    }
}

// 执行方案动作序列（防抖：序列执行中或距上次执行 < 防抖间隔都忽略）
static void PTExecutePlan(NSString *name) {
    double now = PTNowC();
    if (gExecRunning || (now - gLastExec < gDebounceMs / 1000.0)) {
        PTDylibLog(@"[执行] 防抖：忽略 %@（执行中=%d，%.0fms 内已执行）", name, gExecRunning, gDebounceMs);
        return;
    }
    gLastExec = now;
    NSDictionary *p = gPlans[name];
    NSArray *actions = p[@"actions"] ?: @[];
    if (!actions.count) { PTDylibLog(@"[执行] %@ 无动作，跳过", name); return; }
    gExecToken++;
    int token = gExecToken;
    gIsInjecting = YES;
    gExecRunning = YES;
    PTDylibLog(@"[执行] 命中 %@，开始动作序列（%lu 条）", name, (unsigned long)actions.count);
    __block int idx = 0;
    __block void (^runNext)(void);
    runNext = ^(void) {
        if (token != gExecToken) return;
        if (idx >= (int)actions.count) { gIsInjecting = NO; gExecRunning = NO; PTDylibLog(@"[执行] %@ 序列完成", name); return; }
        NSDictionary *a = actions[idx++];
        PTRunAction(a, token, runNext);
    };
    runNext();
}

// ============================================================
// 合并 hook（学习/测试采集 + 运行拦截，同一对方法）
// ============================================================
static IMP gOrigAddEvent = NULL;
static IMP gOrigSendEvent = NULL;

static void PTDylibAddEvent(id self, SEL _cmd, void *event) {
    PTDylibLoadConfig(NO);
    if (event && pGetSender && pGetType) {
        uint32_t type = pGetType(event);
        uint64_t sender = pGetSender(event);
        if (type == 11) {
            gCurSender = sender;      // 运行端
            sCurSender = sender;      // 采集端
            if (sCollectArmed || sTestArmed) sWindowUntil = PTNowC() + kCollectWindowSec;
            if (PTIsLearnedSender(sender)) {
                double dx = pGetFloat ? pGetFloat(event, 0x23) : 0;
                double dy = pGetFloat ? pGetFloat(event, 0x24) : 0;
                PTDylibLog(@"[addEvent] 已学 sender=0x%llx → 会话通道（HID 位移观察 dx=%.2f dy=%.2f）", sender, dx, dy);
                gPagerWindowUntil = PTNowC() + kPagerWindowSec;
            }
        }
    }
    if (gOrigAddEvent) ((void (*)(id, SEL, void *))gOrigAddEvent)(self, _cmd, event);
}

// v1.0.12：sendEvent 层双指长按检测——两指同时按下 0.5s 不动 → 弹菜单。
// sendEvent 是 App 所有触摸必经之路，任何页面/角落都能触发，不被 App 手势仲裁抢。
// 菜单窗口上的触摸不算；手指位移 >25pt 视为移动取消该指。
static NSMutableDictionary *gFingers = nil;
static BOOL gGestureFired = NO;

static void PTDylibGestureTick(UIEvent *event) {
    if (!event) return;
    if (gRecArmed || gInFakeTouch || gIsInjecting) return;   // v1.0.12：录制/注入中不触发双指
    if (!gFingers) gFingers = [NSMutableDictionary dictionary];
    for (UITouch *t in event.allTouches) {
        if (!t.window) continue;
        if (PTDylibIsMenuWindow(t.window)) continue;   // 菜单窗口上的触摸不参与
        NSString *key = [NSString stringWithFormat:@"%p", t];
        if (t.phase == UITouchPhaseBegan) {
            CGPoint p = [t locationInView:t.window];
            gFingers[key] = @{@"t": @(CACurrentMediaTime()), @"x": @(p.x), @"y": @(p.y)};
        } else if (t.phase == UITouchPhaseMoved) {
            NSDictionary *f = gFingers[key];
            if (f) {
                CGPoint p = [t locationInView:t.window];
                CGFloat dx = p.x - [f[@"x"] doubleValue], dy = p.y - [f[@"y"] doubleValue];
                if (dx * dx + dy * dy > 25.0 * 25.0) [gFingers removeObjectForKey:key];
            }
        } else if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) {
            [gFingers removeObjectForKey:key];
        }
    }
    if (gFingers.count >= 2 && !gGestureFired) {
        double now = CACurrentMediaTime();
        BOOL allHold = YES;
        for (NSDictionary *f in gFingers.allValues) {
            if (now - [f[@"t"] doubleValue] < 0.5) { allHold = NO; break; }
        }
        if (allHold) {
            gGestureFired = YES;
            PTDylibShowMenu();
        }
    } else if (gFingers.count == 0) {
        gGestureFired = NO;
    }
}

static void PTDylibSendEvent(id self, SEL _cmd, UIEvent *event) {
    PTDylibLoadConfig(NO);
    // v1.0.12：双指长按检测（最前面，任何触摸都能触发）
    PTDylibGestureTick(event);
    // v1.0.6：调试可视化先画点（与 deb 对齐——未命中重放/动作执行的注入触摸也画点；
    // 被拦截吞掉的翻页器原始轨迹仍不可见，v1.0.43 语义不变）
    if (gDebugDots && event) {
        for (UITouch *t in event.allTouches) {
            CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
            PTDebugUpdate((__bridge void *)t, p, t.phase, NO);
        }
    }
    // v1.0.8：手动滑动录制——手指在录制区（完成按钮行往下）内的真实轨迹，
    // Began 在录制区才算开始，抬起/超时 5s 结束回调（v1.0.12：按模式区分滑动/点击/双击）
    if (gRecArmed && event && !gInFakeTouch) {
        NSSet *touches = [event respondsToSelector:@selector(allTouches)] ? event.allTouches : nil;
        UITouch *t = [touches anyObject];
        if (t) {
            CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
            BOOL isTapMode = [gRecMode isEqualToString:@"tapManual"] || [gRecMode isEqualToString:@"doubleTapManual"];
            switch (t.phase) {
                case UITouchPhaseBegan: {
                    if (gRecActive) break;   // 已在录（多指）：忽略第二根
                    if (p.y >= gRecTopY) {
                        if (!gRecPts) {
                            gRecPts = [NSMutableArray array];
                            gRecT0 = CACurrentMediaTime();
                        }
                        gRecActive = YES;
                        if (isTapMode) {
                            // 点击/双击：记录按下点（一次点击一个点）
                            double tms = (CACurrentMediaTime() - gRecT0) * 1000.0;
                            [gRecPts addObject:@{@"x": @(p.x), @"y": @(p.y), @"t": @(tms)}];
                            gRecTaps++;
                            // 超时兜底：双指点击第二下一直不来 → 5s 完成
                            NSMutableArray *curPts = gRecPts;
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                if (gRecArmed && gRecActive && gRecPts == curPts) {
                                    gRecActive = NO;
                                    NSArray *pts = gRecPts;
                                    gRecPts = nil;
                                    gRecTaps = 0;
                                    if (gRecDone) { gRecDone(pts); }
                                }
                            });
                        } else {
                            // 滑动：记录起点
                            [gRecPts addObject:@{@"x": @(p.x), @"y": @(p.y), @"t": @(0)}];
                            NSMutableArray *curPts = gRecPts;
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                if (gRecActive && gRecPts == curPts) {   // 还是同一次滑动（用户按着不放）
                                    gRecActive = NO;
                                    NSArray *pts = gRecPts;
                                    gRecPts = nil;
                                    if (gRecDone) { gRecDone(pts); }   // v1.0.10：不置 nil——录制页生命周期内可多次重录，PTRecStop 统一清理
                                }
                            });
                        }
                    } else {
                        gRecActive = NO;   // 点在按钮行：不录
                    }
                    break;
                }
                case UITouchPhaseMoved: {
                    if (gRecActive && gRecPts && !isTapMode) {
                        double tms = (CACurrentMediaTime() - gRecT0) * 1000.0;
                        [gRecPts addObject:@{@"x": @(p.x), @"y": @(p.y), @"t": @(tms)}];
                    }
                    break;
                }
                case UITouchPhaseEnded:
                case UITouchPhaseCancelled: {
                    if (gRecActive && gRecPts) {
                        if (isTapMode) {
                            gRecActive = NO;   // 松开一次点击，等第二次（双击）
                            PTRecFinishIfDone();   // 点击完成一次，双击需两次
                        } else {
                            gRecActive = NO;
                            NSArray *pts = gRecPts;
                            gRecPts = nil;
                            if (gRecDone) { gRecDone(pts); }
                        }
                    }
                    break;
                }
                default: break;
            }
        }
    }
    // 注入触摸/执行中：放行（注入触摸没有 addEvent、sender 残留翻页器，走拦截会把映射触摸 Began 吞掉）
    if (gInFakeTouch || gIsInjecting || sTestInjecting) {
        if (gOrigSendEvent) ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
        return;
    }
    // 学习/测试激活：只采集放行，不拦截（即使按的是已学 sender 也不吞）
    if ((sCollectArmed || sTestArmed) && event && PTNowC() < sWindowUntil) {
        NSSet *touches = [event respondsToSelector:@selector(allTouches)] ? event.allTouches : nil;
        UITouch *t = [touches anyObject];
        if (t && pGetSender) {
            CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
            switch (t.phase) {
                case UITouchPhaseBegan: {
                    sSessActive = YES; sSessDist = 0; sSessHasMove = NO; sSessFirstDir = 0;
                    sSessLast = p;
                    sSessStart = p;
                    break;
                }
                case UITouchPhaseMoved: {
                    if (sSessActive) {
                        double dx = p.x - sSessLast.x, dy = p.y - sSessLast.y;
                        double seg = hypot(dx, dy);
                        if (seg > 0) {
                            sSessDist += seg;
                            if (!sSessHasMove && sSessDist > 5) {
                                sSessHasMove = YES;
                                sSessFirstDir = atan2(dy, dx) * 180.0 / M_PI;
                            }
                        }
                        sSessLast = p;
                    }
                    break;
                }
                case UITouchPhaseEnded: {
                    if (sSessActive) {
                        sSessActive = NO;
                        int phase = (sSessDist < kTapDistThreshold) ? 0 : 1;
                        double dir = sSessHasMove ? sSessFirstDir : 0;
                        int tapDx = 0;
                        {
                            double dxv = p.x - sSessStart.x;
                            tapDx = (dxv > kTapDxThresh) ? 1 : (dxv < -kTapDxThresh ? -1 : 0);
                        }
                        if (sTestArmed) PTTestOnEnded(phase, dir, sSessDist, sCurSender, tapDx);
                        else SAppendSample(phase, dir, sSessDist, tapDx);
                    }
                    break;
                }
                case UITouchPhaseCancelled: sSessActive = NO; break;
                default: break;
            }
        }
        if (gOrigSendEvent) ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
        return;
    }
    // 运行拦截：已学 sender 会话/窗口内 → 整段吞（命中执行/未命中重放），App 不收到原始触摸
    if (event && (PTNowC() < gPagerWindowUntil || gSession.active)) {
        if (PTHandlePagerEvent(event)) return;
    }
    // 诊断：非注入触摸会话 Began 打一行 sender
    if (event) {
        for (UITouch *t in event.allTouches) {
            if (t.phase == UITouchPhaseBegan) {
                CGPoint p = t.window ? [t locationInView:t.window] : [t locationInView:t.view];
                PTDylibLog(@"[touch] sender=0x%llx phase=Began pos=(%.1f,%.1f)", gCurSender, p.x, p.y);
            }
        }
    }
    if (gOrigSendEvent) ((void (*)(id, SEL, UIEvent *))gOrigSendEvent)(self, _cmd, event);
}

// hook 装配（method_getImplementation + method_setImplementation，无 ellekit）
void PTDylibInstallHooks(void) {
    static dispatch_once_t on;
    dispatch_once(&on, ^{
        @autoreleasepool {
            PTDylibLogRefreshCfg();   // v1.0.19：启动时从配置种子 sLogEnabled（关日志后 PTDylibLog 不再每次读 plist）
            void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
            if (iokit) {
                pGetType = (IOHIDEventGetType_t)dlsym(iokit, "IOHIDEventGetType");
                pGetSender = (IOHIDEventGetSenderID_t)dlsym(iokit, "IOHIDEventGetSenderID");
                pGetFloat = (IOHIDEventGetFloatValue_t)dlsym(iokit, "IOHIDEventGetFloatValue");
            }
            Class addCls = NSClassFromString(@"_UIUpdateHIDDigitizerInput");
            if (!addCls) {
                // v1.0.19：私有类不存在（当前 iOS 版本可能已改名）→ 拦截完全失效，必须醒目提示
                NSLog(@"[PageTurnerDylib][严重] 核心钩子失败：私有类 _UIUpdateHIDDigitizerInput 不存在，翻页器输入拦截将完全失效（当前 iOS 可能已改名该私有类）。");
                PTDylibLog(@"[严重][核心钩子] 私有类 _UIUpdateHIDDigitizerInput 不存在 → 拦截失效");
            }
            SEL addSel = sel_registerName("addEvent:");
            Method am = addCls ? class_getInstanceMethod(addCls, addSel) : NULL;
            if (addCls && !am) {
                NSLog(@"[PageTurnerDylib][严重] 核心钩子失败：_UIUpdateHIDDigitizerInput 缺少 addEvent: 方法，翻页器输入拦截将完全失效。");
                PTDylibLog(@"[严重][核心钩子] _UIUpdateHIDDigitizerInput 缺少 addEvent: 方法 → 拦截失效");
            }
            if (am) { gOrigAddEvent = method_getImplementation(am); method_setImplementation(am, (IMP)PTDylibAddEvent); }

            Class appCls = NSClassFromString(@"UIApplication");
            SEL sendSel = sel_registerName("sendEvent:");
            Method sm = appCls ? class_getInstanceMethod(appCls, sendSel) : NULL;
            if (sm) { gOrigSendEvent = method_getImplementation(sm); method_setImplementation(sm, (IMP)PTDylibSendEvent); }

            BOOL ok = (gOrigAddEvent != NULL && gOrigSendEvent != NULL && pGetType != NULL && pGetSender != NULL);
            PTDylibLog(@"PTDylibInstallHooks: ok=%d addEvent=%d sendEvent=%d getType=%d getSender=%d",
                ok, gOrigAddEvent != NULL, gOrigSendEvent != NULL, pGetType != NULL, pGetSender != NULL);
            if (!ok) {
                // v1.0.19：单点失败兜底——任一核心符号缺失都导致功能静默失效，强制进 syslog 让用户可见
                NSLog(@"[PageTurnerDylib][严重] PTDylibInstallHooks 部分失败 ok=%d（addEvent=%d sendEvent=%d getType=%d getSender=%d）。翻页器拦截可能不工作，请核对当前 iOS 版本与私有 API 兼容性！",
                    ok, gOrigAddEvent != NULL, gOrigSendEvent != NULL, pGetType != NULL, pGetSender != NULL);
                PTDylibLog(@"[严重][核心钩子] 安装部分失败 ok=%d → 拦截可能不工作，核对 iOS 私有 API 兼容性", ok);
            }
        }
    });
}
