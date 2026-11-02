import AppKit
import ArrangementCore
import Testing
@testable import WindowArrange

@MainActor
struct DisplayProfileMonitorTests {
    private let a = DisplayProfile(mode: .builtinOnly, displayIDs: ["builtin"])
    private let b = DisplayProfile(mode: .clamshell, displayIDs: ["home"])

    private func environment(_ profile: DisplayProfile?, width: CGFloat = 1000) -> DisplayEnvironment {
        DisplayEnvironment(profile: profile,
            geometry: [.init(id: profile?.displayIDs.sorted().first ?? "", frame: CGRect(x: 0, y: 0, width: width, height: 800), visibleFrame: .zero)],
            label: profile?.mode.title ?? "Unknown")
    }

    @Test func geometryMustSettleAndBusyWorkIsDeferred() {
        var current = environment(a)
        var ready = false
        var restored: [DisplayProfile] = []
        let monitor = DisplayProfileMonitor(read: { current }, enabled: { true }, ready: { ready },
            changed: { _ in }, restore: { restored.append($0) }, interrupt: {})
        monitor.poll(now: 0)
        current = environment(a, width: 2000)
        monitor.poll(now: 2)
        ready = true
        monitor.poll(now: 4)
        #expect(restored.isEmpty)
        monitor.poll(now: 5)
        #expect(restored == [a])
        monitor.poll(now: 10)
        #expect(restored == [a])
    }

    @Test func interruptionReturningToSameProfileCanRetry() {
        var current = environment(a)
        var ready = true
        var restored: [DisplayProfile] = []
        var interruptions = 0
        let monitor = DisplayProfileMonitor(read: { current }, enabled: { true }, ready: { ready },
            changed: { _ in }, restore: { restored.append($0) }, interrupt: { interruptions += 1 })
        monitor.poll(now: 0)
        monitor.poll(now: 3)
        ready = false // Restoration is now in flight.
        current = environment(b)
        monitor.poll(now: 4)
        current = environment(a)
        monitor.poll(now: 5)
        monitor.poll(now: 9)
        #expect(restored == [a])
        ready = true
        monitor.poll(now: 10)
        #expect(restored == [a, a])
        #expect(interruptions == 3)
    }

    @Test func geometryNotificationsDoNotCancelOrRepeatAnExistingRestore() {
        var current = environment(a)
        var restored: [DisplayProfile] = []
        var interruptions = 0
        let monitor = DisplayProfileMonitor(read: { current }, enabled: { true }, ready: { true },
            changed: { _ in }, restore: { restored.append($0) }, interrupt: { interruptions += 1 })
        monitor.poll(now: 0)
        monitor.poll(now: 3)
        current = environment(a, width: 2000)
        monitor.poll(now: 4)
        monitor.poll(now: 8)
        #expect(restored == [a])
        #expect(interruptions == 1)
    }

    @Test func resettingModeInterruptsAndWaitsBeforeApplyingAgain() {
        var enabled = true
        var restored: [DisplayProfile] = []
        var interruptions = 0
        let current = environment(a)
        let monitor = DisplayProfileMonitor(read: { current }, enabled: { enabled }, ready: { true },
            changed: { _ in }, restore: { restored.append($0) }, interrupt: { interruptions += 1 })
        monitor.poll(now: 0)
        monitor.poll(now: 3)
        enabled = false
        monitor.reset()
        monitor.poll(now: 4)
        #expect(restored == [a] && interruptions == 2)
        enabled = true
        monitor.reset()
        monitor.poll(now: 5)
        monitor.poll(now: 7)
        #expect(restored == [a])
        monitor.poll(now: 8)
        #expect(restored == [a, a])
    }
}
