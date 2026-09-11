# 豆包输入法语音闪避 · Doubao Audio Duck

豆包输入法采集麦克风时，自动静音 macOS 默认输出设备；采集结束约 1 秒后恢复原来的静音状态。用于减少喜马拉雅、网页视频或音乐被麦克风一起识别的问题。不会暂停播放或改变播放进度。

Mutes the macOS default output while Doubao Input Method captures the microphone, then restores the previous mute state about one second after capture stops. Playback continues.

非官方个人工具，与字节跳动及豆包团队无关。

## 工作方式

- 只检查 bundle ID 为 `com.bytedance.inputmethod.doubaoime` 的 Core Audio 采集状态，不把其他应用开麦当作触发条件。
- 专用线程每隔约 20ms 发起一次检查，同一时间最多一个扫描；首次观察到采集就执行静音，不再等待 320ms。
- 不再以 Fn 标志、当前输入法或窗口位置作为静音前提。方向键也可能设置 Function 标志，它不是物理 Fn 专属。
- 持续采集时保持静音，停止约 1 秒后恢复；恢复前再次采集会取消恢复任务。
- 保留用户原先的静音状态，正常停止服务时恢复由本进程修改的状态。

**限制：** Core Audio 只能说明豆包正在采集，不能区分后台预采集和实际语音识别。因此豆包后台采麦也会静音。这版优先避免漏静音。它没有修改豆包软件或挂钩其 Fn 处理函数，不能保证在开麦前静音，也不能保证零延迟；20ms 是检查间隔而不是实测端到端延迟。

The trigger is Doubao's own Core Audio capture state, not a keyboard flag or window heuristic. Capture is checked at roughly 20ms intervals with at most one scan in flight. There is no 320ms start debounce. Only restoration is delayed. Background capture by Doubao also triggers mute; polling cannot guarantee zero latency or mute before the microphone opens.

## 环境与安装

- macOS，系统 Core Audio API 可报告进程采集状态。
- 豆包输入法。
- Xcode Command Line Tools (`swiftc`)。
- 默认输出设备必须支持可写的 mute 属性；外接声卡、AirPlay 等设备不保证兼容。

```bash
./install.sh
```

安装到 `~/.local/bin/doubao-audio-duck`，创建并启动登录自启服务 `com.doubao.audio-duck`。安装脚本可重复运行。

旧的 `DUCK_FN_HOLD_MS` / `DUCK_FN_CONFIRM_MS` 参数不再控制采麦模式。

## 检查

```bash
# 当前状态，duckMode 应为 doubao-capture
~/.local/bin/doubao-audio-duck --dump

# 控制器回归测试，使用模拟音频后端，不改变系统声音
~/.local/bin/doubao-audio-duck --self-test

# 手动静音 1 秒后恢复
~/.local/bin/doubao-audio-duck --test-mute

# 日志与服务状态
 tail -30 ~/Library/Logs/doubao-audio-duck.log
 launchctl print "gui/$(id -u)/com.doubao.audio-duck"
```

采集期间状态为 `ducked doubao-capture`，空闲为 `idle`。状态文件：`/tmp/doubao-audio-duck.status`。

默认输出设备切换、多输出路由和异常强制终止的恢复不保证正确；若异常终止后仍静音，可手动执行：

```bash
~/.local/bin/doubao-audio-duck --force-unmute
```

## 卸载

```bash
./uninstall.sh
```

## 文件

- `main.swift`：采集检测、静音控制、诊断与自检。
- `install.sh` / `uninstall.sh`：安装及卸载登录服务。
- `scratch/trace-fn.swift`：只读 Fn/采麦对照诊断，不参与正常运行。
