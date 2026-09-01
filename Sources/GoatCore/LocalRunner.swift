import Foundation
import Observation

/// How to spawn `fountain runner`: a pure value the tests can exercise
/// without ever launching a process.
public struct LocalRunnerConfig: Equatable, Sendable {
    public var binaryPath: String
    /// Empty string = let the CLI default to the hostname.
    public var name: String
    /// Empty string = the CLI's default root (~/.fountain/runners/<name>/sandboxes).
    public var root: String
    public var logLevel: String

    public init(binaryPath: String, name: String = "", root: String = "", logLevel: String = "info") {
        self.binaryPath = binaryPath
        self.name = name
        self.root = root
        self.logLevel = logLevel
    }

    public var arguments: [String] {
        var args = ["runner", "--log-level", logLevel]
        if !name.isEmpty { args += ["--name", name] }
        if !root.isEmpty { args += ["--root", root] }
        return args
    }

    /// The child gets the app's own session via env — never a profile
    /// written to ~/.fountain/credentials.
    public func environment(apiKey: String, baseURL: URL, base: [String: String]) -> [String: String] {
        var env = base
        env["FOUNTAIN_API_KEY"] = apiKey
        env["FOUNTAIN_BASE_URL"] = baseURL.absoluteString
        return env
    }
}

/// Splits raw pipe chunks into lines and keeps only the newest `capacity`,
/// so a chatty daemon can run for days without growing the app.
public struct LineBuffer: Equatable, Sendable {
    public private(set) var lines: [String] = []
    private var partial = ""
    private let capacity: Int

    public init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    public mutating func append(_ chunk: String) {
        partial += chunk
        var pieces = partial.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        partial = pieces.removeLast()
        lines.append(contentsOf: pieces)
        trim()
    }

    /// Emit a trailing unterminated line (call at process exit).
    public mutating func flush() {
        guard !partial.isEmpty else { return }
        lines.append(partial)
        partial = ""
        trim()
    }

    public mutating func clear() {
        lines = []
        partial = ""
    }

    private mutating func trim() {
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }
}

/// Runs `fountain runner` as a supervised child of the app: the daemon that
/// turns this Mac into a sandbox provider. The child inherits the app's
/// session (key + base URL) through the environment and dies with the app —
/// RootView sends stop() on NSApplication.willTerminate.
@Observable @MainActor
public final class LocalRunnerController {
    public enum Phase: Equatable, Sendable {
        case stopped
        case running(pid: Int32)
        /// The daemon quit on its own (crash, refused name, auth failure).
        case exited(code: Int32)
        /// The spawn itself failed (bad path, not executable).
        case failed(String)
    }

    public private(set) var phase: Phase = .stopped
    public private(set) var buffer = LineBuffer()
    public private(set) var version: String?

    public var binaryPath: String {
        didSet { UserDefaults.standard.set(binaryPath, forKey: Self.binaryPathKey) }
    }
    public var name: String {
        didSet { UserDefaults.standard.set(name, forKey: Self.nameKey) }
    }
    public var root: String {
        didSet { UserDefaults.standard.set(root, forKey: Self.rootKey) }
    }

    static let binaryPathKey = "runner.binaryPath"
    static let nameKey = "runner.name"
    static let rootKey = "runner.root"

    private var process: Process?
    private var stopRequested = false

    public var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    public init() {
        let defaults = UserDefaults.standard
        binaryPath = defaults.string(forKey: Self.binaryPathKey) ?? Self.discoverBinary() ?? ""
        name = defaults.string(forKey: Self.nameKey) ?? ""
        root = defaults.string(forKey: Self.rootKey) ?? ""
    }

    /// Well-known install locations, in order. A stored custom path (set via
    /// the UI) bypasses this entirely.
    public nonisolated static func discoverBinary(
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/fountain",
            "\(home)/.fountain/bin/fountain",
            "/opt/homebrew/bin/fountain",
            "/usr/local/bin/fountain",
        ]
        return candidates.first(where: isExecutable)
    }

    /// Re-check the well-known locations (after the user installs the CLI).
    public func rediscover() {
        if let found = Self.discoverBinary() {
            binaryPath = found
        }
    }

    public func probeVersion() async {
        let path = binaryPath
        guard !path.isEmpty else {
            version = nil
            return
        }
        version = (await Self.output(of: path, arguments: ["-v"])).flatMap(Self.parseVersion)
    }

    /// "fountain version v0.13.0" → "v0.13.0".
    public nonisolated static func parseVersion(_ output: String) -> String? {
        output
            .split(separator: "\n").first
            .flatMap { $0.split(separator: " ").last }
            .map(String.init)
    }

    public func start(apiKey: String, baseURL: URL) {
        guard process == nil else { return }
        let config = LocalRunnerConfig(binaryPath: binaryPath, name: name, root: root)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: config.binaryPath)
        child.arguments = config.arguments
        child.environment = config.environment(
            apiKey: apiKey,
            baseURL: baseURL,
            base: ProcessInfo.processInfo.environment
        )

        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.buffer.append(text) }
        }
        child.terminationHandler = { [weak self] proc in
            proc.terminationHandler = nil
            (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            Task { @MainActor [weak self] in self?.processDidExit(code: code) }
        }

        stopRequested = false
        do {
            try child.run()
            process = child
            phase = .running(pid: child.processIdentifier)
            buffer.append("▶ \(config.binaryPath) \(config.arguments.joined(separator: " "))\n")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// SIGTERM; the daemon parks its sandboxes and disconnects cleanly.
    public func stop() {
        guard let process else { return }
        stopRequested = true
        process.terminate()
    }

    public func clearLog() {
        buffer.clear()
    }

    private func processDidExit(code: Int32) {
        buffer.flush()
        buffer.append("■ exited (\(code))\n")
        process = nil
        phase = stopRequested ? .stopped : .exited(code: code)
        stopRequested = false
    }

    private nonisolated static func output(of path: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
    }
}
