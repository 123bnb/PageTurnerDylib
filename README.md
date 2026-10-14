# PageTurnerDylib

**PageTurner 翻页器按键映射 · 独立 dylib 版（v1.0.0）**

用巨魔注入器（TrollFools / TrollStore）把 `PageTurnerDylib.dylib` 注入任意 App，**注入即生效**：在该 App 内**三指长按 0.5 秒**弹出设置菜单，完成防抖间隔、记录与映射、调试可视化、调试日志的全部配置。

- 独立仓库，现有 deb 版（`123bnb/PageTurner`）一行代码不动
- 无总开关、无「指定 App 生效」——不按翻页器键 = 不启用
- 配置规则：**检测到 deb 版配置文件就复用（数据互通），没检测到就自建独立配置**
- 构建参考 `DirectVolumeTap` 的纯 clang + ldid 方案，产物为单个 `.dylib`

---

## 安装与使用

1. 用 TrollStore 安装/打开巨魔注入器（TrollFools）
2. 把 `PageTurnerDylib.dylib` 注入到你要翻页的目标 App（如番茄小说）
3. 打开该 App，**三指长按 0.5 秒** → 弹出设置菜单
4. 按需设置：
   - **防抖间隔**：连续按键最小间隔（滑杆 100~1000ms，默认 300ms）
   - **记录与映射**：完整方案管理（新增方案 → 录制特征 → 映射动作序列 → 动作参数 → 排序 → 测试区）
   - **调试可视化**（开关）：开启后所有触摸显示绿点+轨迹（翻页器带 P 标记）
   - **调试日志**（开关）：总日志开关（内存 200 条 + 文件 1000 行）
   - **调试日志**（入口，仅开关打开时显示）：查看并复制最近日志

## 菜单结构（三指长按弹出）

```
PageTurnerDylib              [关闭]
├─ 设置
│  ├─ 防抖间隔        → 滑杆页
│  └─ 记录与映射      → 方案列表（新增/删除/排序/测试）
└─ 调试
   ├─ 调试可视化      [开关]
   ├─ 调试日志        [开关]
   └─ 调试日志        → 日志页（开关开时显示）
配置来源：复用 deb 版配置 / 独立配置（底部显示）
```

## 配置路径（关键）

dylib 启动时按顺序探测，**第一个存在的文件**即为当前配置：

**① deb 版配置（优先复用）**：`com.yourname.pageturner.plist`
```
/var/mobile/Library/Preferences/com.yourname.pageturner.plist
<jbroot>/var/mobile/Library/Preferences/com.yourname.pageturner.plist
<jbroot>/Library/Preferences/com.yourname.pageturner.plist
/var/jb/var/mobile/Library/Preferences/com.yourname.pageturner.plist
/var/jb/Library/Preferences/com.yourname.pageturner.plist
```
（`<jbroot>` = 从本 dylib 镜像路径提取的 `.jbroot-XXX` 根）

**② 都没有 → 自建独立配置**：`com.yourname.pageturnerdylib.plist`（同 5 候选路径模式，主路径 `/var/mobile/Library/Preferences/`）

写配置时与 deb 版同策略：jbroot 真实偏好路径 + 普通路径双写，App 沙盒重定向下仍可读。

## 日志

- 内存：最近 200 条（菜单 → 调试日志直接查看/复制）
- 文件：`PageTurnerDylib.log`，循环保留 1000 行；候选路径：App 容器 Documents、`/var/mobile/Documents`、jbroot 变体

## 与 deb 版的行为差异

| | deb 版 | PageTurnerDylib |
|---|---|---|
| 注入方式 | 越狱插件（PreferenceLoader + ellekit） | 巨魔注入 dylib |
| 生效范围 | 勾选 App 才生效 | 注入哪个 App 就在哪个 App 生效 |
| 总开关 | 有 | 无（不按 = 不启用） |
| 设置入口 | 系统设置 → PageTurner | App 内三指长按 |
| 配置 | 固定路径 | 有 deb 配置则复用，无则独立 |
| hook | MSHookMessageEx（ellekit） | method_getImplementation + method_setImplementation |

## 构建

GitHub Actions 自动构建（push 到 main 或 tag `v*`），产物上传 artifact / 发布 Release：

```bash
SDK=<iPhoneOS16.5.sdk 路径>
clang -arch arm64 -arch arm64e -isysroot "$SDK" -miphoneos-version-min=15.0 \
  -fobjc-arc -fobjc-abi-version=2 -Wl,-undefined,dynamic_lookup \
  -Wno-unused-variable -Wno-deprecated-declarations -Wno-arc-performSelector-leaks \
  -Iptftouch -include ptftouch/Compat.h \
  -framework Foundation -framework UIKit \
  -dynamiclib PTDylibMain.m PTDylibCore.m PTDylibUI.m \
    ptftouch/PTFakeMetaTouch.m ptftouch/UITouch-KIFAdditions.m \
    ptftouch/UIEvent+KIFAdditions.m ptftouch/IOHIDEvent+KIF.m \
  -o PageTurnerDylib.dylib
ldid -S PageTurnerDylib.dylib
```

## 源码结构

| 文件 | 说明 |
|---|---|
| `PTDylibMain.m` | 注入入口（constructor）+ 三指长按手势 + 覆盖窗口 |
| `PTDylibCore.m` | 运行端核心：配置选择（deb 复用/独立自建）、日志、学习/测试采集、运行拦截/匹配/执行、调试可视化、合并 hook |
| `PTDylibUI.m` | 设置页（防抖/方案/学习/动作/参数/日志/测试）+ 三指菜单主页面 |
| `PTDylibShared.h` | 跨文件共享符号 |
| `ptftouch/` | PTFakeMetaTouch 合成触摸（自 deb 版复制，KIF 同源） |

## 版本记录

- **v1.0.1**：音量修复（与 deb v1.0.44 同步）——静音/音量± 无效根因：AVSystemController 私有 category 字符串用错，现按候选 category 依次尝试 + 回读确认 + MPVolumeView slider 兜底。
- **v1.0.0**：首个独立 dylib 版本。功能与 deb v1.0.43 对齐（防抖严谨化、可视化只画实际收到触摸、速度默认 1000pt/s、参数页预设值、映射排序、重复特征禁保存+清空、绿点解除钳制、底部版本号等）。
