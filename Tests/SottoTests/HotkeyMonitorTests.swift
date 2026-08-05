import CoreGraphics
import Foundation
import Testing
@testable import Sotto

private final class DeliveryLog: @unchecked Sendable {
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var events: [HotkeyEvent] = []
    private var alarms: [HotkeyAlarm] = []
    private var lastDelivery: Date?

    func append(event: HotkeyEvent) {
        lock.lock()
        events.append(event)
        lastDelivery = Date()
        lock.unlock()
        arrived.signal()
    }

    func append(alarm: HotkeyAlarm) {
        lock.lock()
        alarms.append(alarm)
        lastDelivery = Date()
        lock.unlock()
        arrived.signal()
    }

    func waitForDeliveries(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        for _ in 0 ..< count {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            if arrived.wait(timeout: .now() + remaining) == .timedOut { return false }
        }
        return true
    }

    var recordedEvents: [HotkeyEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var recordedAlarms: [HotkeyAlarm] {
        lock.lock()
        defer { lock.unlock() }
        return alarms
    }

    var lastDeliveryTime: Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastDelivery
    }
}

private func makeMonitor(_ hotkey: Hotkey, _ log: DeliveryLog) -> HotkeyMonitor {
    HotkeyMonitor(
        hotkey: hotkey,
        onEvent: { log.append(event: $0) },
        onAlarm: { log.append(alarm: $0) }
    )
}

private let fnKeyCode: Int64 = 63
private let shiftKeyCode: Int64 = 56
private let spaceKeyCode: Int64 = 49

@Suite("Hotkey classification — pure, no event tap required")
struct HotkeyClassifierTests {
    @Test func fnHoldProducesExactlyOneStartAndOneStop() {
        var classifier = HotkeyClassifier(hotkey: .fn)

        #expect(classifier.classify(type: .flagsChanged, flags: [.maskSecondaryFn], keyCode: fnKeyCode) == .start)
        // shift pressed and released mid-hold: more flagsChanged events, still one hold
        #expect(classifier.classify(type: .flagsChanged, flags: [.maskSecondaryFn, .maskShift], keyCode: shiftKeyCode) == nil)
        #expect(classifier.classify(type: .flagsChanged, flags: [.maskSecondaryFn], keyCode: shiftKeyCode) == nil)
        #expect(classifier.classify(type: .flagsChanged, flags: [], keyCode: fnKeyCode) == .stop)
        #expect(classifier.classify(type: .flagsChanged, flags: [], keyCode: fnKeyCode) == nil)
    }

    @Test func fnClassifierIgnoresKeyEvents() {
        var classifier = HotkeyClassifier(hotkey: .fn)

        #expect(classifier.classify(type: .keyDown, flags: [.maskSecondaryFn], keyCode: spaceKeyCode) == nil)
        #expect(classifier.classify(type: .keyUp, flags: [.maskSecondaryFn], keyCode: spaceKeyCode) == nil)
    }

    @Test func chordHoldIgnoresAutorepeatAndOtherKeys() {
        var classifier = HotkeyClassifier(hotkey: .chord(keyCode: spaceKeyCode, modifiers: .maskControl))

        #expect(classifier.classify(type: .keyDown, flags: [.maskControl], keyCode: spaceKeyCode) == .start)
        #expect(classifier.classify(type: .keyDown, flags: [.maskControl], keyCode: spaceKeyCode) == nil)
        #expect(classifier.classify(type: .keyDown, flags: [.maskControl], keyCode: 48) == nil)
        #expect(classifier.classify(type: .keyUp, flags: [.maskControl], keyCode: spaceKeyCode) == .stop)
    }

    @Test func chordWithoutItsModifierNeverStarts() {
        var classifier = HotkeyClassifier(hotkey: .chord(keyCode: spaceKeyCode, modifiers: .maskControl))

        #expect(classifier.classify(type: .keyDown, flags: [], keyCode: spaceKeyCode) == nil)
        #expect(classifier.classify(type: .keyUp, flags: [], keyCode: spaceKeyCode) == nil)
    }
}

@Suite("Hotkey delivery — real threads, synthetic events, no event tap required")
struct HotkeyDeliveryTests {
    @Test func everyHoldDeliversOneStartAndOneStop() throws {
        let log = DeliveryLog()
        let monitor = makeMonitor(.fn, log)
        monitor.startDelivery()
        defer { monitor.stop() }

        monitor.record(type: .flagsChanged, flags: [.maskSecondaryFn], keyCode: fnKeyCode)
        monitor.record(type: .flagsChanged, flags: [.maskSecondaryFn, .maskShift], keyCode: shiftKeyCode)
        monitor.record(type: .flagsChanged, flags: [], keyCode: fnKeyCode)

        #expect(log.waitForDeliveries(2, timeout: 1))
        #expect(log.recordedEvents == [.start, .stop])
        #expect(log.recordedAlarms.isEmpty)
    }

    // Rule 1: delivery must not depend on the main runloop. The main thread is genuinely blocked for
    // 3 s while a producer thread stands in for the tap thread.
    @MainActor @Test func fiftyCyclesSurviveAThreeSecondMainThreadBlock() throws {
        let log = DeliveryLog()
        let monitor = makeMonitor(.fn, log)
        monitor.startDelivery()
        defer { monitor.stop() }

        let producer = Thread {
            for _ in 0 ..< 50 {
                monitor.record(type: .flagsChanged, flags: [.maskSecondaryFn], keyCode: fnKeyCode)
                Thread.sleep(forTimeInterval: 0.02)
                monitor.record(type: .flagsChanged, flags: [], keyCode: fnKeyCode)
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        producer.qualityOfService = .userInteractive
        producer.start()

        Thread.sleep(forTimeInterval: 3)
        let mainThreadWokeAt = Date()

        #expect(log.waitForDeliveries(100, timeout: 1))
        #expect(log.recordedEvents == (0 ..< 50).flatMap { _ in [HotkeyEvent.start, .stop] })
        #expect(log.recordedAlarms.isEmpty)

        let lastDelivery = try #require(log.lastDeliveryTime)
        #expect(lastDelivery < mainThreadWokeAt)
    }

    @Test func recordReturnsUnder100MicrosecondsAtP99() throws {
        let log = DeliveryLog()
        let monitor = makeMonitor(.fn, log)
        monitor.startDelivery()
        defer { monitor.stop() }

        var samples = [UInt64](repeating: 0, count: 1000)
        for index in 0 ..< samples.count {
            let flags: CGEventFlags = index.isMultiple(of: 2) ? [.maskSecondaryFn] : []
            let start = DispatchTime.now().uptimeNanoseconds
            monitor.record(type: .flagsChanged, flags: flags, keyCode: fnKeyCode)
            samples[index] = DispatchTime.now().uptimeNanoseconds - start
        }
        samples.sort()

        let p99 = samples[samples.count * 99 / 100]
        #expect(p99 < 100_000, "p99 was \(p99) ns (max \(samples[samples.count - 1]) ns)")

        #expect(log.waitForDeliveries(1000, timeout: 2))
        #expect(log.recordedEvents.count == 1000)
    }

    @Test func tapDisabledByTimeoutRaisesTheAlarm() throws {
        let log = DeliveryLog()
        let monitor = makeMonitor(.fn, log)
        monitor.startDelivery()
        defer { monitor.stop() }

        monitor.record(type: .tapDisabledByTimeout, flags: [], keyCode: 0)

        #expect(log.waitForDeliveries(1, timeout: 1))
        #expect(log.recordedAlarms == [.tapDisabledByTimeout])
        #expect(log.recordedEvents.isEmpty)
    }
}

@Suite("Live event tap — requires Input Monitoring")
struct HotkeyTapPermissionTests {
    // Input Monitoring is not granted to the test binary on this machine. If this suite starts
    // failing, the grant changed: re-run the live-tap work, do not relax the assertion.
    @Test func startWithoutInputMonitoringThrowsAnErrorNamingThePermission() {
        #expect(CGPreflightListenEventAccess() == false)

        let log = DeliveryLog()
        let monitor = makeMonitor(.fn, log)

        #expect(throws: HotkeyMonitorError.inputMonitoringDenied) {
            try monitor.start()
        }
        #expect("\(HotkeyMonitorError.inputMonitoringDenied)".contains("Input Monitoring"))
    }
}
