// Read-only diagnosis. No audio writes, event posting, permission requests, or text capture.
// swiftc scratch/trace-fn.swift -o /tmp/duck-trace-fn
// /tmp/duck-trace-fn 180 > /tmp/duck-trace-fn.log
import Foundation
import CoreGraphics
import CoreAudio
import Carbon
import ApplicationServices
import IOKit.hid

setbuf(stdout, nil)
let seconds = max(1, min(600, Double(CommandLine.arguments.dropFirst().first ?? "180") ?? 180))
let start = DispatchTime.now().uptimeNanoseconds
func stamp(_ message: String) {
    let ms = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    print("\(ISO8601DateFormatter().string(from: Date())) +\(ms)ms \(message)")
}
func uintProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}
func capturePIDs() -> [UInt32] {
    var address = AudioObjectPropertyAddress(mSelector: 0x70727323, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard !ids.isEmpty,
          AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        guard uintProperty(id, 0x70697269) == 1 else { return nil }
        return uintProperty(id, 0x70706964)
    }.sorted()
}
func currentIME() -> String {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyBundleID) else { return "unknown" }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

stamp("START duration=\(seconds)s axTrusted=\(AXIsProcessTrusted()) listenAccess=\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue) (0=granted,1=denied,2=unknown) cgListen=\(CGPreflightListenEventAccess())")
// Observe only physical Fn flagsChanged events, and only with existing access.
// No global ordinary keyDown/keyUp events are subscribed to.
let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .flagsChanged && event.getIntegerValueField(.keyboardEventKeycode) == 63 {
        stamp("EVENT keycode=63 secondaryFn=\(event.flags.contains(.maskSecondaryFn))")
    }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        stamp("EVENT TAP DISABLED type=\(type.rawValue)")
    }
    return Unmanaged.passUnretained(event)
}
var eventTap: CFMachPort?
var eventSource: CFRunLoopSource?
if CGPreflightListenEventAccess() {
    eventTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                options: .listenOnly,
                                eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
                                callback: callback, userInfo: nil)
    if let tap = eventTap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) {
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
stamp("physicalFnEventTap=\(eventTap != nil) (unavailable is not proof that Fn is absent)")

var lastKeys = ""
var lastAudio = ""
var lastAudioAt: UInt64 = 0
var lastHeartbeatAt: UInt64 = 0
var keyChanges = 0
repeat {
    let now = DispatchTime.now().uptimeNanoseconds
    let physicalHid = CGEventSource.keyState(.hidSystemState, key: 63)
    let physicalCombined = CGEventSource.keyState(.combinedSessionState, key: 63)
    let sharedHid = CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
    let sharedCombined = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
    // Only navigation key state, never letters or typed text.
    let arrows = ([123, 124, 125, 126] as [CGKeyCode]).filter {
        CGEventSource.keyState(.hidSystemState, key: $0)
    }
    let keys = "KEYS fn63Hid=\(physicalHid) fn63Combined=\(physicalCombined) sharedHid=\(sharedHid) sharedCombined=\(sharedCombined) arrowsHid=\(arrows)"
    if keys != lastKeys {
        stamp(keys)
        if !lastKeys.isEmpty { keyChanges += 1 }
        lastKeys = keys
    }
    if now - lastAudioAt >= 200_000_000 {
        lastAudioAt = now
        let device = uintProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        let muted = device.flatMap { uintProperty($0, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput) }
        let audio = "AUDIO device=\(device.map(String.init) ?? "unknown") mute=\(muted.map(String.init) ?? "unknown") capturePIDs=\(capturePIDs()) inputSource=\(currentIME())"
        if audio != lastAudio {
            stamp(audio)
            lastAudio = audio
        }
    }
    if now - lastHeartbeatAt >= 5_000_000_000 {
        lastHeartbeatAt = now
        stamp("HEARTBEAT keyChanges=\(keyChanges)")
    }
    CFRunLoopRunInMode(.defaultMode, 0.02, false)
} while Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000 < seconds

if let source = eventSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
stamp("END keyChanges=\(keyChanges). No observed Fn event is inconclusive without a time-correlated physical press.")
