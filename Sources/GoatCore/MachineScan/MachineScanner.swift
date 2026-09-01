import Foundation

/// Everything one local scan found, plus what it couldn't read. Built
/// entirely from this Mac; nothing here has touched the network.
public struct MachineScan: Sendable {
    public var scannedAt: Date
    public var home: String
    public var duration: TimeInterval
    /// Local harness configs (Claude Code, Codex, …), user and project scope.
    public var sites: [HarnessSite]
    /// Project directories the harnesses have been used in, most recent first.
    public var projects: [ProjectSignal]
    /// Domains visited in the lookback window, most visited first.
    public var browsing: [BrowserHistory.SiteUsage]
    /// Browser profiles whose history was actually read.
    public var browsersRead: [BrowserHistory.Profile]
    public var apps: [InstalledApp]
    /// Locations looked at, whether or not they existed.
    public var probed: [String]
    /// Paths that existed but could not be read or parsed.
    public var unreadable: [UnreadablePath]

    public init(
        scannedAt: Date = Date(), home: String, duration: TimeInterval = 0,
        sites: [HarnessSite] = [], projects: [ProjectSignal] = [],
        browsing: [BrowserHistory.SiteUsage] = [], browsersRead: [BrowserHistory.Profile] = [],
        apps: [InstalledApp] = [], probed: [String] = [], unreadable: [UnreadablePath] = []
    ) {
        self.scannedAt = scannedAt
        self.home = home
        self.duration = duration
        self.sites = sites
        self.projects = projects
        self.browsing = browsing
        self.browsersRead = browsersRead
        self.apps = apps
        self.probed = probed
        self.unreadable = unreadable
    }
}

/// Runs the four local scans. Everything is injectable so tests can point
/// it at a fixture home directory instead of the real machine.
public struct MachineScanner: Sendable {
    public var home: String
    /// Only browsing newer than this counts as "what you use".
    public var lookback: TimeInterval
    /// Where history databases are copied before being opened.
    public var scratch: URL
    public var includeBrowsing: Bool
    /// Where to look for `.app` bundles; nil means the macOS defaults for `home`.
    public var applicationDirectories: [String]?
    /// Unioned with the roots the harnesses already register.
    public var extraProjectRoots: [String]
    public var now: Date

    public init(
        home: String = NSHomeDirectory(),
        lookback: TimeInterval = 90 * 24 * 3600,
        scratch: URL = FileManager.default.temporaryDirectory.appendingPathComponent("swift-goat-scan", isDirectory: true),
        includeBrowsing: Bool = true,
        applicationDirectories: [String]? = nil,
        extraProjectRoots: [String] = [],
        now: Date = Date()
    ) {
        self.home = home
        self.lookback = lookback
        self.scratch = scratch
        self.includeBrowsing = includeBrowsing
        self.applicationDirectories = applicationDirectories
        self.extraProjectRoots = extraProjectRoots
        self.now = now
    }

    /// Synchronous and IO-bound: call it off the main actor.
    public func scan() -> MachineScan {
        let started = Date()
        let rec = ScanRecorder()

        // Claude Code registers `~` itself when launched from there; as a
        // project root it would just duplicate the user-scope site.
        let roots = Array(Set(HarnessScan.registeredProjects(home: home, recorder: rec) + extraProjectRoots))
            .filter { $0 != home && $0 != "/" }
            .sorted()
        let sites = HarnessScan.scan(home: home, projectRoots: roots, recorder: rec)
        let projects = ProjectScan.scan(roots: roots, home: home)

        var browsing: [BrowserHistory.SiteUsage] = []
        var browsersRead: [BrowserHistory.Profile] = []
        if includeBrowsing {
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            var rows: [(BrowserHistory.Browser, BrowserHistory.Row)] = []
            for profile in BrowserHistory.profiles(home: home) where rec.probe(profile.path) {
                do {
                    let read = try BrowserHistory.read(profile, since: now.addingTimeInterval(-lookback), scratch: scratch)
                    rows += read.map { (profile.browser, $0) }
                    browsersRead.append(profile)
                } catch {
                    rec.fail(profile.path, "\(error)")
                }
            }
            browsing = BrowserHistory.aggregate(rows)
        }

        let apps = InstalledApps.scan(
            directories: applicationDirectories ?? InstalledApps.defaultDirectories(home: home),
            recorder: rec
        )

        return MachineScan(
            scannedAt: started,
            home: home,
            duration: Date().timeIntervalSince(started),
            sites: sites,
            projects: projects,
            browsing: browsing,
            browsersRead: browsersRead,
            apps: apps,
            probed: Array(Set(rec.probed)).sorted(),
            unreadable: rec.unreadable
        )
    }
}
