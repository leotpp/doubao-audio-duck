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

private let kProcessObjectList: AudioObjectPropertySelector = 0x70727323 // 'prs#'
private let kProcessPID: AudioObjectPropertySelector = 0x70706964        // 'ppid'
private let kProcessBundleID: AudioObjectPropertySelector = 0x70626964   // 'pbid'
private let kProcessIsRunningInput: AudioObjectPropertySelector = 0x70697269 // 'piri'

private func log(_ msg: String) {
    let line = ISO8601DateFormatter().string(from: Date()) + "  " + msg + "\n"
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

private func osascript(_ source: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", source]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        return ""
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func isSystemMuted() -> Bool {
    osascript("output muted of (get volume settings)").lowercased().hasPrefix("t")
}

private func setSystemMuted(_ muted: Bool) {
    if muted {
        _ = osascript("set volume with output muted")
    } else {
        _ = osascript("set volume without output muted")
    }
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
            return (audioUInt32(id, kProcessIsRunningInput) ?? 0) != 0
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

private func fnHeld() -> Bool {
    CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
}

private final class DuckController {
    /// Fn alone is put on probation: it must be corroborated by the overlay or
    /// mic-capture signal within this many ticks (~80ms each) or it is treated
    /// as a spurious maskSecondaryFn report and dropped. Override with the
    /// DUCK_FN_CONFIRM_TICKS environment variable.
    static let fnConfirmTicks: Int = {
        if let s = ProcessInfo.processInfo.environment["DUCK_FN_CONFIRM_TICKS"],
           let n = Int(s), n > 0 { return n }
        return 8
    }()

    private var duckedByUs = false
    private var mutedBefore = false
    private var lastActive = false
    private var restoreWork: DispatchWorkItem?
    private let restoreDelay: TimeInterval = 1.0
    private var lastNote = ""
    private var fnHoldTicks = 0
    private var fnOnlyTicks = 0
    private var overlayTicks = 0
    private var halTicks = 0

    /// Last-resort restore used on SIGTERM/SIGINT so a killed daemon
    /// never leaves the system muted. Runs before exit.
    func emergencyRestore(_ why: String) {
        if duckedByUs && !mutedBefore {
            setSystemMuted(false)
        }
        writeStatus("idle")
        log("emergency restore (\(why)) duckedByUs=\(duckedByUs) mutedBefore=\(mutedBefore)")
        exit(0)
    }

    func tick() {
        if fnHeld() && currentInputSourceIsDoubao() {
            fnHoldTicks += 1
        } else {
            fnHoldTicks = 0
            fnOnlyTicks = 0
        }
        // ~240ms of Fn hold while Doubao is the IME. Ignores Fn+brightness taps.
        let fn = fnHoldTicks >= 3

        // Overlay / HAL are sustain-only. They must not start a duck on their own:
        // the idle voice bar parks on-screen, and Doubao flickers IsRunningInput
        // without the user recording. Probe while ducked as before, and also while
        // Fn is on probation so a real press can be corroborated.
        var overlay = false
        var overlayInfo = ""
        var hal = false
        let probing = duckedByUs || (fn && fnHoldTicks <= DuckController.fnConfirmTicks)
        if probing {
            let (overlayNow, info) = doubaoRecordingOverlayVisible()
            overlayInfo = info
            if overlayNow {
                overlayTicks += 1
            } else {
                overlayTicks = 0
            }
            overlay = overlayTicks >= 2
            if doubaoHALCapturing() {
                halTicks += 1
            } else {
                halTicks = 0
            }
            // ~320ms of stable HAL capture, so a one-tick flicker cannot hold mute.
            hal = halTicks >= 4
        } else {
            overlayTicks = 0
            halTicks = 0
        }

        // Spurious maskSecondaryFn reports happen without any key press. A real
        // press-and-hold always brings up the overlay or mic capture within
        // ~640ms; a phantom Fn flag never does, so drop it instead of muting.
        if !duckedByUs && !overlay && !hal && fnHoldTicks > DuckController.fnConfirmTicks {
            return
        }

        let active = fn || (duckedByUs && (overlay || hal))
        if active {
            restoreWork?.cancel()
            restoreWork = nil
            if !lastActive {
                var parts: [String] = []
                if fn { parts.append("fn") }
                if overlay { parts.append("overlay[\(overlayInfo)]") }
                if hal { parts.append("hal") }
                applyDuck(true, reason: parts.joined(separator: "+"))
            }
            lastActive = true
            if active == fn && !(overlay || hal) {
                fnOnlyTicks += 1
            } else {
                fnOnlyTicks = 0
            }
        } else if lastActive {
            lastActive = false
            let work = DispatchWorkItem { [weak self] in
                self?.applyDuck(false, reason: "idle")
            }
            restoreWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
        }
    }

    private func applyDuck(_ on: Bool, reason: String) {
        if on {
            if duckedByUs { return }
            mutedBefore = isSystemMuted()
            if !mutedBefore {
                setSystemMuted(true)
            }
            duckedByUs = true
            writeStatus("ducked \(reason)")
            log("DUCK on (\(reason)) mutedBefore=\(mutedBefore)")
        } else {
            if !duckedByUs { return }
            if !mutedBefore {
                setSystemMuted(false)
            }
            duckedByUs = false
            writeStatus("idle")
            log("DUCK off (\(reason)) restoredMuted=\(mutedBefore)")
        }
        lastNote = reason
    }
}

private func dumpDebug() {
    print("systemMuted=\(isSystemMuted())")
    print("doubaoHALCapturing=\(doubaoHALCapturing())")
    let overlay = doubaoRecordingOverlayVisible()
    print("doubaoRecordingOverlayVisible=\(overlay.0) \(overlay.1)")
    print("(recording overlay ignores bars parked flush with a screen's right edge)")
    print("currentInputSourceIsDoubao=\(currentInputSourceIsDoubao())")
    print("fnHeld=\(fnHeld())")
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
    if isSystemMuted() {
        let overlay = doubaoRecordingOverlayVisible().0
        let hal = doubaoHALCapturing()
        if !overlay && !hal && !fnHeld() {
            setSystemMuted(false)
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
            duck.tick()
        }
    }

    let timer = Timer(timeInterval: 0.08, repeats: true) { _ in
        duck.tick()
    }
    RunLoop.main.add(timer, forMode: .common)

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

    RunLoop.main.run()
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--dump") || args.contains("--status") {
    dumpDebug()
    if let text = try? String(contentsOfFile: statusPath, encoding: .utf8) {
        print("statusFile=\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
} else if args.contains("--test-mute") {
    print("muting 1s…")
    let was = isSystemMuted()
    setSystemMuted(true)
    Thread.sleep(forTimeInterval: 1.0)
    if !was { setSystemMuted(false) }
    print("restored")
} else {
    runDaemon()
}
