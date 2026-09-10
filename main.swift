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

/// Display geometry straight from CoreGraphics. It shares the top-left global
/// coordinate space with CGWindow bounds (so no vertical flip is needed) and,
/// unlike NSScreen, it is safe to call off the main thread — which matters
/// because the overlay scan now runs on the input queue.
private func displayBounds() -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
        return [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
        return [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
    }
    return ids.map { CGDisplayBounds($0) }
}

/// CGWindow bounds are top-left origin, the same space as CGDisplayBounds.
private func cgWindowRect(_ bounds: [String: Any]) -> CGRect {
    let x = (bounds["X"] as? NSNumber)?.doubleValue ?? 0
    let y = (bounds["Y"] as? NSNumber)?.doubleValue ?? 0
    let w = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
    let h = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
    return CGRect(x: x, y: y, width: w, height: h)
}

private func windowVisibleOnAScreen(_ cgRect: CGRect) -> Bool {
    for screen in displayBounds() {
        let inter = screen.intersection(cgRect)
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
    for screen in displayBounds() {
        let maxX = screen.maxX
        let minX = screen.minX
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

    let thresholdNanoseconds: UInt64
    private(set) var held = false
    private(set) var generation: UInt64 = 0
    private var pressedAt: UInt64?

    init(thresholdNanoseconds: UInt64) {
        self.thresholdNanoseconds = thresholdNanoseconds
        self.pressedAt = nil
    }

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

    func shouldArm(generation: UInt64, at now: UInt64) -> Bool {
        guard held, self.generation == generation, let pressedAt else { return false }
        return now >= pressedAt && now - pressedAt >= thresholdNanoseconds
    }
}

/// Test hook: `DUCK_FAKE_FN_AT=<unix seconds>` makes the daemon report Fn as
/// held for 1.5s starting at that wall-clock second. It exists so the arm
/// latency can be measured inside a real launchd job, where timers behave very
/// differently from an interactive shell, without touching the keyboard.
/// Off unless the variable is set.
private let fakeFnAt: TimeInterval = {
    if let s = ProcessInfo.processInfo.environment["DUCK_FAKE_FN_AT"],
       let n = TimeInterval(s) { return n }
    return 0
}()

private let fakeFnRepeat: Int = {
    if let s = ProcessInfo.processInfo.environment["DUCK_FAKE_FN_REPEAT"],
       let n = Int(s), n > 0 { return n }
    return 1
}()

private func fakedFnHeld() -> Bool? {
    guard fakeFnAt > 0 else { return nil }
    let now = Date().timeIntervalSince1970
    for i in 0..<fakeFnRepeat {
        let start = fakeFnAt + Double(i) * 3.0
        if now >= start && now < start + 1.5 { return true }
    }
    return nil
}

private func hardwareFnHeld() -> Bool {
    if let faked = fakedFnHeld() { return faked }
    return CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
}

private final class DuckController {
    /// Every Fn tick and every duck decision runs here, never on the main
    /// runloop. The overlay scan enumerates every window on the system and can
    /// hold the main thread for tens of milliseconds; sharing a runloop with it
    /// made the Fn->mute path jitter between 40ms and 140ms.
    let queue = DispatchQueue(label: "com.doubao.audio-duck.input", qos: .userInteractive)

    /// Window enumeration + the CoreAudio process walk cost ~12ms together.
    /// They run here so they can never delay a duck decision, and the results
    /// hop back onto `queue` which owns the state machine.
    private let scanQueue = DispatchQueue(label: "com.doubao.audio-duck.scan", qos: .utility)
    private var scanInFlight = false

    private var lastHidHeld: Bool?

    /// Fn edge detection plus fast-mode arming. Called on `queue`.
    /// Returns true while the tool is "hot" (Fn held or audio ducked) so the
    /// caller can poll faster.
    func pollInput() -> Bool {
        let held = hardwareFnHeld()
        if held != lastHidHeld {
            lastHidHeld = held
            handleFnChanged(held, source: "hid-state")
        }
        pollFn()
        return fnGate.held || duckedByUs
    }

    /// Conservative mode, kept for hardware that reports phantom Fn flags.
    /// Setting DUCK_FN_HOLD_MS restores the old "wait, then mute" behaviour.
    ///
    /// It is off by default because the wait is exactly the bug: Doubao starts
    /// capturing on Fn-down, so every millisecond spent waiting is playback
    /// that gets recognised.
    static let legacyHoldMilliseconds: Int? = {
        if let s = ProcessInfo.processInfo.environment["DUCK_FN_HOLD_MS"],
           let n = Int(s), (100...2_000).contains(n) {
            return n
        }
        return nil
    }()

    /// Fast mode: Fn must be down this long, measured from the real Fn-down
    /// event, before we mute. Two 20ms polls of hidSystemState must agree,
    /// which filters a one-tick phantom report without re-introducing the
    /// audible leak. Override with DUCK_FN_CONFIRM_MS.
    static let fnConfirmMilliseconds: Int = {
        if let s = ProcessInfo.processInfo.environment["DUCK_FN_CONFIRM_MS"],
           let n = Int(s), (0...400).contains(n) {
            return n
        }
        return 40
    }()

    /// Reported by --dump / --self-test and written to the log at startup.
    static var fnHoldMilliseconds: Int {
        legacyHoldMilliseconds ?? fnConfirmMilliseconds
    }

    static var modeDescription: String {
        if let hold = legacyHoldMilliseconds { return "legacy-hold-\(hold)ms" }
        return "fast-confirm-\(fnConfirmMilliseconds)ms"
    }

    private static let fnArmNanoseconds = UInt64(fnConfirmMilliseconds) * 1_000_000
    /// Gate threshold — only the conservative legacy path still consults it.
    private static let fnHoldNanoseconds = UInt64(fnHoldMilliseconds) * 1_000_000
    /// After muting, keep watching for an Fn companion key for this long.
    /// Fn+F1..F12 / Fn+arrows / Fn+Delete are shortcuts, not dictation, so the
    /// mute is undone the moment one shows up. The probe deliberately runs
    /// *after* the mute: querying per-key state costs tens of milliseconds, and
    /// spending that before muting would hand it straight back to Doubao.
    private static let companionProbeNanoseconds: UInt64 = 120_000_000
    /// A hold shorter than this that never produced HAL capture or the
    /// recording overlay was a shortcut chord or a phantom Fn flag; restore
    /// fast instead of waiting the full second.
    private static let shortHoldNanoseconds: UInt64 = 400_000_000
    private static let fastRestoreDelay: TimeInterval = 0.15
    private static let standardRestoreDelay: TimeInterval = 1.0

    private var duckedByUs = false
    private var mutedBefore = false
    private var fnGate = FnHoldGate(thresholdNanoseconds: DuckController.fnHoldNanoseconds)
    private var holdWork: DispatchWorkItem?
    private var restoreWork: DispatchWorkItem?
    private let sustainStableNanoseconds: UInt64 = 320_000_000
    private var overlayStartedAt: UInt64?
    private var halStartedAt: UInt64?
    private var overlayInfo = ""
    private var sustainActive = false
    /// Short Fn taps never cross the arm threshold. Keep a window so the
    /// recording overlay / HAL capture that follows a click can start the duck.
    private var fnCorroborationDeadline: UInt64 = 0
    private static let fnCorroborationNanoseconds: UInt64 = 1_200_000_000
    /// Fast-mode bookkeeping.
    private var fnPressedAt: UInt64 = 0
    private var duckStartedByFn = false
    private var sawRecordingEvidence = false
    private var companionProbeUntil: UInt64 = 0
    private var suppressedUntilFnRelease = false
    /// Cached result of the IME check. See the note in handleFnChanged.
    private var inputSourceIsDoubao = false
    private var lastInputSourceRefresh: UInt64 = 0

    /// Last-resort restore used on SIGTERM/SIGINT so a killed daemon
    /// never leaves the system muted. Runs before exit.
    func emergencyRestore(_ why: String) {
        queue.sync {
            holdWork?.cancel()
            restoreWork?.cancel()
            if duckedByUs && !mutedBefore {
                _ = setSystemMuted(false)
            }
            writeStatus("idle")
            log("emergency restore (\(why)) duckedByUs=\(duckedByUs) mutedBefore=\(mutedBefore)")
        }
        exit(0)
    }

    func handleFnChanged(_ held: Bool, source: String) {
        let now = monotonicNanoseconds()
        guard let event = fnGate.update(held: held, at: now) else { return }

        holdWork?.cancel()
        holdWork = nil

        switch event {
        case .pressed(let generation):
            // A re-press cancels a pending restore immediately, rather than
            // waiting for the new hold to cross the start threshold.
            restoreWork?.cancel()
            restoreWork = nil
            fnCorroborationDeadline = now + Self.fnCorroborationNanoseconds
            fnPressedAt = now
            sawRecordingEvidence = false
            suppressedUntilFnRelease = false
            companionProbeUntil = 0
            // Query the IME here, not at mute time. The first query in a process
            // builds an XPC connection to the text-input subsystem and costs
            // ~33ms (measured); at press time that is hidden inside the confirm
            // window, whereas in front of the mute it was pure added latency.
            inputSourceIsDoubao = currentInputSourceIsDoubao()
            lastInputSourceRefresh = now
            log("Fn down source=\(source) generation=\(generation)")

            // Conservative path: mute only after the configured hold. pollFn()
            // is a no-op in this mode.
            if let holdMilliseconds = Self.legacyHoldMilliseconds {
                guard !duckedByUs else { return }
                let work = DispatchWorkItem { [weak self] in
                    self?.armFn(generation: generation)
                }
                holdWork = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .milliseconds(holdMilliseconds),
                    execute: work
                )
            }

        case .released(let generation, let durationNanoseconds):
            fnCorroborationDeadline = now + Self.fnCorroborationNanoseconds
            fnPressedAt = 0
            companionProbeUntil = 0
            log("Fn up source=\(source) generation=\(generation) durationMs=\(durationMilliseconds(durationNanoseconds))")
            if duckedByUs {
                // A short hold that never produced HAL capture or the recording
                // overlay was a shortcut chord (Fn+Delete, Fn+brightness) or a
                // phantom Fn flag. Unmute quickly so the dip stays inaudible.
                if duckStartedByFn, !sawRecordingEvidence,
                   durationNanoseconds < Self.shortHoldNanoseconds {
                    scheduleRestoreIfIdle(reason: "fn-shortcut", delay: Self.fastRestoreDelay)
                } else {
                    scheduleRestoreIfIdle(reason: "fn-up", delay: Self.standardRestoreDelay)
                }
            }
        }
    }

    /// Fast-mode Fn handling, called every ~20ms while the daemon is up.
    ///
    /// The old design waited 300ms before muting so a stray Fn report or an
    /// Fn+<key> chord could not silence playback. That wait is what let Doubao
    /// recognise the first ~300ms of music. Instead we mute as soon as Fn is
    /// confirmed and undo it just as fast: chords are spotted via per-key state
    /// within ~80ms, and a short hold with no recording evidence rolls back.
    func pollFn() {
        guard Self.legacyHoldMilliseconds == nil, fnGate.held else { return }
        let now = monotonicNanoseconds()

        if duckedByUs {
            guard now < companionProbeUntil, companionKeyDown() else { return }
            companionProbeUntil = 0
            suppressedUntilFnRelease = true
            restoreWork?.cancel()
            restoreWork = nil
            log("Fn chord detected after duck; undoing mute")
            applyDuck(false, reason: "fn-chord")
            return
        }

        guard !suppressedUntilFnRelease else { return }
        guard now >= fnPressedAt, now - fnPressedAt >= Self.fnArmNanoseconds else { return }
        if !inputSourceIsDoubao {
            // The user can switch to Doubao while Fn is already held. Re-check,
            // but rate-limited: an unbuffered query must not run every 8ms.
            if now - lastInputSourceRefresh >= 200_000_000 {
                lastInputSourceRefresh = now
                inputSourceIsDoubao = currentInputSourceIsDoubao()
            }
            guard inputSourceIsDoubao else { return }
        }

        // Mute first, ask questions after. The chord probe below runs on the
        // following ticks and undoes the mute if Fn turns out to be part of a
        // shortcut; that keeps the leak at ~50ms instead of adding the probe's
        // ~30ms in front of it.
        duckStartedByFn = true
        companionProbeUntil = now + Self.companionProbeNanoseconds
        applyDuck(true, reason: "fn-\(durationMilliseconds(now - fnPressedAt))ms")
        if !duckedByUs {
            duckStartedByFn = false
            companionProbeUntil = 0
        }
    }

    /// Overlay and HAL are corroboration/sustain signals. They cannot start a
    /// duck on their own, but after a recent Fn press they can — that covers
    /// a click-to-record that never crosses the hold threshold.
    /// Cheap gate check on `queue`; the probing itself is handed to `scanQueue`.
    func requestSustainSample() {
        let now = monotonicNanoseconds()
        let fnRecent = fnGate.held || now < fnCorroborationDeadline
        guard duckedByUs || fnRecent, !scanInFlight else { return }
        scanInFlight = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let (overlayNow, info) = doubaoRecordingOverlayVisible()
            let halNow = doubaoHALCapturing()
            self.queue.async {
                self.scanInFlight = false
                self.applySustainSample(overlayNow: overlayNow, info: info, halNow: halNow)
            }
        }
    }

    /// Runs on `queue` with the (slow) probe results already in hand.
    private func applySustainSample(overlayNow: Bool, info: String, halNow: Bool) {
        let now = monotonicNanoseconds()

        if overlayNow {
            overlayStartedAt = overlayStartedAt ?? now
            overlayInfo = info
        } else {
            overlayStartedAt = nil
            overlayInfo = ""
        }

        if halNow {
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
                sawRecordingEvidence = true
                log("sustain on (\(reason))")
            } else {
                log("sustain off")
            }
        }

        if !duckedByUs {
            guard newSustainActive, currentInputSourceIsDoubao() else { return }
            let reason = overlayStable ? "overlay[\(overlayInfo)]" : "hal"
            sawRecordingEvidence = true
            applyDuck(true, reason: reason)
            return
        }

        if fnGate.held || sustainActive {
            restoreWork?.cancel()
            restoreWork = nil
        } else {
            scheduleRestoreIfIdle(reason: "idle", delay: Self.standardRestoreDelay)
        }
    }

    private func armFn(generation: UInt64) {
        holdWork = nil
        let now = monotonicNanoseconds()
        guard fnGate.shouldArm(generation: generation, at: now) else { return }

        guard currentInputSourceIsDoubao() else {
            log("Fn hold ignored generation=\(generation): current input source is not Doubao")
            // The input source can change while Fn is held. Retry without
            // counting callbacks as elapsed time, but never after release.
            guard fnGate.held else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.armFn(generation: generation)
            }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
            return
        }

        duckStartedByFn = true
        applyDuck(true, reason: "fn-\(DuckController.fnHoldMilliseconds)ms")
    }

    private func isStable(since: UInt64?, now: UInt64) -> Bool {
        guard let since, now >= since else { return false }
        return now - since >= sustainStableNanoseconds
    }

    private func scheduleRestoreIfIdle(reason: String, delay: TimeInterval) {
        guard duckedByUs, !fnGate.held, !sustainActive, restoreWork == nil else { return }
        let generation = fnGate.generation
        let work = DispatchWorkItem { [weak self] in
            self?.restoreIfStillIdle(generation: generation, reason: reason)
        }
        restoreWork = work
        log("restore scheduled reason=\(reason) generation=\(generation) delayMs=\(Int(delay * 1000))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
            duckStartedByFn = false
            companionProbeUntil = 0
            writeStatus("idle")
            log("DUCK off (\(reason)) restoredMuted=\(mutedBefore)")
        }
    }
}

private func combinedFnHeld() -> Bool {
    CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
}

/// Keys people actually chord with Fn: arrows (Home/End/PageUp/PageDown),
/// delete, F1..F12, brightness, keyboard backlight, volume and media keys.
/// Holding Fn with any of these is a shortcut, never dictation.
private let companionKeyCodes: [CGKeyCode] = [
    123, 124, 125, 126,                          // arrows
    117, 51,                                     // forward delete, delete
    122, 120, 99, 118, 96, 97, 98, 100, 101,     // F1..F9
    109, 103, 111,                               // F10..F12
    144, 145,                                    // brightness
    21, 22, 149, 150,                            // keyboard backlight
    72, 73, 74,                                  // volume down/up/mute
    16, 17, 18,                                  // play-pause, next, previous
    14,                                          // eject
]

/// hidSystemState only reports modifiers, so Fn alone and Fn+F1 look identical.
/// CGEventSource.keyState exposes individual keys without installing an event
/// tap, which keeps WindowServer out of the input path (see runDaemon).
private func companionKeyDown() -> Bool {
    for code in companionKeyCodes where CGEventSource.keyState(.combinedSessionState, key: code) {
        return true
    }
    return false
}

private func runSelfTest() {
    let threshold = UInt64(DuckController.fnHoldMilliseconds) * 1_000_000
    var gate = FnHoldGate(thresholdNanoseconds: threshold)
    var failures: [String] = []

    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    _ = gate.update(held: true, at: 0)
    expect(!gate.shouldArm(generation: gate.generation, at: threshold - 1), "armed before hold threshold")
    expect(gate.shouldArm(generation: gate.generation, at: threshold), "did not arm at hold threshold")

    let firstGeneration = gate.generation
    _ = gate.update(held: false, at: threshold + 50_000_000)
    let newDownAt = threshold + 60_000_000
    _ = gate.update(held: true, at: newDownAt)
    expect(gate.generation != firstGeneration, "release/re-press did not create a new generation")
    expect(!gate.shouldArm(generation: firstGeneration, at: threshold * 3), "stale generation could arm after re-press")
    expect(!gate.shouldArm(generation: gate.generation, at: newDownAt + threshold / 2), "rapid re-press armed too early")
    expect(gate.shouldArm(generation: gate.generation, at: newDownAt + threshold), "new hold did not arm after its own duration")

    if failures.isEmpty {
        print("self-test passed holdThresholdMs=\(DuckController.fnHoldMilliseconds)")
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
    print("duckMode=\(DuckController.modeDescription)")
    print("fnHoldThresholdMs=\(DuckController.fnHoldMilliseconds)")
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
    log("started pid=\(ProcessInfo.processInfo.processIdentifier) mode=\(DuckController.modeDescription)")
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
    // Warm the text-input XPC connection so the first real press does not pay
    // the ~33ms connection setup that currentInputSourceIsDoubao() costs cold.
    _ = currentInputSourceIsDoubao()
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
            // Hop onto the input queue: it owns all duck state, and log() must
            // not be re-entered from two queues at once.
            duck.queue.async {
                log("notify \(note.name.rawValue) userInfo=\(note.userInfo ?? [:])")
                duck.requestSustainSample()
            }
        }
    }

    // Both timers live on the input queue, not the main runloop: the overlay
    // scan is slow enough to push a main-thread timer past the point where
    // muting still helps.
    let sustainTimer = DispatchSource.makeTimerSource(queue: duck.queue)
    sustainTimer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
    sustainTimer.setEventHandler { duck.requestSustainSample() }
    sustainTimer.resume()

    // The Fn path runs on its own thread with a sleep loop, not a timer.
    // Measured in this launchd background job: both main-runloop timers and
    // dispatch timers get quantised/coalesced, which stretched the 40ms arm to
    // 60-85ms and left the first ~0.1s of playback in Doubao's capture.
    // usleep() is a plain kernel sleep, so the arm lands where it was scheduled.
    // Idle polls at 5ms (detection latency) and 2ms while hot. Cost is a
    // flagsState() call every few ms — well under 0.1% CPU.
    let inputThread = Thread {
        while !Thread.current.isCancelled {
            let hot = duck.queue.sync { duck.pollInput() }
            usleep(hot ? 2_000 : 5_000)
        }
    }
    inputThread.name = "com.doubao.audio-duck.input-poll"
    inputThread.qualityOfService = .userInteractive
    inputThread.stackSize = 256 * 1024
    inputThread.start()

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
        withExtendedLifetime(inputThread) {
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
} else if args.contains("--probe-keys") {
    // Diagnostic for the Fn-chord check. CGEventSource.keyState is what lets the
    // daemon tell "Fn alone" from "Fn+F1": hold a key (or a chord) while this
    // runs to confirm macOS reports per-key state to this binary.
    print("sampling key state for 8s — hold the key/chord you want to test…")
    let deadline = Date().addingTimeInterval(8)
    var seen: Set<CGKeyCode> = []
    while Date() < deadline {
        for code in companionKeyCodes where CGEventSource.keyState(.combinedSessionState, key: code) {
            if seen.insert(code).inserted { print("  key \(code) reported down") }
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    if seen.isEmpty {
        print("no companion key reported (nothing was held, or macOS denies per-key state here)")
        print("the fast rollback path still works without it")
    } else {
        print("keyState works: Fn+<key> chords can be filtered out")
    }
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
