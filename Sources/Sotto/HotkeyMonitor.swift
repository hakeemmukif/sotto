import CoreGraphics
import Foundation
import os

enum Hotkey: Equatable {
    case fn
    case modifier(CGEventFlags)
    case chord(keyCode: Int64, modifiers: CGEventFlags)
}

enum HotkeyEvent: Equatable {
    case start
    case stop
    case abort
}

enum HotkeyAlarm: Equatable {
    case tapDisabledByTimeout
}

enum HotkeyMonitorError: Error, Equatable, CustomStringConvertible {
    case inputMonitoringDenied

    var description: String {
        switch self {
        case .inputMonitoringDenied:
            "Sotto could not arm its keyboard event tap. Grant Input Monitoring in System Settings › Privacy & Security › Input Monitoring."
        }
    }
}

struct HotkeyClassifier {
    /// kVK_Escape. Spelled out rather than imported so this file stays free of Carbon.
    private static let escapeKeyCode: Int64 = 53

    private let hotkey: Hotkey
    private var isHeld = false

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    mutating func classify(type: CGEventType, flags: CGEventFlags, keyCode: Int64) -> HotkeyEvent? {
        // Ahead of the `switch hotkey`, because every branch there would throw an Escape keyDown
        // away: .fn and .modifier demand .flagsChanged, and .chord demands its own keyCode.
        // Clearing isHeld here matters as much as the return value — the later release of the
        // physical hotkey then hits `held != isHeld` as a no-op, so no phantom .stop follows.
        if isHeld, type == .keyDown, keyCode == HotkeyClassifier.escapeKeyCode {
            isHeld = false
            return .abort
        }

        let held: Bool
        switch hotkey {
        case .fn:
            guard type == .flagsChanged else { return nil }
            held = flags.contains(.maskSecondaryFn)
        case let .modifier(flag):
            guard type == .flagsChanged else { return nil }
            held = flags.contains(flag)
        case let .chord(code, modifiers):
            guard keyCode == code else { return nil }
            if type == .keyDown {
                held = flags.isSuperset(of: modifiers)
            } else if type == .keyUp {
                held = false
            } else {
                return nil
            }
        }

        guard held != isHeld else { return nil }
        isHeld = held
        return held ? .start : .stop
    }
}

private enum TapSignal {
    case event(HotkeyEvent)
    case tapDisabled
}

private let hotkeyLog = Logger(subsystem: "com.hakeem.sotto", category: "hotkey")

/// Unchecked because the two threads it owns partition its state: `classifier` and `writeIndex`
/// belong to the tap thread, `readIndex` to the delivery thread, and the semaphore is the only
/// edge between them.
final class HotkeyMonitor: @unchecked Sendable {
    private static let ringCapacity = 64
    private static let ringMask = 63
    private static let eventMask: CGEventMask =
        (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

    private let onEvent: @Sendable (HotkeyEvent) -> Void
    private let onAlarm: @Sendable (HotkeyAlarm) -> Void
    private let ring = UnsafeMutablePointer<TapSignal>.allocate(capacity: HotkeyMonitor.ringCapacity)
    private let pending = DispatchSemaphore(value: 0)

    private var classifier: HotkeyClassifier
    private var writeIndex = 0
    private var readIndex = 0
    private var isDelivering = false
    private var tapPort: CFMachPort?
    private var tapRunLoop: CFRunLoop?

    init(
        hotkey: Hotkey,
        onEvent: @escaping @Sendable (HotkeyEvent) -> Void,
        onAlarm: @escaping @Sendable (HotkeyAlarm) -> Void
    ) {
        classifier = HotkeyClassifier(hotkey: hotkey)
        self.onEvent = onEvent
        self.onAlarm = onAlarm
        // Seeding with .tapDisabled rather than an event means a read-before-write raises the alarm
        // instead of delivering a phantom stop.
        ring.initialize(repeating: .tapDisabled, count: HotkeyMonitor.ringCapacity)
    }

    deinit {
        ring.deallocate()
    }

    func start() throws {
        // Listen-only: an active tap makes the whole event stream wait on this callback's return
        // value, so a slow callback would degrade the user's typing. Sotto only observes the key.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: HotkeyMonitor.eventMask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyMonitorError.inputMonitoringDenied
        }

        // Measured 2026-08-05: without Input Monitoring, tapCreate hands back a non-nil port that
        // the system refuses to enable, so a nil check alone would leave Sotto silently watching
        // nothing.
        CGEvent.tapEnable(tap: port, enable: true)
        guard CGEvent.tapIsEnabled(tap: port) else {
            CFMachPortInvalidate(port)
            throw HotkeyMonitorError.inputMonitoringDenied
        }

        tapPort = port
        startDelivery()
        startTapThread(port)
    }

    func stop() {
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            tapPort = nil
        }
        if let runLoop = tapRunLoop {
            CFRunLoopStop(runLoop)
            tapRunLoop = nil
        }
        isDelivering = false
        pending.signal()
    }

    /// The whole hot path. Classify, write a preallocated slot, signal — nothing else may enter here.
    func record(type: CGEventType, flags: CGEventFlags, keyCode: Int64) {
        if type == .tapDisabledByTimeout {
            enqueue(.tapDisabled)
            return
        }
        guard let event = classifier.classify(type: type, flags: flags, keyCode: keyCode) else { return }
        enqueue(.event(event))
    }

    func startDelivery() {
        isDelivering = true
        let thread = Thread { [self] in deliver() }
        thread.name = "com.hakeem.sotto.hotkey-delivery"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func enqueue(_ signal: TapSignal) {
        ring[writeIndex & HotkeyMonitor.ringMask] = signal
        writeIndex &+= 1
        pending.signal()
    }

    private func deliver() {
        while true {
            pending.wait()
            guard isDelivering else { return }

            let signal = ring[readIndex & HotkeyMonitor.ringMask]
            readIndex &+= 1

            switch signal {
            case let .event(event):
                onEvent(event)
            case .tapDisabled:
                if let port = tapPort {
                    CGEvent.tapEnable(tap: port, enable: true)
                }
                hotkeyLog.fault("hotkey tap disabled by timeout and re-armed — the dedicated tap thread and classify-and-signal callback should make this unreachable, so treat it as a regression")
                onAlarm(.tapDisabledByTimeout)
            }
        }
    }

    // Rule 1: the callback runs on whichever runloop owns the source. Its own thread keeps it clear
    // of SwiftUI layout, menu tracking and the pill's animation on the main runloop, which is what
    // pushes these callbacks past the tap deadline.
    private func startTapThread(_ port: CFMachPort) {
        let ready = DispatchSemaphore(value: 0)
        // CFMachPort carries no Sendable annotation. The tap thread is the only thread that reads
        // this one; CFMachPortInvalidate in stop() is the single cross-thread call and is safe.
        nonisolated(unsafe) let tapMachPort = port
        let thread = Thread { [self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapMachPort, 0)
            tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.hakeem.sotto.hotkey-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }
}

private func hotkeyTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    unowned(unsafe) let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo!).takeUnretainedValue()
    monitor.record(
        type: type,
        flags: event.flags,
        keyCode: event.getIntegerValueField(.keyboardEventKeycode)
    )
    return Unmanaged.passUnretained(event)
}
