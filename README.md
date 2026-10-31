# 语音输入静音 · Push-to-Talk Mute

按住语音输入快捷键（默认**右 Ctrl**）时静音 macOS 系统输出，松开立刻恢复。音乐、网页视频继续播放，进度不回退。它只负责给语音输入腾出一个安静环境，不干预输入法的录音和识别。

适配**微信输入法**、**豆包输入法**，以及任何把同一个物理键当「按住说话」的输入法。

> 非官方个人工具，与字节跳动、腾讯及相关输入法团队无关。

## 它怎么工作

两种触发方式，自动二选一：

1. **认物理键**（首选）：直接读原始 HID 键流，所以连输入法自己吞掉的按住说话键也能看见。
2. **看麦克风**（降级）：没有「输入监控」权限时，改为监听微信输入法 / 豆包是否正在占用麦克风，占麦即静音，放开即恢复。**不需要任何系统权限。** 只看这两个输入法（`com.tencent.inputmethod.wetype`、`com.bytedance.inputmethod.doubaoime`），**其它 App 用麦克风不会触发**。每 5ms 查一次占麦状态，目标进程列表每 500ms 刷新一次。

当前用的是哪种，`--dump` 和状态文件里都有：`recognitionMode=precise-key` 或 `degraded-cg-or-ime-capture`。

内部的二进制名 `doubao-audio-duck`、服务名 `com.doubao.audio-duck` 是历史命名，和现在同时支持微信输入法无关，不影响使用。

## 安装

```bash
./install.sh
```

装完即可用（走上面的第 2 种方式）。想让第 1 种方式生效，再给一次权限：

```bash
~/.local/bin/doubao-audio-duck --grant
# 在弹出的「系统设置 → 隐私与安全性 → 输入监控」里允许 doubao-audio-duck
launchctl kickstart -k "gui/$(id -u)/com.doubao.audio-duck"
```

注意：本工具是 adhoc 签名，**每次重新编译都可能让这个授权失效**。失效了不影响使用（会自动退回第 2 种方式），想回到精确模式就再授权一次。

## 更新记录

- **2026-10-31（当前版本）** —— 触发方式改为「**看输入法有没有在占用麦克风**」：不再依赖系统权限，微信输入法或豆包开始采麦就静音、停止采麦就恢复。同时补上物理键模式的权限申请与明确报错，权限缺失时不会再静默失效（以前的表现就是"按了没反应"）。
- 2026-09-23 —— 支持微信输入法「按住说话」的快捷键读取。
- 2026-09-11 —— 豆包输入法开麦即静音。
- 2026-09-10 —— 静音延迟从 300–700ms 降到约 55ms。
- 2026-08-31 —— 移除全局 Fn 事件监听，改为按需触发。
- 2026-08-21 —— 早期基线：按住 Fn 静音、松开恢复。

## 换快捷键（要改代码）

默认键是**右 Ctrl（keyCode 62），写死在代码里**，位置在 `main.swift` 第 8 行：

```swift
private let fallbackHoldKey = CGKeyCode(kVK_RightControl)
```

- 你的输入法「按住说话」绑的是**别的键**，或者你想用蓝牙键盘上的某个键 → 改这一行的 keyCode，然后重跑 `./install.sh`。
- 如果那个键**不是 Ctrl**，还要在 `main.swift` 的 `HIDKeyMonitor`（约 244 行）里补一条 HID usage 映射。目前只映射了左 Ctrl（`0xE0`）和右 Ctrl（`0xE4`）；不补的话精确模式认不出这个键，只剩"看麦克风"那层有效。
- 微信输入法的「按住说话」配置如果能读到，会优先按它来（`--dump` 显示 `source=wetype`）；读不到、关闭或格式变化才用上面这个默认键。
- macOS 的 Fn（Globe）键有特殊性，不推荐绑它。

## 现在的限制

- 只认微信输入法和豆包这两个输入法在采麦；会议、录屏、语音备忘录等其它 App 用麦克风**不会**触发静音。
- **看麦克风模式分不清"真的在说话"和"后台预采麦"**：点麦克风按钮录音也会静音；输入法一直占着麦就一直静音，直到它放开。
- 只对**默认输出设备**写 mute。设备不暴露 mute 属性（部分外接声卡、AirPlay）就不生效；本机蓝牙音箱已验证可用。
- 5ms 是采样目标值，不是时延保证：不保证一定先于输入法开麦，也不保证识别不漏字。
- 强制杀进程、崩溃、切换输出设备时，可能来不及恢复静音。

## 诊断

```bash
~/.local/bin/doubao-audio-duck --dump          # 用了哪个键、走哪种模式、权限与状态
~/.local/bin/doubao-audio-duck --self-test     # 57 条断言自检，不动系统声音
~/.local/bin/doubao-audio-duck --probe-keys    # 只采样按键，不静音
~/.local/bin/doubao-audio-duck --force-unmute  # 卡住静音时强制解除
tail -30 ~/Library/Logs/doubao-audio-duck.log
launchctl print "gui/$(id -u)/com.doubao.audio-duck"
```

状态文件 `/tmp/doubao-audio-duck.status` 正常值是 `idle`、`ducked hold-key` 或 `held pre-muted`。

## 卸载

```bash
./uninstall.sh
```

卸载会强制解除静音（包括你本来手动开的静音），执行前留意当前声音状态。

## 文件

- `main.swift`：快捷键读取、物理键 / 采麦触发、静音恢复、诊断与自检。
- `install.sh` / `uninstall.sh`：安装与卸载登录服务。
- `scratch/trace-fn.swift`：历史 Fn / 采麦只读诊断，不参与运行。

## English

Mutes the macOS default output while you hold the push-to-talk key (Right Control by default) and restores the previous mute state on release. Audio keeps playing.

Works with WeType (微信输入法) and Doubao IME. Two triggers, picked automatically: raw HID key events (needs Input Monitoring) or those two input methods' microphone capture state (needs no permission). Only these two IMEs are watched — other apps using the microphone never trigger it. With the capture fallback, background pre-capture and click-to-record also mute. The hold key is hard-coded as Right Control (keyCode 62 in `main.swift:8`); edit it — plus the HID usage mapping near line 244 for non-Ctrl keys — and re-run `./install.sh` to change it.
