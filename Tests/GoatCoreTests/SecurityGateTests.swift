import Foundation
import Testing
@testable import GoatCore

@Suite("SecurityGate")
@MainActor
struct SecurityGateTests {
    /// A gate with a scripted authenticator and a hand-cranked clock.
    private func makeGate(
        enabled: Bool = true,
        graceWindow: TimeInterval = 300,
        result: Bool = true,
        clock: @escaping () -> Date = { Date(timeIntervalSinceReferenceDate: 0) },
        prompts: SendableCounter = SendableCounter()
    ) -> SecurityGate {
        SecurityGate(
            enabled: enabled,
            graceWindow: graceWindow,
            authenticate: { _ in
                prompts.increment()
                return result
            },
            now: clock
        )
    }

    @Test func startsLocked() {
        let gate = makeGate()
        #expect(!gate.isUnlocked(.admin))
        #expect(!gate.isUnlocked(.secrets))
    }

    @Test func disabledGateIsAlwaysUnlocked() async {
        let prompts = SendableCounter()
        let gate = makeGate(enabled: false, prompts: prompts)
        #expect(gate.isUnlocked(.admin))
        #expect(await gate.unlock(.secrets, reason: "test"))
        #expect(prompts.value == 0)
    }

    @Test func successfulUnlockOpensOnlyThatScope() async {
        let gate = makeGate(result: true)
        #expect(await gate.unlock(.admin, reason: "test"))
        #expect(gate.isUnlocked(.admin))
        #expect(!gate.isUnlocked(.secrets))
    }

    @Test func failedUnlockStaysLocked() async {
        let gate = makeGate(result: false)
        #expect(!(await gate.unlock(.admin, reason: "test")))
        #expect(!gate.isUnlocked(.admin))
    }

    @Test func unlockWithinGraceWindowDoesNotReprompt() async {
        let prompts = SendableCounter()
        let gate = makeGate(prompts: prompts)
        _ = await gate.unlock(.admin, reason: "test")
        _ = await gate.unlock(.admin, reason: "test")
        #expect(prompts.value == 1)
    }

    @Test func graceWindowExpiryRelocks() async {
        nonisolated(unsafe) var time = Date(timeIntervalSinceReferenceDate: 0)
        let gate = makeGate(graceWindow: 300, clock: { time })
        _ = await gate.unlock(.admin, reason: "test")
        #expect(gate.isUnlocked(.admin))

        time = time.addingTimeInterval(299)
        #expect(gate.isUnlocked(.admin))

        time = time.addingTimeInterval(2)
        #expect(!gate.isUnlocked(.admin))
    }

    @Test func expiredScopeRepromptsOnUnlock() async {
        nonisolated(unsafe) var time = Date(timeIntervalSinceReferenceDate: 0)
        let prompts = SendableCounter()
        let gate = makeGate(graceWindow: 300, clock: { time }, prompts: prompts)
        _ = await gate.unlock(.admin, reason: "test")
        time = time.addingTimeInterval(301)
        #expect(await gate.unlock(.admin, reason: "test"))
        #expect(prompts.value == 2)
        #expect(gate.isUnlocked(.admin))
    }

    @Test func lockAllRelocksEveryScope() async {
        let gate = makeGate()
        _ = await gate.unlock(.admin, reason: "test")
        _ = await gate.unlock(.secrets, reason: "test")
        gate.lockAll()
        #expect(!gate.isUnlocked(.admin))
        #expect(!gate.isUnlocked(.secrets))
    }
}

/// Call counter usable from the gate's @Sendable authenticator closure.
final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
