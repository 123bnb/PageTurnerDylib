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

- **v1.0.17**：修复录制覆盖层「取消/完成」按钮真正根因——按钮/提示文字是顶部横幅(bar)的子视图，frame 误用了 topInset+xx 绝对坐标（topInset=54 时 y=64 超出 bar 高 56），按钮整体渲染在横幅下方、且 hitTest 只命中 bar 区域导致点击穿透。改为 bar 内相对坐标后按钮回到横幅当中、可正常点击。
- **v1.0.16**：录制覆盖层布局加固——注入环境下 keyWindow.safeAreaInsets.top 可能返回 0（按钮行仍被灵动岛盖住/按钮与横幅错位），改用状态栏高度兜底取最大值；覆盖层顶部显示版本号便于确认加载；中央提示卡文案注明「仅提示可穿透、顶部取消/完成可点击」。
- **v1.0.15**：修复滑动(手动)录制覆盖层「完成/取消」按钮按不到——根因是整层 userInteractionEnabled=NO 导致 iOS 命中测试跳过整棵子树，按钮收不到触摸（点击穿透到 App）；改为自定义覆盖层视图 hitTest 局部命中：仅顶部按钮行可点，其余区域穿透到 App（实地录制不受影响）。
- **v1.0.14**：删【点击(手动)/双击(手动)】动作（新增映射菜单仅保留【滑动(手动)】；旧配置残留动作点击编辑后自动转普通点击/双击）；修复滑动(手动)录制覆盖层按钮被灵动岛挡住按不到的问题——顶部「取消/完成」按钮行下移到安全区以下（此前从 y=0 开始）。
- **v1.0.13**：修复「测试本方案」看不到滑动(手动)轨迹——测试区执行函数缺 recSwipe/tapManual/doubleTapManual 分支（此前命中方案后手动动作被跳过，什么都没注入）；现在测试区按翻页键会真实回放录制轨迹，绿点轨迹线可见（需开调试可视化）。
- **v1.0.12**：四件套——①**状态栏彻底不碰**：可视化从独立窗口改成 keyWindow 上的透明覆盖层（零窗口，时间/信号电量永远跟随 App，打开调试可视化也不会变白）；②**双指长按稳定弹出**：删掉手势识别器，改 sendEvent 层自检测"两指同时按住 0.5s"，任何页面任何角落都能弹（不再依赖 keyWindow/手势仲裁）；③**轨迹可见**：录制/测试轨迹线同层显示；④**录制改半透明覆盖层**：录制区叠在 App 内容上（能看到小说）、触摸穿透实地操作，新增「点击(手动)」「双击(手动)」，滑动/点击/双击三种手动录制统一，已完成动作再点=重录覆盖（deb v1.0.51 同步）。
- **v1.0.11**：①可视化绿点窗口 windowLevel 降到 Normal+1（盖 App 内容但不盖状态栏）——彻底不碰时间/信号电量，状态栏归系统/App 管（deb v1.0.50 同步）；②录制页轨迹修复——timer 注册 tracking 模式（手指滑动时也刷新）+ 录完保留轨迹；③双指长按手势装到所有前台窗口（不止 keyWindow）+ 定时补装——阅读页独立窗口也能触发。
- **v1.0.10**：六项修复——①录制页实时轨迹线；②状态栏透传改系统实时值+菜单页补状态栏隐藏透传（不再瞬间变白/全屏不隐藏）；③删录制页手势禁用（恢复左滑返回）；④滑动(手动)已录动作再点击=重新录入覆盖；⑤三指改双指+3s定时兜底迁移（更稳）；⑥修复"再滑一次可重录"失效（回调不再置空）。
- **v1.0.9**：滑动(手动)录制页 UI 调整——提示字移到录制区中心当背景字（自动换行、不拦截滑动、不被灵动岛遮挡）。
- **v1.0.8**：新增「滑动(手动)」动作——录制页顶部完成按钮行往下为录制区，手指滑动录真实轨迹（坐标+时间戳），点完成保存；回放按录制轨迹逐点注入（保持时间间隔），告别程序插值滑动的卡顿。
- **v1.0.7**：状态栏颜色跟随 App 修复——可视化窗口/菜单窗口的 rootViewController 状态栏样式透传（不再接管状态栏导致时间/信号电池变白）；可视化开关关掉时销毁窗口（不再永驻）；三指手势监听 UIWindowDidBecomeKeyNotification，keyWindow 变化自动迁移（此前只在触发时迁移，手势留在旧窗口触发不了就永远自愈不了）。
- **v1.0.6**：修复调试可视化无效——可视化画点移到 sendEvent 注入 return 之前（与 deb 对齐，未命中重放/动作注入也画点）；可视化窗口补 windowScene 绑定（iOS 13+ 多 scene）。
- **v1.0.5**：删除音量动作类型（与 deb v1.0.48 同步）——音量+/音量-/静音切换整体删除（无音频会话 App 进程音量读取接口全假值，修四版无法稳定，止损）；旧配置里的音量动作执行时自动跳过。
- **v1.0.3**：音量± 读真实系统音量修复（与 deb v1.0.46 同步）——读改走 AVAudioSession.outputVolume（AVSystemController get 在 App 进程恒 0.5 默认，导致首次从 50% 起步、手动调音量不感知）；删持久目标状态，每次现读真实值再 ±0.0625。
- **v1.0.2**：配置统一存 App 容器内（去掉 deb 5 候选路径探测 / jbroot 镜像推断 / 双写——TrollStore 注入无沙盒外权限，那些路径全部访问不到）；日志文件固定容器 Documents；音量± 与 deb v1.0.45 同步修复（目标值状态累加，不再依赖 get 回读，修"只能首次触发"）。
- **v1.0.1**：音量修复（与 deb v1.0.44 同步）——静音/音量± 无效根因：AVSystemController 私有 category 字符串用错，现按候选 category 依次尝试 + 回读确认 + MPVolumeView slider 兜底。
- **v1.0.0**：首个独立 dylib 版本。功能与 deb v1.0.43 对齐（防抖严谨化、可视化只画实际收到触摸、速度默认 1000pt/s、参数页预设值、映射排序、重复特征禁保存+清空、绿点解除钳制、底部版本号等）。
