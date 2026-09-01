import Foundation
import Testing
@testable import GoatCore

@Suite("LocalRunnerConfig")
struct LocalRunnerConfigTests {
    @Test func defaultsOmitNameAndRoot() {
        let config = LocalRunnerConfig(binaryPath: "/usr/local/bin/fountain")
        #expect(config.arguments == ["runner", "--log-level", "info"])
    }

    @Test func nameAndRootBecomeFlags() {
        let config = LocalRunnerConfig(
            binaryPath: "/usr/local/bin/fountain",
            name: "studio",
            root: "/tmp/sandboxes",
            logLevel: "debug"
        )
        #expect(config.arguments == [
            "runner", "--log-level", "debug",
            "--name", "studio",
            "--root", "/tmp/sandboxes",
        ])
    }

    @Test func environmentInjectsSessionAndKeepsBase() throws {
        let config = LocalRunnerConfig(binaryPath: "/x/fountain")
        let env = config.environment(
            apiKey: "sk-test",
            baseURL: try #require(URL(string: "https://managoat.com")),
            base: ["PATH": "/usr/bin", "HOME": "/Users/x"]
        )
        #expect(env["FOUNTAIN_API_KEY"] == "sk-test")
        #expect(env["FOUNTAIN_BASE_URL"] == "https://managoat.com")
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["HOME"] == "/Users/x")
    }
}

@Suite("LineBuffer")
struct LineBufferTests {
    @Test func splitsLinesAcrossChunks() {
        var buffer = LineBuffer()
        buffer.append("hel")
        buffer.append("lo\nwor")
        #expect(buffer.lines == ["hello"])
        buffer.append("ld\n")
        #expect(buffer.lines == ["hello", "world"])
    }

    @Test func flushEmitsTheTrailingPartial() {
        var buffer = LineBuffer()
        buffer.append("no newline")
        #expect(buffer.lines.isEmpty)
        buffer.flush()
        #expect(buffer.lines == ["no newline"])
        // A second flush is a no-op.
        buffer.flush()
        #expect(buffer.lines == ["no newline"])
    }

    @Test func capsAtCapacityKeepingNewest() {
        var buffer = LineBuffer(capacity: 3)
        buffer.append("1\n2\n3\n4\n5\n")
        #expect(buffer.lines == ["3", "4", "5"])
    }

    @Test func clearDropsLinesAndPartial() {
        var buffer = LineBuffer()
        buffer.append("a\nb")
        buffer.clear()
        buffer.flush()
        #expect(buffer.lines.isEmpty)
    }
}

@Suite("LocalRunnerController statics")
struct LocalRunnerDiscoveryTests {
    @Test func discoveryTakesTheFirstExecutableCandidate() {
        let home = NSHomeDirectory()
        let found = LocalRunnerController.discoverBinary { path in
            path == "/opt/homebrew/bin/fountain" || path == "/usr/local/bin/fountain"
        }
        #expect(found == "/opt/homebrew/bin/fountain")

        let local = LocalRunnerController.discoverBinary { $0 == "\(home)/.local/bin/fountain" }
        #expect(local == "\(home)/.local/bin/fountain")
    }

    @Test func discoveryReturnsNilWhenNothingIsInstalled() {
        #expect(LocalRunnerController.discoverBinary { _ in false } == nil)
    }

    @Test func parsesTheCLIVersionLine() {
        #expect(LocalRunnerController.parseVersion("fountain version v0.13.0\n") == "v0.13.0")
        #expect(LocalRunnerController.parseVersion("") == nil)
    }
}

/// Real child processes (a fake binary standing in for `fountain`), so the
/// pipe capture and phase transitions are exercised, not just the config.
@Suite("LocalRunnerController supervision")
@MainActor
struct LocalRunnerProcessTests {
    private func makeFakeBinary(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goat-runner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake-fountain")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func waitUntil(_ done: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !done() {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func capturesOutputAndReportsAnExit() async throws {
        let controller = LocalRunnerController()
        controller.binaryPath = try makeFakeBinary("echo hello from fake; exit 3")
        controller.start(apiKey: "k", baseURL: try #require(URL(string: "https://example.com")))

        try await waitUntil { if case .exited = controller.phase { true } else { false } }
        #expect(controller.phase == .exited(code: 3))
        #expect(controller.buffer.lines.contains("hello from fake"))
    }

    @Test func stopIsACleanShutdownNotAFailure() async throws {
        let controller = LocalRunnerController()
        controller.binaryPath = try makeFakeBinary("sleep 60")
        controller.start(apiKey: "k", baseURL: try #require(URL(string: "https://example.com")))
        #expect(controller.isRunning)

        controller.stop()
        try await waitUntil { controller.phase == .stopped }
        #expect(controller.phase == .stopped)
    }
}
