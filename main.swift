import Foundation
import CoreAudio
import CoreGraphics
import Carbon
import AppKit
import Darwin

/// Ducks (mutes) system output while Doubao IME is recording.
/// MicPause cannot see IME capture and cannot pause webpage players.
/// Muting the default output silences Safari/Chrome/any app, then restores.

private let doubaoBundleID = "com.bytedance.inputmethod.doubaoime"
private let logPath = NSHomeDirectory() + "/Library/Logs/doubao-audio-duck.log"
private let statusPath = "/tmp/doubao-audio-duck.status"
private let logDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let kProcessObjectList: AudioObjectPropertySelector = 0x70727323 // 'prs#'
private let kProcessPID: AudioObjectPropertySelector = 0x70706964        // 'ppid'
private let kProcessBundleID: AudioObjectPropertySelector = 0x70626964   // 'pbid'
private let kProcessIsRunningInput: AudioObjectPropertySelector = 0x70697269 // 'piri'

private func log(_ msg: String) {
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
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var device: AudioDeviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
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
    guard let device = defaultOutputDevice() else {
        log("output mute unavailable: no default output device")
        return false
    }
    var address = outputMuteAddress()
    var value: UInt32 = muted ? 1 : 0
    let size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    if status != noErr {
        log("output mute failed muted=\(muted) status=\(status)")
        return false
    }
    return true
}

private func audioUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

private func audioString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return nil }
    var unmanaged: Unmanaged<CFString>?
    var sz = size
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &sz, &unmanaged)
    guard status == noErr, let unmanaged else { return nil }
    return unmanaged.takeUnretainedValue() as String
}

private func processObjectIDs() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let sys = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    var sz = size
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &sz, &ids) == noErr else { return [] }
    return ids
}

private func doubaoHALCapturing() -> Bool {
    for id in processObjectIDs() {
        let bid = audioString(id, kProcessBundleID) ?? ""
        if bid == doubaoBundleID {
            if (audioUInt32(id, kProcessIsRunningInput) ?? 0) != 0 {
                return true
            }
        }
    }
    return false
}

private func screensUnion() -> CGRect {
    var u = CGRect.null
    for screen in NSScreen.screens {
        u = u.union(screen.frame)
    }
    return u.isNull ? CGRect(x: 0, y: 0, width: 1920, height: 1080) : u
}

/// CGWindow bounds are top-left origin. NSScreen.frame is bottom-left.
private func cgWindowRect(_ bounds: [String: Any]) -> CGRect {
    let x = (bounds["X"] as? NSNumber)?.doubleValue ?? 0
    let y = (bounds["Y"] as? NSNumber)?.doubleValue ?? 0
    let w = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
    let h = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
    return CGRect(x: x, y: y, width: w, height: h)
}

private func windowVisibleOnAScreen(_ cgRect: CGRect) -> Bool {
    // Convert CGWindow top-left rect into Cocoa bottom-left using the union of screens.
    let screens = screensUnion()
    let cocoa = CGRect(
        x: cgRect.origin.x,
        y: screens.maxY - cgRect.origin.y - cgRect.height,
        width: cgRect.width,
        height: cgRect.height
    )
    for screen in NSScreen.screens {
        let inter = screen.frame.intersection(cocoa)
        // Parked-off-the-edge panels can share 0–2px with the display. Require a real visible chunk.
        if !inter.isNull && inter.width >= 80 && inter.height >= 30 {
            return true
        }
    }
    return false
}

/// Doubao parks the idle voice bar flush against a display's right edge
/// (x ≈ screenMaxX − width), not past it. On a 2560-wide panel that is
/// around x=1917 and looks fully on-screen, which used to false-trigger ducking.
private func overlayParkedAgainstRightEdge(_ cgRect: CGRect) -> Bool {
    for screen in NSScreen.screens {
        let maxX = screen.frame.maxX
        let minX = screen.frame.minX
        let flush = maxX - cgRect.width
        if abs(cgRect.origin.x - flush) <= 48 { return true }
        if cgRect.origin.x >= maxX - 24 { return true }
        if cgRect.maxX <= minX + 24 { return true }
    }
    return false
}

/// Doubao's voice overlay uses a very high window layer; the typing candidate bar does not.
/// Idle, that overlay sits flush with a screen's right edge — that is not recording.
private func doubaoRecordingOverlayVisible() -> (Bool, String) {
    guard let info = CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else { return (false, "") }

    for win in info {
        let owner = win[kCGWindowOwnerName as String] as? String ?? ""
        guard owner.contains("豆包输入法") || owner.lowercased().contains("doubaoime") else { continue }
        let onscreen = (win[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        guard onscreen else { continue }
        let layer = win[kCGWindowLayer as String] as? Int ?? 0
        let bounds = win[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let rect = cgWindowRect(bounds)
        guard layer >= 100 && rect.width >= 180 && rect.height >= 40 else { continue }
        if overlayParkedAgainstRightEdge(rect) { continue }
        if windowVisibleOnAScreen(rect) {
            return (true, "layer=\(layer) \(Int(rect.width))x\(Int(rect.height)) @\(Int(rect.origin.x)),\(Int(rect.origin.y))")
        }
    }
    return (false, "")
}

private func currentInputSourceIsDoubao() -> Bool {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
    guard let raw = TISGetInputSourceProperty(src, kTISPropertyBundleID) else { return false }
    let bid = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    return bid == doubaoBundleID
}

private func monotonicNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

private func durationMilliseconds(_ nanoseconds: UInt64) -> Int {
    Int(nanoseconds / 1_000_000)
}

private struct FnHoldGate {
    enum Event {
        case pressed(generation: UInt64)
        case released(generation: UInt64, durationNanoseconds: UInt64)
    }

    private(set) var held = false
    private(set) var generation: UInt64 = 0
    private var pressedAt: UInt64?

    mutating func update(held: Bool, at now: UInt64) -> Event? {
        guard held != self.held else { return nil }
        self.held = held
        generation &+= 1
        if held {
            pressedAt = now
            return .pressed(generation: generation)
        }

        let duration = pressedAt.map { now >= $0 ? now - $0 : 0 } ?? 0
        pressedAt = nil
        return .released(generation: generation, durationNanoseconds: duration)
    }
}

/// Fn is only corroboration, not proof of voice recording: macOS also sets the
/// Fn flag for shortcuts such as Fn-Up/Fn-Down in terminals and candidate UIs.
private struct FnCorroborationGate {
    let windowNanoseconds: UInt64
    private(set) var deadline: UInt64 = 0

    mutating func noteFnActivity(at now: UInt64) {
        deadline = now &+ windowNanoseconds
    }

    func isRecent(fnHeld: Bool, at now: UInt64) -> Bool {
        fnHeld || now < deadline
    }

    func allowsDuckStart(
        fnHeld: Bool,
        at now: UInt64,
        inputSourceIsDoubao: Bool,
        recordingEvidenceIsStable: Bool
    ) -> Bool {
        isRecent(fnHeld: fnHeld, at: now)
            && inputSourceIsDoubao
            && recordingEvidenceIsStable
    }
}

private func hardwareFnHeld() -> Bool {
    CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
}

private final class DuckController {
    private var duckedByUs = false
    private var mutedBefore = false
    private var fnGate = FnHoldGate()
    private var restoreWork: DispatchWorkItem?
    private let restoreDelay: TimeInterval = 1.0
    private let sustainStableNanoseconds: UInt64 = 320_000_000
    private var overlayStartedAt: UInt64?
    private var halStartedAt: UInt64?
    private var overlayInfo = ""
    private var sustainActive = false
    /// Keep a window so recording evidence that follows a short Fn click can
    /// start the duck, while unrelated Fn shortcuts remain insufficient.
    private static let fnCorroborationNanoseconds: UInt64 = 1_200_000_000
    private var fnCorroboration = FnCorroborationGate(
        windowNanoseconds: DuckController.fnCorroborationNanoseconds
    )

    /// Last-resort restore used on SIGTERM/SIGINT so a killed daemon
    /// never leaves the system muted. Runs before exit.
    func emergencyRestore(_ why: String) {
        restoreWork?.cancel()
        if duckedByUs && !mutedBefore {
            _ = setSystemMuted(false)
        }
        writeStatus("idle")
        log("emergency restore (\(why)) duckedByUs=\(duckedByUs) mutedBefore=\(mutedBefore)")
        exit(0)
    }

    func handleFnChanged(_ held: Bool, source: String) {
        let now = monotonicNanoseconds()
        guard let event = fnGate.update(held: held, at: now) else { return }

        fnCorroboration.noteFnActivity(at: now)

        switch event {
        case .pressed(let generation):
            // A re-press cancels a pending restore immediately. It must still
            // be corroborated by a stable Doubao recording signal before mute.
            restoreWork?.cancel()
            restoreWork = nil
            log("Fn down source=\(source) generation=\(generation)")

        case .released(let generation, let durationNanoseconds):
            log("Fn up source=\(source) generation=\(generation) durationMs=\(durationMilliseconds(durationNanoseconds))")
            if duckedByUs {
                scheduleRestoreIfIdle(reason: "fn-up")
            }
        }
    }

    /// Overlay and HAL are corroboration/sustain signals. They cannot start a
    /// duck on their own, but after a recent Fn press they can start it —
    /// including click-to-record and double-tap continuous recording.
    func pollSustain() {
        let now = monotonicNanoseconds()
        let fnRecent = fnCorroboration.isRecent(fnHeld: fnGate.held, at: now)
        guard duckedByUs || fnRecent else { return }

        let (overlayNow, info) = doubaoRecordingOverlayVisible()
        if overlayNow {
            overlayStartedAt = overlayStartedAt ?? now
            overlayInfo = info
        } else {
            overlayStartedAt = nil
            overlayInfo = ""
        }

        if doubaoHALCapturing() {
            halStartedAt = halStartedAt ?? now
        } else {
            halStartedAt = nil
        }

        let overlayStable = isStable(since: overlayStartedAt, now: now)
        let halStable = isStable(since: halStartedAt, now: now)
        let newSustainActive = overlayStable || halStable
        if newSustainActive != sustainActive {
            sustainActive = newSustainActive
            if newSustainActive {
                let reason = overlayStable ? "overlay[\(overlayInfo)]" : "hal"
                log("sustain on (\(reason))")
            } else {
                log("sustain off")
            }
        }

        if !duckedByUs {
            guard fnCorroboration.allowsDuckStart(
                fnHeld: fnGate.held,
                at: now,
                inputSourceIsDoubao: currentInputSourceIsDoubao(),
                recordingEvidenceIsStable: newSustainActive
            ) else { return }
            let reason = overlayStable ? "overlay[\(overlayInfo)]" : "hal"
            applyDuck(true, reason: reason)
            return
        }

        if fnGate.held || sustainActive {
            restoreWork?.cancel()
            restoreWork = nil
        } else {
            scheduleRestoreIfIdle(reason: "idle")
        }
    }

    private func isStable(since: UInt64?, now: UInt64) -> Bool {
        guard let since, now >= since else { return false }
        return now - since >= sustainStableNanoseconds
    }

    private func scheduleRestoreIfIdle(reason: String) {
        guard duckedByUs, !fnGate.held, !sustainActive, restoreWork == nil else { return }
        let generation = fnGate.generation
        let work = DispatchWorkItem { [weak self] in
            self?.restoreIfStillIdle(generation: generation, reason: reason)
        }
        restoreWork = work
        log("restore scheduled reason=\(reason) generation=\(generation) delayMs=\(Int(restoreDelay * 1000))")
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
    }

    private func restoreIfStillIdle(generation: UInt64, reason: String) {
        restoreWork = nil
        guard generation == fnGate.generation, !fnGate.held, !sustainActive else {
            log("restore skipped generation=\(generation) current=\(fnGate.generation) fnHeld=\(fnGate.held) sustain=\(sustainActive)")
            return
        }
        applyDuck(false, reason: reason)
    }

    private func applyDuck(_ on: Bool, reason: String) {
        if on {
            if duckedByUs { return }
            guard let before = systemMuteState() else {
                log("DUCK failed (\(reason)): cannot read output mute state")
                return
            }
            mutedBefore = before
            if !mutedBefore && !setSystemMuted(true) { return }
            duckedByUs = true
            writeStatus("ducked \(reason)")
            log("DUCK on (\(reason)) mutedBefore=\(mutedBefore)")
        } else {
            if !duckedByUs { return }
            if !mutedBefore {
                guard setSystemMuted(false) else {
                    log("DUCK restore failed (\(reason)); keeping ownership state")
                    return
                }
            }
            duckedByUs = false
            writeStatus("idle")
            log("DUCK off (\(reason)) restoredMuted=\(mutedBefore)")
        }
    }
}

private func combinedFnHeld() -> Bool {
    CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
}

private func runSelfTest() {
    var gate = FnHoldGate()
    var corroboration = FnCorroborationGate(windowNanoseconds: 1_200_000_000)
    var failures: [String] = []

    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    _ = gate.update(held: true, at: 0)
    expect(gate.held, "Fn press was not recorded")
    let firstGeneration = gate.generation
    _ = gate.update(held: false, at: 50_000_000)
    expect(!gate.held, "Fn release was not recorded")
    _ = gate.update(held: true, at: 60_000_000)
    expect(gate.generation != firstGeneration, "release/re-press did not create a new generation")

    corroboration.noteFnActivity(at: 0)
    expect(!corroboration.allowsDuckStart(
        fnHeld: true, at: 400_000_000, inputSourceIsDoubao: true, recordingEvidenceIsStable: false
    ), "Fn-only shortcut could start ducking")
    expect(corroboration.allowsDuckStart(
        fnHeld: true, at: 400_000_000, inputSourceIsDoubao: true, recordingEvidenceIsStable: true
    ), "Fn plus stable recording evidence could not start ducking")
    expect(!corroboration.allowsDuckStart(
        fnHeld: false, at: 1_200_000_000, inputSourceIsDoubao: true, recordingEvidenceIsStable: true
    ), "expired Fn corroboration could start ducking")
    expect(!corroboration.allowsDuckStart(
        fnHeld: false, at: 400_000_000, inputSourceIsDoubao: false, recordingEvidenceIsStable: true
    ), "non-Doubao input source could start ducking")

    if failures.isEmpty {
        print("self-test passed")
    } else {
        for failure in failures { print("self-test failed: \(failure)") }
        exit(1)
    }
}

private func dumpDebug() {
    if let muted = systemMuteState() {
        print("systemMuted=\(muted)")
    } else {
        print("systemMuted=unknown")
    }
    print("doubaoHALCapturing=\(doubaoHALCapturing())")
    let overlay = doubaoRecordingOverlayVisible()
    print("doubaoRecordingOverlayVisible=\(overlay.0) \(overlay.1)")
    print("(recording overlay ignores bars parked flush with a screen's right edge)")
    print("currentInputSourceIsDoubao=\(currentInputSourceIsDoubao())")
    print("fnHeld=\(hardwareFnHeld()) hidSystemState")
    print("fnHeldCombined=\(combinedFnHeld())")
    print("fnCorroborationWindowMs=1200")
    print("process objects:")
    for id in processObjectIDs() {
        let bid = audioString(id, kProcessBundleID) ?? "?"
        let pid = audioUInt32(id, kProcessPID) ?? 0
        let inn = audioUInt32(id, kProcessIsRunningInput) ?? 99
        if inn != 0 || bid.contains("doubao") || bid.contains("wetype") || bid.contains("CoreSpeech") {
            print("  pid=\(pid) in=\(inn) \(bid)")
        }
    }
    if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
        print("on-screen Doubao windows:")
        for win in info {
            let owner = win[kCGWindowOwnerName as String] as? String ?? ""
            if owner.contains("豆包") || owner.lowercased().contains("doubao") {
                print("  owner=\(owner) layer=\(win[kCGWindowLayer as String] ?? 0) bounds=\(win[kCGWindowBounds as String] ?? [:])")
            }
        }
    }
}

private var lockFD: Int32 = -1

private func acquireSingletonLock() {
    let path = "/tmp/doubao-audio-duck.lock"
    lockFD = open(path, O_CREAT | O_RDWR, 0o644)
    if lockFD < 0 {
        log("could not open lock file")
        return
    }
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        log("another instance holds the lock, exiting")
        exit(0)
    }
}

private func runDaemon() {
    acquireSingletonLock()
    log("started pid=\(ProcessInfo.processInfo.processIdentifier)")
    // A previous instance may have been killed mid-duck and left the system
    // muted. If Doubao shows no recording activity right now, unmute once.
    if let muted = systemMuteState(), muted {
        let overlay = doubaoRecordingOverlayVisible().0
        let hal = doubaoHALCapturing()
        if !overlay && !hal && !hardwareFnHeld() {
            _ = setSystemMuted(false)
            log("startup: found system muted with no Doubao activity; unmuted")
        } else {
            log("startup: system muted, but Doubao appears active; leaving as-is")
        }
    }
    writeStatus("idle")
    let duck = DuckController()

    let names = [
        "DoubaoImeSettings.asrShortcutRecordingStateNotification",
        "DoubaoImeSettings.asrShortcutRecordingCaptureNotification",
        "DoubaoImeSettings.enableStartASRShortcutNotification",
        "com.bytedance.inputmethod.doubaoime.asrShortcutRecordingStateNotification"
    ]
    for name in names {
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name(name),
            object: nil,
            queue: .main
        ) { note in
            log("notify \(note.name.rawValue) userInfo=\(note.userInfo ?? [:])")
            duck.pollSustain()
        }
    }

    let sustainTimer = Timer(timeInterval: 0.20, repeats: true) { _ in
        duck.pollSustain()
    }
    RunLoop.main.add(sustainTimer, forMode: .common)

    // Poll hidSystemState directly. Avoid a global event tap: if an event-tap
    // client stalls, WindowServer can spend substantial time dispatching input
    // events and make typing plus system animations lag globally.
    var lastHidHeld: Bool?
    let hidTimer = Timer(timeInterval: 0.08, repeats: true) { _ in
        let held = hardwareFnHeld()
        if held != lastHidHeld {
            lastHidHeld = held
            duck.handleFnChanged(held, source: "hid-state")
        }
    }
    RunLoop.main.add(hidTimer, forMode: .common)

    // If launchd kills or restarts us mid-duck, unmute before dying so the
    // system never stays silently muted by a dead daemon.
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let srcTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    srcTerm.setEventHandler { duck.emergencyRestore("SIGTERM") }
    srcTerm.resume()
    let srcInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    srcInt.setEventHandler { duck.emergencyRestore("SIGINT") }
    srcInt.resume()

    withExtendedLifetime(sustainTimer) {
        withExtendedLifetime(hidTimer) {
            RunLoop.main.run()
        }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--self-test") {
    runSelfTest()
} else if args.contains("--dump") || args.contains("--status") {
    dumpDebug()
    if let text = try? String(contentsOfFile: statusPath, encoding: .utf8) {
        print("statusFile=\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
} else if args.contains("--test-mute") {
    print("muting 1s…")
    guard let was = systemMuteState(), setSystemMuted(true) else {
        print("mute failed: default output device does not expose a writable mute property")
        exit(1)
    }
    Thread.sleep(forTimeInterval: 1.0)
    if !was && !setSystemMuted(false) {
        print("restore failed")
        exit(1)
    }
    print("restored")
} else if args.contains("--force-unmute") {
    if setSystemMuted(false) {
        print("restored")
    } else {
        print("restore failed")
        exit(1)
    }
} else {
    runDaemon()
}
