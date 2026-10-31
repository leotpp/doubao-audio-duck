# 按键语音静音 · Doubao Audio Duck

按住语音输入快捷键时，静音 macOS 默认输出；松开后立即尝试恢复按键前的静音状态。启动时读取微信输入法「按住说话」的快捷键，无法读取或不支持时回退为右 Ctrl（keyCode 62）。音乐、网页视频等继续播放，播放进度不变。

Mutes the macOS default output while the push-to-talk key is held and restores its previous mute state on release. Reads WeType's hold shortcut at startup, falling back to Right Control (keyCode 62). Playback continues.

非官方个人工具，与字节跳动、腾讯及相关输入法团队无关。

## 工作方式

- 约每 5ms 读取一次物理按键状态；首次观察到按下就尝试静音，首次观察到释放就尝试恢复，不额外等待长按确认或 1 秒恢复延时。按键优先从原始 HID 层读取：微信输入法会吞掉自己的按住说话键，普通键盘事件接口看不到它。
- HID 通道可用时按实体键触发，不要求当前输入源是微信输入法；HID 不可用时自动切换为 **CG keyState 或 WeType/豆包采麦** 降级。两种模式都会明确记录在启动日志和状态文件中。
- 从 `~/Library/Application Support/WeType/mmkv/wetype.settings` 只读解析「按住说话」配置，不修改输入法设置。支持单键及该键本身的修饰位，暂不支持组合键、多击和 Fn；配置关闭、缺失、损坏或不支持时，在日志记录原因并回退到右 Ctrl。Ctrl 类快捷键同时监听左右两个 keyCode（本机蓝牙键盘把右 Ctrl 上报为 59）。
- 改快捷键后需重启服务；`--dump` 显示配置读取结果，服务实际采用的键也会在启动日志中记录。
- 原始 HID 当前仅映射左右 Ctrl（usage `0xE0` / `0xE4`）；其他单键配置仍依赖 CGEventSource，输入法吞键时不能保证识别。此次未扩展键码映射。
- 降级模式在独立串行队列约每 20ms 查询 CoreAudio 进程列表（`prs#`）、bundle ID（`pbid`）和 running input（`piri`），最多一个查询在途，不阻塞主按键轮询。只匹配 `com.tencent.inputmethod.wetype` / `com.bytedance.inputmethod.doubaoime`，无需新增 TCC 权限；CG 接口仅为辅助，无法可靠识别被输入法吞掉的键。查询失败公开为 `captureAvailable=false` 和 `ERROR`，不能视为健康空闲。
- **降级的代价：** 后台预采麦、点击麦克风也会静音，可能一直持续到输入法停止采麦；无法从采麦区分实际说话与后台工作。开始/恢复还会受 20ms 目标扫描间隔、HAL 状态和调度延迟影响，不保证与实体键释放同时恢复。HID 可用时不启用采麦降级，不额外增加旧版的 1 秒恢复等待。
- 保留按键前已有的静音。静音写入成功后，即使回读滞后也保留恢复责任；释放后写入或回读失败，会在后续采样继续重试，确认解除静音后才清除责任。
- SIGTERM / SIGINT 退出时最多约 0.5 秒尽力恢复，并记录是否确认成功。单实例锁失败时退出，避免多个实例互相争用。

**限制：** 5ms 是目标采样间隔，不是端到端时延保证；键盘上报、进程调度及音频设备都会增加延迟，不能保证先于输入法开麦，也不能保证识别不漏字。该工具不控制输入法的录音或识别流程。

精确按键模式只覆盖「按住说话」：点麦克风按钮、单击切换录音不会触发；其他应用使用同一个物理键也会静音。释放立即恢复可能使输入法收尾时录到播放声。MMKV 是非公开配置，输入法升级可能使解析失效，届时回退右 Ctrl。降级模式的触发边界与恢复时刻见上方说明。

With HID access, the physical hold key triggers mute. Without it, CG key state OR supported IME capture triggers mute; background capture can keep the output muted until capture stops. Failed writes and delayed readback keep restoration pending. Configuration changes require a service restart.

## 环境与安装

- macOS，已安装 Command Line Tools（`swiftc`）。
- 输入法的「按住说话」快捷键与本工具监听键一致；当前默认/回退键为右 Ctrl。
- 默认输出设备需要可读写的 mute 属性；设备类型不参与判断，已验证可写 mute 的蓝牙音箱也可使用。但不保证所有外接声卡、AirPlay 等设备都暴露该属性；不使用音量归零、暂停播放器或其他设备兜底。
- 原始 HID 需要输入监控权限。启动时仅在未授权时调用 `IOHIDRequestAccess`；系统可能不弹窗，已有拒绝记录时仍需手动处理。请求返回值不等于 GUI 已允许，`unknown` 也不等于 `denied`。

```bash
./install.sh
```

安装先编译临时版本并运行自检，通过后才停止旧服务；旧服务必须确认退出时已履行静音恢复责任，才替换二进制并启动服务。安装到 `~/.local/bin/doubao-audio-duck`，登录服务为 `com.doubao.audio-duck`。`DUCK_FN_HOLD_MS` / `DUCK_FN_CONFIRM_MS` 不再生效。

### 输入监控授权与重编译

安装后会检测 daemon 的权限及 HID 打开结果；未就绪时自动打开「系统设置 → 隐私与安全性 → 输入监控」，同时打印准确添加路径。也可主动执行：

```bash
~/.local/bin/doubao-audio-duck --grant
```

在该面板允许 `doubao-audio-duck`；若未列出，点击 `+`，按 `⌘⇧G` 输入 **`/Users/你的用户名/.local/bin/doubao-audio-duck`**（使用 `--grant` 打印的绝对路径），添加并打开开关。终端的权限归属可能与 LaunchAgent 不同，应允许这个二进制文件，然后执行下方重启命令。最终以 daemon 的启动日志/状态文件中 `hidInput=granted hidStarted=true` 为准，并在实际文本框中按住再松开右 Ctrl，核对 `hold key down/up` 和 `DUCK begin/end`。

**本工具使用 adhoc/linker 签名，不保证跨重编译保留 TCC 授权。** 当前 designated requirement 绑定 `cdhash`，构建变化可能使原授权失效；未创建自签证书或修改钥匙串。表现为 `hidInput=denied/unknown` 或 `hidStarted=false`、醒目错误和降级模式。即使设置里已有旧条目，重装后也要检查；必要时移除旧条目，再用 `+` 添加当前文件并允许，随后重启。安装后检测与降级用于避免失效时静默空转，不代表授权已持久化。

```bash
launchctl kickstart -k "gui/$(id -u)/com.doubao.audio-duck"
```

## 检查

```bash
# 当前输出、启动时将读取的快捷键、当前按键状态、权限与状态文件
~/.local/bin/doubao-audio-duck --dump

# 手动请求输入监控并打开准确设置面板（不会争用单实例锁）
~/.local/bin/doubao-audio-duck --grant

# 仅采样按键，不静音；5 秒内按住 Ctrl（或读取到的配置键）
~/.local/bin/doubao-audio-duck --probe-keys

# 使用模拟音频后端验证按键、恢复责任、写入重试与配置解析，不改变系统声音
~/.local/bin/doubao-audio-duck --self-test

# 日志与服务状态
 tail -30 ~/Library/Logs/doubao-audio-duck.log
 launchctl print "gui/$(id -u)/com.doubao.audio-duck"
```

`duckMode=hold-key`；本机右 Ctrl 配置应显示 `holdKey=62 source=wetype` 与 `holdKeys=[59, 62]`。`--dump` 的 `hidInputMonitoring` / `diagnosticHidStarted` 属于本次诊断进程，`statusFile` 属于 daemon。状态文件 `/tmp/doubao-audio-duck.status` 保留 `idle`、`ducked hold-key`、`held pre-muted`、`mute-pending` / `restore-pending` 前缀，并附加 `pid`、`hidInput=granted/denied/unknown`、`hidStarted`、`hidOpenResult`、`recognitionMode=precise-key/degraded-cg-or-ime-capture` 与采麦可用性。降级的 `hold key down/up` 表示合并触发状态的变化，不证明观察到了物理键。`captureAvailable=false` 时 CG 仍可能工作，但被吞掉的键无法检测，不能仅凭 `idle` 判断工具有效。授权或设备接入变化后请重启服务以重新打开 HID。

强制终止（SIGKILL）、进程崩溃、输出设备切换、多输出路由仍不能保证恢复原设备。按住期间手动修改静音状态也无法区分操作意图。异常终止后若仍静音，可手动解除，或执行：

```bash
~/.local/bin/doubao-audio-duck --force-unmute
```

手动静音 1 秒的诊断命令 `--test-mute` 只能在服务停止时使用，以免干扰服务持有的恢复状态。

## 卸载

```bash
./uninstall.sh
```

现有卸载脚本会强制解除静音，包括原本手动开启的静音；卸载前请留意当前声音状态。

## 文件

- `main.swift`：快捷键配置读取、物理按键控制、静音恢复、诊断与自检。
- `install.sh` / `uninstall.sh`：安装及卸载登录服务。
- `scratch/trace-fn.swift`：历史 Fn/采麦只读诊断，不参与服务运行。
