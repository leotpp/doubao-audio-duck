import Foundation
import CoreAudio
import CoreGraphics
import Carbon
import Darwin
import IOKit.hid

private let fallbackHoldKey = CGKeyCode(kVK_RightControl)
private let logPath = NSHomeDirectory() + "/Library/Logs/doubao-audio-duck.log"
private let statusPath = "/tmp/doubao-audio-duck.status"
private let settingsPath = NSHomeDirectory() + "/Library/Application Support/WeType/mmkv/wetype.settings"
private let modeDescription = "hold-key"
private let logDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private func log(_ msg: String) {
    guard !CommandLine.arguments.contains("--self-test") else { return }
    let line = logDateFormatter.string(from: Date()) + "  " + msg + "\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
}

private func writeStatus(_ s: String) {
    try? (s + "\n").write(toFile: statusPath, atomically: true, encoding: .utf8)
}

private func defaultOutputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var device: AudioDeviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr && device != kAudioObjectUnknown ? device : nil
}

private func outputMuteAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
}

private func systemMuteState() -> Bool? {
    guard let device = defaultOutputDevice() else { return nil }
    var address = outputMuteAddress()
    var muted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
    return status == noErr ? muted != 0 : nil
}

@discardableResult
private func setSystemMuted(_ muted: Bool) -> Bool {
    guard let device = defaultOutputDevice() else { return false }
    var address = outputMuteAddress()
    var value: UInt32 = muted ? 1 : 0
    return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
}

private enum SettingsError: Error { case invalid(String) }

private struct ByteReader {
    let bytes: [UInt8]
    var index = 0
    var isAtEnd: Bool { index == bytes.count }

    mutating func number() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < bytes.count else { throw SettingsError.invalid("truncated varint") }
            let byte = bytes[index]; index += 1
            guard shift != 63 || byte <= 1 else { throw SettingsError.invalid("varint overflow") }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
        }
        throw SettingsError.invalid("varint overflow")
    }

    mutating func blob() throws -> [UInt8] {
        let count = try number()
        guard count <= UInt64(bytes.count - index) else { throw SettingsError.invalid("truncated value") }
        let end = index + Int(count)
        defer { index = end }
        return Array(bytes[index..<end])
    }
}

private let shortcutSettingNames: Set<String> = [
    "voicePTTHotKey", "voicePTTShortcut_keyCodes", "voicePTTShortcut_modifiers", "voicePTTShortcut_tapCount"
]

private func shortcutSettings(_ data: Data) throws -> [String: [UInt8]] {
    let bytes = Array(data)
    guard bytes.count >= 5 else { throw SettingsError.invalid("missing MMKV header") }
    let size = (0..<4).reduce(UInt64(0)) { $0 | UInt64(bytes[$1]) << ($1 * 8) }
    guard size > 0, size <= UInt64(bytes.count - 4) else { throw SettingsError.invalid("invalid MMKV length") }
    // shortcut: WeType 的 MMKV 布局来自逆向与上游格式，升级变更时需更新；失败回退右 Ctrl。
    var reader = ByteReader(bytes: Array(bytes[4..<(4 + Int(size))]))
    _ = try reader.number()
    var values: [String: [UInt8]] = [:]
    while !reader.isAtEnd {
        guard let key = String(bytes: try reader.blob(), encoding: .utf8), !key.isEmpty else {
            throw SettingsError.invalid("invalid MMKV key")
        }
        let value = try reader.blob()
        if shortcutSettingNames.contains(key) {
            if value.isEmpty { values.removeValue(forKey: key) } else { values[key] = value }
        }
    }
    return values
}

private struct HoldShortcut {
    var key = fallbackHoldKey
    var source = "fallback"
    var reason = ""
    var keyCodes: [UInt16]?
    var modifiers: UInt64?
    var tapCount: UInt64?

    static func decode(_ data: Data) -> HoldShortcut {
        var result = HoldShortcut()
        do {
            let values = try shortcutSettings(data)
            func number(_ name: String) throws -> UInt64 {
                guard let bytes = values[name] else { throw SettingsError.invalid("missing \(name)") }
                var reader = ByteReader(bytes: bytes)
                let value = try reader.number()
                guard reader.isAtEnd else { throw SettingsError.invalid("invalid \(name)") }
                return value
            }
            let enabled = try number("voicePTTHotKey")
            guard let rawKeys = values["voicePTTShortcut_keyCodes"] else { throw SettingsError.invalid("missing keyCodes") }
            var reader = ByteReader(bytes: rawKeys)
            let json = try reader.blob()
            guard reader.isAtEnd else { throw SettingsError.invalid("invalid keyCodes length") }
            let keys = try JSONDecoder().decode([UInt16].self, from: Data(json))
            result.keyCodes = keys
            result.modifiers = try number("voicePTTShortcut_modifiers")
            result.tapCount = try number("voicePTTShortcut_tapCount")
            guard enabled == 1 else { throw SettingsError.invalid("WeType push-to-talk disabled") }
            guard result.tapCount == 1, keys.count == 1, let key = keys.first, key < 128 else {
                throw SettingsError.invalid("shortcut is not a single hold key")
            }
            let modifierForKey: [UInt16: UInt64] = [
                54: 1 << 8, 55: 1 << 8, 56: 1 << 9, 60: 1 << 9,
                58: 1 << 11, 61: 1 << 11, 59: 1 << 12, 62: 1 << 12
            ]
            guard key != 63, result.modifiers == (modifierForKey[key] ?? 0) else {
                throw SettingsError.invalid("unsupported modifier combination")
            }
            result.key = key
            result.source = "wetype"
        } catch SettingsError.invalid(let message) {
            result.reason = message
        } catch {
            result.reason = "invalid WeType shortcut encoding"
        }
        return result
    }

    static func load() -> HoldShortcut {
        do { return decode(try Data(contentsOf: URL(fileURLWithPath: settingsPath))) }
        catch { return HoldShortcut(reason: "cannot read WeType settings") }
    }

    // 本机蓝牙键盘把右 Ctrl 报成 59（实测），左右两侧一起监听才能匹配输入法实际收到的键。
    var keys: [CGKeyCode] { key == 59 || key == 62 ? [59, 62] : [key] }

    var summary: String {
        "holdKey=\(key) source=\(source) keyCodes=\(keyCodes.map { String(describing: $0) } ?? "unknown") modifiers=\(modifiers.map { String($0) } ?? "unknown") tapCount=\(tapCount.map { String($0) } ?? "unknown")" + (reason.isEmpty ? "" : " fallbackReason=\(reason)")
    }
}

// 输入法会吞掉自己的按住说话热键，CGEventSource 看不到；原始 HID 层不受影响。
private final class HIDKeyMonitor {
    private var manager: IOHIDManager?
    private var down = Set<CGKeyCode>()
    private(set) var started = false
    private(set) var openResult: IOReturn?

    static func describeAccess(_ access: IOHIDAccessType) -> String {
        switch access {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "unknown"
        }
    }

    static var accessDescription: String { describeAccess(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)) }

    @discardableResult
    static func requestIfNeeded() -> String {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            let accepted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            log("input monitoring request returned=\(accepted) hidInput=\(accessDescription); GUI approval may still be required")
        }
        return accessDescription
    }

    var openDescription: String {
        openResult.map { "\($0) (0x" + String(UInt32(bitPattern: $0), radix: 16) + ")" } ?? "not-attempted"
    }

    func start() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<HIDKeyMonitor>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.openResult = openResult
        self.manager = manager
        started = openResult == kIOReturnSuccess
        return started
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad else { return }
        let key: CGKeyCode
        switch IOHIDElementGetUsage(element) {
        case 0xE0: key = 59  // 左 Ctrl
        case 0xE4: key = 62  // 右 Ctrl
        default: return
        }
        if IOHIDValueGetIntegerValue(value) != 0 { down.insert(key) } else { down.remove(key) }
    }

    func isDown(_ key: CGKeyCode) -> Bool { down.contains(key) }
    var pressed: [CGKeyCode] { down.sorted() }
}

private func holdKeyDown(_ keys: [CGKeyCode], hid: HIDKeyMonitor?) -> Bool {
    keys.contains { key in
        if let hid, hid.started, hid.isDown(key) { return true }
        return CGEventSource.keyState(.hidSystemState, key: key)
    }
}

private let supportedCaptureBundles: Set<String> = [
    "com.tencent.inputmethod.wetype", "com.bytedance.inputmethod.doubaoime"
]

private struct CaptureSnapshot {
    var available: Bool
    var bundles: [String] = []
    var problem = ""
    var capturing: Bool { available && !bundles.isEmpty }
    var summary: String {
        "captureAvailable=\(available) captureBundles=\(bundles)" + (problem.isEmpty ? "" : " captureError=\(problem)")
    }

    static func select(_ processes: [(String, UInt32?)]) -> CaptureSnapshot {
        let supported = processes.filter { supportedCaptureBundles.contains($0.0) }
        let active = supported.filter { ($0.1 ?? 0) != 0 }.map { $0.0 }
        return CaptureSnapshot(available: !supported.contains { $0.1 == nil }, bundles: Array(Set(active)).sorted(),
                               problem: supported.contains { $0.1 == nil } ? "piri-read-failed" : "")
    }
}

private let capturePollIntervalNs: UInt64 = 5_000_000
private let captureEnumerationIntervalNs: UInt64 = 500_000_000

private func captureAddress(_ selector: UInt32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

private struct CaptureProcess {
    let id: AudioObjectID
    let bundle: String
}

private enum CaptureEnumeration {
    case success([CaptureProcess])
    case failure(String)
}

private func enumerateCaptureProcesses() -> CaptureEnumeration {
    var listAddress = captureAddress(0x70727323) // prs#
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    let sizeResult = AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size)
    guard sizeResult == noErr else { return .failure("prs#-size:\(sizeResult)") }
    guard size > 0 else { return .success([]) }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let listResult = AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &ids)
    guard listResult == noErr else { return .failure("prs#-read:\(listResult)") }
    var processes: [CaptureProcess] = []
    for id in ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
        var bundleAddress = captureAddress(0x70626964) // pbid
        var bundle: Unmanaged<CFString>?
        var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let result = AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, &bundle)
        guard result == noErr, let bundle else { return .failure("pbid-read:\(result)") }
        let name = bundle.takeUnretainedValue() as String
        if supportedCaptureBundles.contains(name) { processes.append(CaptureProcess(id: id, bundle: name)) }
    }
    return .success(processes)
}

private func captureInput(_ id: AudioObjectID) -> UInt32? {
    var inputAddress = captureAddress(0x70697269) // piri
    var input: UInt32 = 0
    var inputSize = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &inputAddress, 0, nil, &inputSize, &input) == noErr ? input : nil
}

// Confined to the capture queue. Refreshes can still stall a query; newly created
// process objects can take one enumeration interval to discover. The 5ms target
// applies to cache hits, not to initial discovery or HAL enumeration spikes.
private final class CaptureQuery {
    private let enumerate: () -> CaptureEnumeration
    private let readInput: (AudioObjectID) -> UInt32?
    private var processes: [CaptureProcess] = []
    private var lastEnumeration: UInt64?

    init(enumerate: @escaping () -> CaptureEnumeration = enumerateCaptureProcesses,
         readInput: @escaping (AudioObjectID) -> UInt32? = captureInput) {
        self.enumerate = enumerate
        self.readInput = readInput
    }

    func captureSnapshot(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> CaptureSnapshot {
        func refresh() -> String? {
            processes = []
            lastEnumeration = nil
            switch enumerate() {
            case .success(let values):
                processes = values
                lastEnumeration = now
                return nil
            case .failure(let problem): return problem
            }
        }
        if processes.isEmpty || lastEnumeration.map({ now - $0 >= captureEnumerationIntervalNs }) != false {
            if let problem = refresh() { return CaptureSnapshot(available: false, problem: problem) }
        }
        func sample() -> CaptureSnapshot {
            CaptureSnapshot.select(processes.map { ($0.bundle, readInput($0.id)) })
        }
        let result = sample()
        guard !result.available else { return result }
        // An object may have disappeared. Re-enumerate and retry only once;
        // never publish stale active state or loop indefinitely on HAL failures.
        if let problem = refresh() { return CaptureSnapshot(available: false, problem: problem) }
        let retried = sample()
        if !retried.available { processes = []; lastEnumeration = nil }
        return retried
    }
}

private func recognitionMode(hidStarted: Bool) -> String { hidStarted ? "precise-key" : "degraded-cg-or-ime-capture" }

private func triggerHeld(keyDown: Bool, hidStarted: Bool, capture: CaptureSnapshot) -> Bool {
    keyDown || (!hidStarted && capture.capturing)
}

// Only one HAL query can be in flight; results and all controller state belong to main.
private final class CaptureMonitor {
    private let queue = DispatchQueue(label: "com.doubao.audio-duck.capture")
    private let query = CaptureQuery()
    private var inFlight = false
    private var lastQuery: UInt64 = 0
    private var lastSummary = ""
    private(set) var snapshot = CaptureSnapshot(available: false, problem: "not-sampled")

    func poll() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard !inFlight, now - lastQuery >= capturePollIntervalNs else { return }
        lastQuery = now; inFlight = true
        queue.async {
            let result = self.query.captureSnapshot()
            DispatchQueue.main.async {
                self.inFlight = false
                self.snapshot = result
                if result.summary != self.lastSummary {
                    self.lastSummary = result.summary
                    log("\(result.available ? "fallback capture" : "ERROR fallback capture unavailable; swallowed hold key cannot be detected:") \(result.summary)")
                }
            }
        }
    }
}

private func grantAccess() {
    print("hidInputBefore=\(HIDKeyMonitor.accessDescription)")
    print("hidInputAfter=\(HIDKeyMonitor.requestIfNeeded())")
    let binary = NSHomeDirectory() + "/.local/bin/doubao-audio-duck"
    print("系统设置 → 隐私与安全性 → 输入监控：打开开关；如未列出，用 + 添加：\(binary)")
    print("终端请求与 LaunchAgent 的权限归属可能不同；请求返回值不代表 daemon 已获授权。")
    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    opener.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]
    do { try opener.run(); opener.waitUntilExit(); print("settingsOpenExit=\(opener.terminationStatus)") }
    catch { print("无法自动打开系统设置：\(error)") }
    print("授权后重启：launchctl kickstart -k gui/$(id -u)/com.doubao.audio-duck")
}

private final class DuckController {
    private let readMute: () -> Bool?
    private let writeMute: (Bool) -> Bool
    private let publishStatus: (String) -> Void
    private var mutedBefore: Bool?
    private var requestedMute: Bool?
    private var lastStatus: String?
    private var lastProblem: String?
    private var lastProblemAt: UInt64 = 0
    private(set) var keyHeld = false
    var needsRestore: Bool { mutedBefore == false }

    init(readMute: @escaping () -> Bool? = systemMuteState,
         writeMute: @escaping (Bool) -> Bool = setSystemMuted,
         publishStatus: @escaping (String) -> Void = writeStatus) {
        self.readMute = readMute; self.writeMute = writeMute; self.publishStatus = publishStatus
    }

    private func status(_ value: String) {
        guard value != lastStatus else { return }
        lastStatus = value
        publishStatus(value)
    }

    private func problem(_ value: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        if value != lastProblem || now - lastProblemAt >= 500_000_000 {
            log(value); lastProblem = value; lastProblemAt = now
        }
    }

    // 写入与回读不同步时保留原始状态，绝不把自己的静音重新当成用户静音。
    private func reconcile(muted: Bool) -> Bool {
        if requestedMute == muted, readMute() == muted {
            status(muted ? "ducked hold-key" : "idle")
            lastProblem = nil
            return true
        }
        guard writeMute(muted) else {
            status(muted ? "mute-pending" : "restore-pending")
            problem("DUCK write failed targetMuted=\(muted); retaining restore responsibility")
            return false
        }
        requestedMute = muted
        guard readMute() == muted else {
            status(muted ? "mute-pending" : "restore-pending")
            problem("DUCK readback pending targetMuted=\(muted) (write accepted); retaining restore responsibility")
            return false
        }
        status(muted ? "ducked hold-key" : "idle")
        lastProblem = nil
        return true
    }

    func update(held: Bool) {
        if held != keyHeld {
            keyHeld = held
            log("hold key \(held ? "down" : "up")")
        }
        if held {
            if mutedBefore == nil {
                guard let before = readMute() else {
                    problem("DUCK cannot read initial mute state; retrying")
                    return
                }
                mutedBefore = before
                log("DUCK begin mutedBefore=\(before)")
            }
            if mutedBefore == true { status("held pre-muted"); return }
            _ = reconcile(muted: true)
        } else if let before = mutedBefore {
            if before || reconcile(muted: false) {
                mutedBefore = nil; requestedMute = nil
                status("idle")
                log("DUCK end restoredMuted=\(before)")
            }
        } else {
            status("idle")
        }
    }

    func restoreBeforeExit() -> Bool {
        for _ in 0..<100 {
            update(held: false)
            if !needsRestore { return true }
            usleep(5_000)
        }
        log("emergency restore unconfirmed; output may still be muted")
        return false
    }
}

private var lockFD: Int32 = -1

private func acquireSingletonLock() {
    lockFD = open("/tmp/doubao-audio-duck.lock", O_CREAT | O_RDWR, 0o644)
    guard lockFD >= 0 else { log("could not open lock file; exiting"); exit(1) }
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        if errno == EWOULDBLOCK { log("another instance holds the lock, exiting"); exit(0) }
        log("could not acquire lock; exiting"); exit(1)
    }
}

private func runDaemon() {
    acquireSingletonLock()
    let shortcut = HoldShortcut.load()
    let hid = HIDKeyMonitor()
    let access = HIDKeyMonitor.requestIfNeeded()
    let hidStarted = hid.start()
    let mode = recognitionMode(hidStarted: hidStarted)
    let channel = "hidInput=\(access) hidStarted=\(hidStarted) hidOpenResult=\(hid.openDescription) recognitionMode=\(mode)"
    log("started pid=\(ProcessInfo.processInfo.processIdentifier) mode=\(modeDescription) \(channel)")
    log("shortcut \(shortcut.summary) holdKeys=\(shortcut.keys) keyPollIntervalMs=5")
    if !hidStarted {
        log("ERROR 物理按键通道不可用，精确按键模式此刻无效；启用 CG 或输入法采麦降级。运行 ~/.local/bin/doubao-audio-duck --grant")
        log("degraded capturePollIntervalMs=\(capturePollIntervalNs / 1_000_000) captureEnumerationIntervalMs=\(captureEnumerationIntervalNs / 1_000_000); background pre-capture/click recording can mute until capture stops; release timing is approximate")
    }
    let capture = CaptureMonitor()
    var audioStatus = "idle"
    var lastPublished = ""
    func publish() {
        let health = hidStarted ? "captureAvailable=not-used" : capture.snapshot.summary
        let value = "\(audioStatus) pid=\(ProcessInfo.processInfo.processIdentifier) \(channel) \(health)"
        if value != lastPublished { writeStatus(value); lastPublished = value }
    }
    let duck = DuckController(publishStatus: { audioStatus = $0; publish() })
    publish()
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .nanoseconds(0))
    timer.setEventHandler {
        if !hidStarted { capture.poll() }
        duck.update(held: triggerHeld(keyDown: holdKeyDown(shortcut.keys, hid: hid), hidStarted: hidStarted, capture: capture.snapshot))
        publish()
    }
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let signals = [SIGTERM, SIGINT].map { sig in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            timer.cancel()
            let restored = duck.restoreBeforeExit()
            log("emergency restore signal=\(sig) confirmed=\(restored)")
            exit(restored ? 0 : 1)
        }
        source.resume()
        return source
    }
    timer.resume()
    withExtendedLifetime((timer, signals, hid)) { RunLoop.main.run() }
}

private func runSelfTest() {
    var failures: [String] = []
    var assertions = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures.append(message) }
    }
    final class FakeAudio {
        var muted = false
        var reads: [Bool?] = []
        var writes: [Bool] = []
        var failuresRemaining = 0
        func read() -> Bool? { reads.isEmpty ? muted : reads.removeFirst() }
        func write(_ value: Bool) -> Bool {
            writes.append(value)
            if failuresRemaining > 0 { failuresRemaining -= 1; return false }
            muted = value; return true
        }
        func controller() -> DuckController {
            DuckController(readMute: { self.read() }, writeMute: { self.write($0) }, publishStatus: { _ in })
        }
    }
    do {
        let audio = FakeAudio(), duck = audio.controller()
        duck.update(held: false)
        expect(audio.writes.isEmpty, "idle changed audio")
        duck.update(held: true); duck.update(held: true)
        expect(audio.muted && audio.writes == [true], "hold did not mute exactly once")
        duck.update(held: false); duck.update(held: false)
        expect(!audio.muted && audio.writes == [true, false] && !duck.needsRestore, "release did not restore")
    }
    do {
        let audio = FakeAudio(); audio.muted = true
        let duck = audio.controller()
        duck.update(held: true); duck.update(held: true); duck.update(held: false)
        expect(audio.muted && audio.writes.isEmpty, "pre-existing user mute changed")
    }
    do {
        let audio = FakeAudio(); audio.reads = [false, false]
        let duck = audio.controller()
        duck.update(held: true)
        expect(duck.needsRestore, "stale mute readback discarded restore responsibility")
        duck.update(held: true); duck.update(held: false)
        expect(!audio.muted && audio.writes == [true, false], "stale mute readback prevented restoration")
    }
    do {
        let audio = FakeAudio(); audio.reads = [false, nil]
        let duck = audio.controller()
        duck.update(held: true); duck.update(held: false)
        expect(!audio.muted && !duck.needsRestore, "unknown mute readback prevented restoration")
    }
    do {
        let audio = FakeAudio(), duck = audio.controller()
        duck.update(held: true); audio.failuresRemaining = 1
        duck.update(held: false)
        expect(duck.needsRestore && audio.muted, "failed restoration discarded responsibility")
        duck.update(held: false)
        expect(!audio.muted && !duck.needsRestore && audio.writes == [true, false, false], "restoration was not retried")
    }
    do {
        let audio = FakeAudio(), duck = audio.controller()
        duck.update(held: true); audio.reads = [true, nil]
        duck.update(held: false)
        expect(duck.needsRestore, "stale restoration readback discarded responsibility")
        duck.update(held: false)
        expect(!audio.muted && !duck.needsRestore, "unknown restoration readback was not retried")
    }
    do {
        let audio = FakeAudio(), duck = audio.controller()
        duck.update(held: true); audio.reads = [true]
        duck.update(held: false); duck.update(held: true)
        expect(audio.muted && duck.needsRestore && audio.writes == [true, false, true], "re-press did not cancel pending restoration")
        duck.update(held: false)
        expect(!audio.muted && !duck.needsRestore, "re-press lost original unmuted state")
    }
    do {
        let audio = FakeAudio(); audio.failuresRemaining = 1
        let duck = audio.controller()
        duck.update(held: true); duck.update(held: true); duck.update(held: false)
        expect(!audio.muted && audio.writes == [true, true, false], "failed mute was not retried")
    }
    do {
        let audio = FakeAudio(); audio.reads = [nil, false]
        let duck = audio.controller()
        duck.update(held: true)
        expect(audio.writes.isEmpty, "unknown initial state was overwritten")
        duck.update(held: true)
        expect(audio.muted, "initial read failure was not retried")
        expect(duck.restoreBeforeExit() && !audio.muted, "signal-equivalent cleanup did not restore")
    }
    func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat {
            let byte = UInt8(value & 0x7f); value >>= 7
            bytes.append(byte | (value == 0 ? 0 : 0x80))
        } while value != 0
        return bytes
    }
    func stringValue(_ value: String) -> [UInt8] { varint(UInt64(value.utf8.count)) + value.utf8 }
    func fixture(_ extra: [(String, [UInt8])] = []) -> Data {
        let entries: [(String, [UInt8])] = [
            ("voicePTTHotKey", [1]), ("voicePTTShortcut_keyCodes", stringValue("[62]")),
            ("voicePTTShortcut_modifiers", varint(4096)), ("voicePTTShortcut_tapCount", [1])
        ] + extra
        var payload: [UInt8] = [0xff, 0xff, 0xff, 0x07]
        for (key, value) in entries {
            payload += varint(UInt64(key.utf8.count)) + key.utf8 + varint(UInt64(value.count)) + value
        }
        let count = UInt32(payload.count)
        return Data((0..<4).map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) } + payload + [0xff, 0xff])
    }
    let config = HoldShortcut.decode(fixture())
    expect(config.key == 62 && config.source == "wetype" && config.modifiers == 4096, "right Ctrl configuration was not decoded")
    expect(config.keys == [59, 62], "Control shortcut should watch both Ctrl sides")
    let changed = HoldShortcut.decode(fixture([
        ("voicePTTShortcut_keyCodes", stringValue("[61]")), ("voicePTTShortcut_modifiers", varint(2048))
    ]))
    expect(changed.key == 61 && changed.source == "wetype", "latest appended shortcut did not win")
    let normal = HoldShortcut.decode(fixture([
        ("voicePTTShortcut_keyCodes", stringValue("[49]")), ("voicePTTShortcut_modifiers", [0])
    ]))
    expect(normal.key == 49 && normal.source == "wetype", "unmodified single key was rejected")
    expect(normal.keys == [49], "plain shortcut should watch only its key")
    for (name, extra) in [
        ("disabled", [("voicePTTHotKey", [UInt8(0)])]),
        ("deleted", [("voicePTTHotKey", [])]),
        ("chord", [("voicePTTShortcut_keyCodes", stringValue("[62,49]"))]),
        ("modifiers", [("voicePTTShortcut_modifiers", varint(256))]),
        ("multiple taps", [("voicePTTShortcut_tapCount", [UInt8(2)])]),
        ("string length", [("voicePTTShortcut_keyCodes", [UInt8(10), 91, 54, 50, 93])]),
        ("varint overflow", [("voicePTTShortcut_modifiers", Array(repeating: UInt8(255), count: 10))])
    ] {
        let value = HoldShortcut.decode(fixture(extra))
        expect(value.key == 62 && value.source == "fallback" && !value.reason.isEmpty, "invalid \(name) did not fall back")
    }
    var truncated = fixture(); truncated.removeLast(3)
    expect(HoldShortcut.decode(truncated).source == "fallback", "truncated MMKV payload was accepted")
    expect(HoldShortcut.decode(Data([0xff, 0xff, 0xff, 0xff, 0])).source == "fallback", "oversized MMKV payload was accepted")
    expect(HoldShortcut.decode(Data()).source == "fallback", "missing MMKV file did not fall back")
    expect(HIDKeyMonitor.describeAccess(kIOHIDAccessTypeGranted) == "granted", "granted access mislabeled")
    expect(HIDKeyMonitor.describeAccess(kIOHIDAccessTypeDenied) == "denied", "denied access mislabeled")
    expect(HIDKeyMonitor.describeAccess(kIOHIDAccessTypeUnknown) == "unknown", "unknown access mislabeled")
    let idleCapture = CaptureSnapshot.select([])
    let wetypeCapture = CaptureSnapshot.select([("com.tencent.inputmethod.wetype", 1)])
    let doubaoCapture = CaptureSnapshot.select([("com.bytedance.inputmethod.doubaoime", 1)])
    let unknownCapture = CaptureSnapshot.select([("com.tencent.inputmethod.wetype", nil)])
    expect(idleCapture.available && !idleCapture.capturing, "empty process list is not healthy idle")
    expect(wetypeCapture.capturing && doubaoCapture.capturing, "supported input method capture was ignored")
    expect(!CaptureSnapshot.select([("com.other.recorder", 1)]).capturing, "unrelated bundle triggered fallback")
    expect(!unknownCapture.available && !unknownCapture.capturing && !unknownCapture.problem.isEmpty, "unknown query became healthy idle")
    expect(!CaptureSnapshot(available: false, problem: "list-failed").available, "list failure became available")
    expect(recognitionMode(hidStarted: true) == "precise-key" && recognitionMode(hidStarted: false) == "degraded-cg-or-ime-capture", "recognition mode selection failed")
    expect(!triggerHeld(keyDown: false, hidStarted: true, capture: wetypeCapture), "capture affected precise key mode")
    expect(triggerHeld(keyDown: true, hidStarted: false, capture: unknownCapture), "CG key fallback was blocked by capture error")
    do {
        let audio = FakeAudio(), duck = audio.controller()
        duck.update(held: triggerHeld(keyDown: false, hidStarted: false, capture: wetypeCapture))
        expect(audio.muted && duck.needsRestore, "capture start did not mute with restoration ownership")
        duck.update(held: triggerHeld(keyDown: false, hidStarted: false, capture: idleCapture))
        expect(!audio.muted && !duck.needsRestore, "capture stop did not restore")
        duck.update(held: triggerHeld(keyDown: false, hidStarted: false, capture: unknownCapture))
        expect(audio.writes == [true, false], "unknown capture unexpectedly muted")
    }
    do {
        let process = CaptureProcess(id: 1, bundle: "com.tencent.inputmethod.wetype")
        var enumerations = 0
        var reads: [AudioObjectID] = []
        var value: UInt32 = 0
        let query = CaptureQuery(enumerate: {
            enumerations += 1
            return .success([process])
        }, readInput: { id in reads.append(id); return value })
        expect(query.captureSnapshot(now: 0).available && enumerations == 1 && reads == [1], "first capture query did not enumerate and sample")
        value = 1
        expect(query.captureSnapshot(now: 5_000_000).capturing && enumerations == 1 && reads == [1, 1], "cache hit did not sample without enumeration")
        _ = query.captureSnapshot(now: captureEnumerationIntervalNs - 1)
        expect(enumerations == 1, "cache expired before its boundary")
        expect(query.captureSnapshot(now: captureEnumerationIntervalNs).capturing && enumerations == 2, "cache did not refresh exactly at expiry")
    }
    do {
        var enumerations = 0
        let query = CaptureQuery(enumerate: { enumerations += 1; return .success([]) },
                                 readInput: { _ in failures.append("empty cache read an object"); return nil })
        let first = query.captureSnapshot(now: 0)
        let next = query.captureSnapshot(now: 1)
        expect(first.available && !first.capturing && next.available && enumerations == 2, "empty cache was not retried on next query")
    }
    do {
        let process = CaptureProcess(id: 1, bundle: "com.tencent.inputmethod.wetype")
        let replacement = CaptureProcess(id: 2, bundle: "com.bytedance.inputmethod.doubaoime")
        var enumerations = 0
        var missing = false
        var refreshFailure = false
        var reads: [AudioObjectID] = []
        let query = CaptureQuery(enumerate: {
            enumerations += 1
            if refreshFailure { return .failure("prs#-read:test") }
            return .success([missing ? replacement : process])
        }, readInput: { id in
            reads.append(id)
            return missing && id == 1 ? nil : 1
        })
        expect(query.captureSnapshot(now: 0).capturing, "disappearance fixture did not start active")
        missing = true
        let replaced = query.captureSnapshot(now: 1)
        expect(replaced.bundles == [replacement.bundle] && enumerations == 2 && reads == [1, 1, 2], "missing process did not immediately refresh and read replacement once")
        refreshFailure = true
        let failed = query.captureSnapshot(now: captureEnumerationIntervalNs + 1)
        expect(!failed.available && !failed.capturing && failed.problem == "prs#-read:test", "failed refresh published stale capture")
        refreshFailure = false
        expect(query.captureSnapshot(now: captureEnumerationIntervalNs + 2).capturing && enumerations == 4, "failed refresh did not recover on next query")
    }
    do {
        let process = CaptureProcess(id: 1, bundle: "com.tencent.inputmethod.wetype")
        var enumerations = 0
        var value: UInt32? = nil
        let query = CaptureQuery(enumerate: { enumerations += 1; return .success([process]) },
                                 readInput: { _ in value })
        let failed = query.captureSnapshot(now: 0)
        expect(!failed.available && failed.problem == "piri-read-failed" && enumerations == 2, "persistent piri failure did not stop after one retry")
        value = 1
        expect(query.captureSnapshot(now: 1).capturing && enumerations == 3, "persistent piri failure did not invalidate cache for recovery")
    }
    if failures.isEmpty {
        print("self-test passed: \(assertions) assertions (hold, ownership, MMKV, permissions, capture fallback)")
    } else {
        for failure in failures { print("self-test failed: \(failure)") }
        exit(1)
    }
}

private func dumpDebug() {
    let shortcut = HoldShortcut.load()
    print("systemMuted=\(systemMuteState().map { String($0) } ?? "unknown")")
    print(shortcut.summary)
    print("holdKeys=\(shortcut.keys)")
    print("holdKeyDown=\(holdKeyDown(shortcut.keys, hid: nil))")
    print("hidInputMonitoring=\(HIDKeyMonitor.accessDescription)")
    print("diagnosticProcessPid=\(ProcessInfo.processInfo.processIdentifier) (permission above belongs to this process; daemon fields are in statusFile)")
    let hid = HIDKeyMonitor()
    _ = hid.start()
    print("diagnosticHidStarted=\(hid.started) hidOpenResult=\(hid.openDescription)")
    print("diagnosticRecognitionMode=\(recognitionMode(hidStarted: hid.started))")
    print(CaptureQuery().captureSnapshot().summary)
    print("capturePollIntervalMs=\(capturePollIntervalNs / 1_000_000) captureEnumerationIntervalMs=\(captureEnumerationIntervalNs / 1_000_000) (degraded mode only)")
    print("duckMode=\(modeDescription)")
    print("keyPollIntervalMs=5")
    if let text = try? String(contentsOfFile: statusPath, encoding: .utf8) {
        print("statusFile=\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--self-test") {
    runSelfTest()
} else if args.contains("--grant") {
    grantAccess()
} else if args.contains("--dump") || args.contains("--status") {
    dumpDebug()
} else if args.contains("--probe-keys") {
    let shortcut = HoldShortcut.load()
    print(shortcut.summary)
    let hid = HIDKeyMonitor()
    let hidStarted = hid.start()
    print("hidInput=\(HIDKeyMonitor.accessDescription) hidStarted=\(hidStarted)")
    print("采样 5 秒，请按住\(shortcut.key == 62 || shortcut.key == 59 ? " Ctrl" : "快捷键 keyCode=\(shortcut.key)")…")
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    var seen = false
    var lastPressed: [CGKeyCode] = []
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if hid.pressed != lastPressed {
            lastPressed = hid.pressed
            print("hidDown=\(lastPressed)")
        }
        if holdKeyDown(shortcut.keys, hid: hid) && !seen { seen = true; print("holdKeyDown=true") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    print(seen ? "hold key detected" : "未观察到按键：请确认按的是输入法的按住说话快捷键。")
} else if args.contains("--test-mute") {
    acquireSingletonLock()
    let duck = DuckController(publishStatus: { _ in })
    print("muting 1s…")
    duck.update(held: true)
    Thread.sleep(forTimeInterval: 1)
    let restored = duck.restoreBeforeExit()
    print(restored ? "restored" : "restore unconfirmed")
    exit(restored ? 0 : 1)
} else if args.contains("--force-unmute") {
    if setSystemMuted(false) { print("restore requested") }
    else { print("restore failed"); exit(1) }
} else {
    runDaemon()
}
