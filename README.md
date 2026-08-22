# 豆包输入法语音闪避 · Doubao Audio Duck

> **豆包语音输入时，番剧对白、音乐、说唱也被麦克风一起听进去了？**
>
> **When using Doubao voice input on Mac, does anime dialogue, music, or rap get picked up by the microphone too?**

豆包输入法的语音识别很快，但在 macOS 上语音输入时不会自动闪避系统声音。你一边播放番剧、音乐、播客或视频，一边按住 Fn 说话，扬声器里的声音可能会被麦克风重新拾取，干扰识别结果。

Doubao Input Method is fast, but it does not automatically duck system audio during voice typing on macOS. If you play anime, music, podcasts, or videos while holding Fn to speak, the microphone may capture that playback and interfere with recognition.

**Doubao Audio Duck** 解决的就是这个问题：在**按住 Fn 拉起豆包语音**时自动静音整个 macOS 系统输出；松开按键、识别结束后，再恢复声音。它不会暂停视频，也不会改变播放进度。空闲时贴在屏幕右缘的语音条、以及豆包自己闪动的采麦标志，都不会静音。

**Doubao Audio Duck** addresses this gap: while you **hold Fn to start Doubao voice input**, it automatically mutes macOS system output and restores audio after recording ends. It does not pause videos or change playback position. An idle voice bar parked against a screen's right edge, and Doubao's own flickering capture flag, will not mute audio.

这是一个针对真实使用痛点制作的个人工具，当前实现主要基于我的 Mac 和豆包版本验证，不保证适配所有 macOS、豆包版本和硬件组合。如果你也遇到同样的干扰，欢迎试用、反馈和改进。

This is a small personal tool built around a real-world annoyance. The current implementation has mainly been tested with the author's Mac and Doubao version, so compatibility with every macOS release, Doubao version, and hardware setup is not guaranteed. If you have the same problem, try it, report issues, and help improve it.

> 本项目与字节跳动、豆包输入法或其开发团队无关。
>
> This project is not affiliated with ByteDance or the Doubao Input Method team.

**搜索关键词 / Search terms:** 豆包输入法、Mac 语音输入、macOS 语音识别、麦克风干扰、系统声音静音、录音时静音、音频闪避、番剧、音乐、说唱、视频播放；Doubao Input Method, macOS voice typing, dictation, microphone interference, mute system audio while recording, audio ducking, anime, music, rap, video playback.

## 一句话了解 · In one sentence

播放番剧、音乐或视频时，用豆包输入法按住 Fn 说话；本工具会在录音期间静音系统声音，避免播放内容被麦克风拾取。

Play anime, music, or video while using Doubao voice input; this helper mutes system output during recording so playback is not picked up by the microphone.

## 功能亮点 · Features

- **只有按住 Fn 才会开始静音**；空闲时贴在屏幕右缘的语音条、以及豆包自己闪动的采麦标志，都不会单独静音。
- Fn 启动后，未贴边的语音浮层或稳定的 Core Audio 采集可维持静音（覆盖双击 Fn 持续录音）。
- 使用 macOS 系统级输出静音，因此 Safari、Chrome、视频播放器和其他应用都会暂时静音。
- 结束录音后约 1 秒恢复，避免松键或浮层抖动时把 AirPlay 掐断又接上。
- 如果开始录音前系统已经静音，结束时不会擅自取消静音。
- 以 Swift 单文件实现，安装脚本会在当前 Mac 上重新编译，兼容 Apple Silicon 与 Intel 的本机编译流程。

- **Mute starts only when Fn is held**; an idle bar parked against a screen's right edge, and Doubao's flickering capture flag, cannot start a duck on their own.
- After Fn starts a duck, a non-parked recording overlay or stable Core Audio capture can keep it (covers double-tap Fn continuous recording).
- Because it uses system-level output mute, Safari, Chrome, media players, and other apps are muted together.
- Restores audio about 1 second after recording ends to avoid chopping AirPlay streams.
- Preserves a mute state that was already enabled before recording.
- Implemented as a single Swift source file; the installer compiles a native binary on the current Mac for Apple Silicon or Intel.

## 工作方式 · How it works

程序每约 80 ms 检查 Fn；另外两个信号只用来**维持**已经开始的静音，不能单独启动：

1. **启动：** 当前输入法是豆包，并且 Fn 按住约 240 ms；短暂的 Fn+亮度按键不会触发。没按 Fn 就绝不静音。
2. **维持：** 未贴边的高层级语音浮层。豆包空闲时会把语音条**齐着屏幕右缘停着**（宽屏上完全可见），这条不算录音。
3. **维持：** Core Audio 将豆包输入法进程标记为正在采集输入，且连续约 320 ms。输入法会在没录音时闪这个位，所以不能用来启动。

The daemon checks Fn roughly every 80 ms. Overlay and HAL only **sustain** an already-started duck; they cannot start one:

1. **Start:** Doubao is the current input source and the Fn key has been held for about 240 ms. Brief Fn+brightness taps are ignored. No Fn, no mute.
2. **Sustain:** Doubao's high-level recording overlay is on a display and **not** parked flush with a screen's right edge. The idle 643×77 bar sits at that edge and is ignored.
3. **Sustain:** Core Audio reports the Doubao process as capturing input for about 320 ms. That bit flickers without recording, so it cannot start a duck.

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

安装完成后，打开网页音乐或视频，切换到豆包输入法并按住默认的 Fn 语音快捷键。录音期间系统输出会静音，松开后约 1 秒恢复。

After installation, play a web page or video, select Doubao, and hold its default Fn voice shortcut. System output should mute during recording and return about 1 second after release.

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

录音期间状态文件通常会显示 `ducked fn`；空闲时为 `idle`。不应再出现空闲时的 `ducked overlay[…]` 或单独的 `ducked hal`。

During recording, the status file normally contains `ducked fn`. It is `idle` when inactive. Idle `ducked overlay[…]` or a lone `ducked hal` should no longer appear.

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
- 如果把豆包快捷键改成非 Fn 按键，本工具不会再自动静音（浮层和 Core Audio 不能单独启动闪避）。
- 它会静音所有系统输出，而不是只暂停某一个应用；请确认这正是你想要的行为。
- 进程不读取键盘输入内容，只读取 Fn 修饰键状态、当前输入源、窗口几何信息和 Core Audio 进程状态。
- 如果程序异常退出后声音仍被静音，可先执行 `osascript -e 'set volume without output muted'`，再查看日志或运行卸载脚本。
- 每个 macOS 用户都需要分别运行一次安装脚本。

- This is an unofficial helper for Doubao Input Method. It does not handle WeChat Input Method, Zoom, or other recording applications.
- If Doubao's shortcut is changed to a non-Fn key, this helper will no longer start ducking (overlay and Core Audio cannot start a duck on their own).
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
