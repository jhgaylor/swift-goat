import Testing
@testable import GoatCore

@Suite("NavHistory")
struct NavHistoryTests {
    @Test func startsWithNowhereToGo() {
        let history = NavHistory(initial: "a")
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.current == "a")
    }

    @Test func recordingTheSameStateIsANoOp() {
        var history = NavHistory(initial: "a")
        history.record("a")
        #expect(!history.canGoBack)
    }

    @Test func backAndForwardWalkTheTrail() {
        var history = NavHistory(initial: "a")
        history.record("b")
        history.record("c")

        #expect(history.goBack() == "b")
        #expect(history.goBack() == "a")
        #expect(history.goBack() == nil)
        #expect(history.goForward() == "b")
        #expect(history.goForward() == "c")
        #expect(history.goForward() == nil)
    }

    @Test func newRecordTruncatesTheForwardTail() {
        var history = NavHistory(initial: "a")
        history.record("b")
        history.record("c")
        _ = history.goBack()
        _ = history.goBack()

        history.record("d")
        #expect(!history.canGoForward)
        #expect(history.goBack() == "a")
        #expect(history.goForward() == "d")
    }

    @Test func capDropsTheOldestEntries() {
        var history = NavHistory(initial: 0, cap: 3)
        for state in 1...10 {
            history.record(state)
        }
        #expect(history.current == 10)
        #expect(history.goBack() == 9)
        #expect(history.goBack() == 8)
        #expect(history.goBack() == nil)
    }
}
