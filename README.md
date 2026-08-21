# 豆包输入法语音闪避 · Doubao Audio Duck

一个面向 macOS 的豆包输入法语音输入辅助工具：豆包开始识别语音时，自动静音系统输出；识别结束后恢复原来的静音状态，减少扬声器声音被麦克风重新录入造成的误识别。

An unofficial macOS helper for Doubao Input Method. While Doubao is recording speech, it mutes system output and restores the previous mute state shortly after recording ends, helping prevent speaker audio from leaking back into microphone recognition.

> 本项目与字节跳动、豆包输入法或其开发团队无关。
>
> This project is not affiliated with ByteDance or the Doubao Input Method team.

## 功能亮点 · Features

- 仅在检测到豆包语音输入时闪避系统输出，空闲时不影响声音。
- 同时覆盖三种检测信号：Fn 按住、豆包语音浮层、Core Audio 录音状态。
- 使用 macOS 系统级输出静音，因此 Safari、Chrome、视频播放器和其他应用都会暂时静音。
- 结束录音后约 0.35 秒恢复，避免松键瞬间“闪回”一声。
- 如果开始录音前系统已经静音，结束时不会擅自取消静音。
- 以 Swift 单文件实现，安装脚本会在当前 Mac 上重新编译，兼容 Apple Silicon 与 Intel 的本机编译流程。

- Docks system output only while Doubao voice input is detected.
- Uses three detection signals: held Fn key, the visible Doubao recording overlay, and Core Audio input activity.
- Because it uses system-level output mute, Safari, Chrome, media players, and other apps are muted together.
- Restores audio about 0.35 seconds after recording ends to avoid a brief sound leak.
- Preserves a mute state that was already enabled before recording.
- Implemented as a single Swift source file; the installer compiles a native binary on the current Mac for Apple Silicon or Intel.

## 工作方式 · How it works

程序每约 80 ms 检查以下信号，命中任意一个就进入闪避状态：

1. 当前输入法是豆包，并且 Fn 按住约 240 ms；短暂的 Fn+亮度按键不会触发。
2. 豆包的高层级语音浮层真正显示在屏幕上；停在屏幕外的隐藏候选/浮层不会触发。
3. Core Audio 将豆包输入法进程标记为正在采集输入。这个信号在部分版本中不稳定，因此只作为补充。

The daemon checks these signals roughly every 80 ms and ducks audio when any one is active:

1. Doubao is the current input source and the Fn key has been held for about 240 ms. Brief Fn+brightness taps are ignored.
2. Doubao's high-level recording overlay is visibly present on a display; parked-off-screen windows are ignored.
3. Core Audio reports the Doubao process as capturing input. This signal is unreliable on some versions and is used as a supplement.

闪避使用的是系统输出静音，不是暂停媒体。因此视频或网页会继续播放，只是暂时没有声音。

The tool mutes system output rather than pausing media. Videos and web pages keep playing silently and resume with their existing playback position.

## 环境要求 · Requirements

- macOS 12 或更新版本（已在 macOS 15.7 上验证）。
- 已安装[豆包输入法](https://shurufa.doubao.com/)，并将其设为当前输入法。
- Apple Command Line Tools，安装脚本需要其中的 `swiftc`：

```bash
xcode-select --install
```

- macOS 12 or newer (verified on macOS 15.7).
- [Doubao Input Method](https://shurufa.doubao.com/) installed and selected as the current input source.
- Apple Command Line Tools, because the installer uses `swiftc`:

```bash
xcode-select --install
```

## 安装 · Installation

推荐直接从 GitHub 克隆到用户目录：

Clone the project into a user-owned directory:

```bash
mkdir -p ~/.local/share
git clone https://github.com/leotpp/doubao-audio-duck.git ~/.local/share/doubao-audio-duck
cd ~/.local/share/doubao-audio-duck
chmod +x install.sh uninstall.sh
./install.sh
```

`install.sh` 会：

1. 使用当前机器上的 `swiftc` 编译 `main.swift`。
2. 将可执行文件安装到 `~/.local/bin/doubao-audio-duck`。
3. 创建 `~/Library/LaunchAgents/com.doubao.audio-duck.plist`。
4. 注册并启动 LaunchAgent，使工具在登录后自动运行。

`install.sh` will:

1. Compile `main.swift` with the local `swiftc`.
2. Install the executable at `~/.local/bin/doubao-audio-duck`.
3. Create `~/Library/LaunchAgents/com.doubao.audio-duck.plist`.
4. Bootstrap and start a LaunchAgent so the helper runs after login.

脚本可以重复运行；它会先停止旧的同名 LaunchAgent，再重新编译并启动。

The script is safe to run again; it stops the existing service, recompiles the binary, and starts it again.

## 使用与自检 · Usage and diagnostics

安装完成后，打开网页音乐或视频，切换到豆包输入法并按住默认的 Fn 语音快捷键。录音期间系统输出会静音，松开后约 0.35 秒恢复。

After installation, play a web page or video, select Doubao, and hold its default Fn voice shortcut. System output should mute during recording and return about 0.35 seconds after release.

查看检测状态：

Inspect detection state:

```bash
~/.local/bin/doubao-audio-duck --dump
```

典型的空闲输出：

Typical idle output:

```text
systemMuted=false
doubaoHALCapturing=false
doubaoRecordingOverlayVisible=false
currentInputSourceIsDoubao=true
fnHeld=false
```

手动测试系统静音与恢复（会静音约 1 秒）：

Test mute and restore manually (this mutes output for about one second):

```bash
~/.local/bin/doubao-audio-duck --test-mute
```

也可以查看服务、状态文件和最近日志：

You can also inspect the service, status file, and recent logs:

```bash
launchctl print "gui/$(id -u)/com.doubao.audio-duck" | grep 'state ='
cat /tmp/doubao-audio-duck.status
tail -30 ~/Library/Logs/doubao-audio-duck.log
```

录音期间状态文件通常会显示 `ducked fn`、`ducked overlay[…]` 或其他 `ducked …` 状态；空闲时为 `idle`。

During recording, the status file normally contains `ducked fn`, `ducked overlay[…]`, or another `ducked …` value. It is `idle` when inactive.

## 安装后文件 · Installed files

| 用途 / Purpose | 路径 / Path |
|---|---|
| 源码 / Source | 你克隆项目的目录 / The directory where you cloned the project |
| 可执行文件 / Binary | `~/.local/bin/doubao-audio-duck` |
| 开机启动 / LaunchAgent | `~/Library/LaunchAgents/com.doubao.audio-duck.plist` |
| 日志 / Log | `~/Library/Logs/doubao-audio-duck.log` |
| 当前状态 / Status | `/tmp/doubao-audio-duck.status` |

不要把某台 Mac 上编译好的二进制直接复制到另一台 Mac；请复制源码后在目标机器上重新运行 `install.sh`。

Do not copy a binary compiled on one Mac to another Mac. Copy the source and run `install.sh` on the target machine instead.

## 卸载 · Uninstallation

```bash
~/.local/share/doubao-audio-duck/uninstall.sh
```

卸载脚本会停止 LaunchAgent、删除已安装的二进制和启动配置，并尝试恢复系统声音。源码目录和日志默认保留。

The uninstall script stops the LaunchAgent, removes the installed binary and launch configuration, and attempts to restore system audio. The source directory and logs are kept by default.

如需临时停止但不删除文件：

To stop the service temporarily without removing files:

```bash
launchctl bootout "gui/$(id -u)/com.doubao.audio-duck"
```

修改 `main.swift` 后，重新运行安装脚本即可重新编译并重启：

After modifying `main.swift`, run the installer again to rebuild and restart:

```bash
~/.local/share/doubao-audio-duck/install.sh
```

## 限制与隐私 · Limitations and privacy

- 这是针对豆包输入法的非官方辅助工具，不处理微信输入法、Zoom 或其他应用的录音。
- 如果把豆包快捷键改成非 Fn 按键，Fn 检测会失效；浮层或 Core Audio 检测仍可能有效。
- 它会静音所有系统输出，而不是只暂停某一个应用；请确认这正是你想要的行为。
- 进程不读取键盘输入内容，只读取 Fn 修饰键状态、当前输入源、窗口几何信息和 Core Audio 进程状态。
- 如果程序异常退出后声音仍被静音，可先执行 `osascript -e 'set volume without output muted'`，再查看日志或运行卸载脚本。
- 每个 macOS 用户都需要分别运行一次安装脚本。

- This is an unofficial helper for Doubao Input Method. It does not handle WeChat Input Method, Zoom, or other recording applications.
- If Doubao's shortcut is changed to a non-Fn key, Fn detection will no longer work; overlay or Core Audio detection may still work.
- It mutes all system output rather than pausing one application, so make sure that behavior fits your workflow.
- It does not read keyboard contents. It only inspects Fn modifier state, the current input source, window geometry, and Core Audio process state.
- If an abnormal exit leaves audio muted, run `osascript -e 'set volume without output muted'`, then inspect the logs or run the uninstall script.
- Each macOS user must run the installer separately.

## 项目结构 · Project structure

| 文件 / File | 说明 / Description |
|---|---|
| `main.swift` | 守护进程、录音检测、系统静音、状态输出与调试命令 / Daemon, recording detection, system mute, status, and diagnostics |
| `install.sh` | 编译、安装并启动 LaunchAgent / Build, install, and start the LaunchAgent |
| `uninstall.sh` | 停止并移除已安装组件 / Stop and remove installed components |
| `README.md` | 中英文使用说明 / Bilingual documentation |

## 许可证 · License

当前仓库尚未附带具体开源许可证。仓库虽然公开，但如果你准备复制、修改或再分发，请先等待作者补充许可证或取得明确授权。

This repository does not currently include a specific open-source license. Although the repository is public, please wait for a license to be added or obtain explicit permission before copying, modifying, or redistributing the code.
