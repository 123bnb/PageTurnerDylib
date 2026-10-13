// Compat.h — PTFakeTouch 原生源码兼容宏
// 原生 PTFakeMetaTouch.m 使用了 DLog 宏但工程里未定义，这里统一补齐。
#ifndef DLog
#define DLog(...) NSLog(__VA_ARGS__)
#endif

#include <stdint.h>

// 注入用 senderID（由 Tweak.xm 在进程内捕获真实触摸 sender 后写入；
// 模拟触摸的 IOHIDEvent 必须带目标 App 进程内有效的 senderID，否则被系统丢弃）
extern uint64_t gInjectSender;
