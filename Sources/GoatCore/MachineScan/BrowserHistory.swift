import Foundation
import SQLite3

/// Which sites this Mac's browsers have been visiting — aggregated to
/// the domain, never the URL. Each browser keeps history in SQLite at a
/// known path; the file is copied before opening because the running
/// browser holds a lock on the original, and it's opened read-only.
public enum BrowserHistory {
    public enum Browser: String, CaseIterable, Sendable, Hashable {
        case safari = "Safari"
        case chrome = "Google Chrome"
        case arc = "Arc"
        case brave = "Brave"
        case edge = "Microsoft Edge"
        case chromium = "Chromium"
        case vivaldi = "Vivaldi"
        case firefox = "Firefox"
        case zen = "Zen"

        var family: Family {
            switch self {
            case .safari: .safari
            case .firefox, .zen: .firefox
            default: .chromium
            }
        }
    }

    enum Family { case safari, chromium, firefox }

    public struct Profile: Sendable, Hashable {
        public var browser: Browser
        public var path: String
        public var profileName: String
    }

    /// One domain's usage across every profile that saw it.
    public struct SiteUsage: Sendable, Hashable, Identifiable {
        public var domain: String
        public var visits: Int
        public var browsers: [Browser]
        public var lastVisit: Date?
        public var id: String { domain }
    }

    struct Row {
        var url: String
        var visits: Int
        var lastVisit: Date?
    }

    // MARK: Profiles

    /// Every history database this Mac might have. Chromium browsers keep
    /// one per profile directory (`Default`, `Profile 1`, …).
    public static func profiles(home: String) -> [Profile] {
        let support = home + "/Library/Application Support"
        var out: [Profile] = []
        out += [Profile(browser: .safari, path: home + "/Library/Safari/History.db", profileName: "Default")]
        let chromium: [(Browser, String)] = [
            (.chrome, support + "/Google/Chrome"),
            (.arc, support + "/Arc/User Data"),
            (.brave, support + "/BraveSoftware/Brave-Browser"),
            (.edge, support + "/Microsoft Edge"),
            (.chromium, support + "/Chromium"),
            (.vivaldi, support + "/Vivaldi"),
        ]
        for (browser, base) in chromium {
            for profile in chromiumProfiles(under: base) {
                out.append(Profile(browser: browser, path: base + "/" + profile + "/History", profileName: profile))
            }
        }
        let firefox: [(Browser, String)] = [
            (.firefox, support + "/Firefox/Profiles"),
            (.zen, support + "/zen/Profiles"),
        ]
        for (browser, base) in firefox {
            let dirs = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
            for dir in dirs.sorted() {
                out.append(Profile(browser: browser, path: base + "/" + dir + "/places.sqlite", profileName: dir))
            }
        }
        return out
    }

    private static func chromiumProfiles(under base: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        return entries.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
    }

    // MARK: Reading

    public struct ReadError: Error, CustomStringConvertible {
        public var description: String
    }

    /// Domain-level visit counts from one profile, for URLs last visited
    /// after `since`. The database is copied into `scratch` first.
    static func read(_ profile: Profile, since: Date, scratch: URL) throws -> [Row] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: profile.path) else { return [] }
        guard fm.isReadableFile(atPath: profile.path) else {
            throw ReadError(description: needsFullDiskAccess(profile)
                ? "needs Full Disk Access (System Settings › Privacy & Security)"
                : "not readable")
        }
        let copy = scratch.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer {
            try? fm.removeItem(at: copy)
            try? fm.removeItem(at: URL(fileURLWithPath: copy.path + "-wal"))
        }
        do {
            try fm.copyItem(atPath: profile.path, toPath: copy.path)
            // Firefox and Safari run in WAL mode; the tail of recent history
            // lives in the -wal file until checkpointed.
            if fm.fileExists(atPath: profile.path + "-wal") {
                try? fm.copyItem(atPath: profile.path + "-wal", toPath: copy.path + "-wal")
            }
        } catch {
            throw ReadError(description: needsFullDiskAccess(profile)
                ? "needs Full Disk Access (System Settings › Privacy & Security)"
                : error.localizedDescription)
        }
        return try query(family: profile.browser.family, database: copy.path, since: since)
    }

    private static func needsFullDiskAccess(_ profile: Profile) -> Bool {
        profile.browser == .safari
    }

    private static func query(family: Family, database: String, since: Date) throws -> [Row] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed"
            sqlite3_close(db)
            throw ReadError(description: message)
        }
        defer { sqlite3_close(db) }

        let sql: String
        let bound: Double
        switch family {
        case .chromium:
            // Microseconds since 1601-01-01.
            sql = "SELECT url, visit_count, last_visit_time FROM urls WHERE last_visit_time > ?"
            bound = (since.timeIntervalSince1970 + 11_644_473_600) * 1_000_000
        case .firefox:
            // Microseconds since the Unix epoch.
            sql = "SELECT url, visit_count, last_visit_date FROM moz_places WHERE last_visit_date > ?"
            bound = since.timeIntervalSince1970 * 1_000_000
        case .safari:
            // Seconds since 2001-01-01.
            sql = """
                SELECT i.url, i.visit_count, MAX(v.visit_time) AS last
                FROM history_items i JOIN history_visits v ON v.history_item = i.id
                GROUP BY i.id HAVING last > ?
                """
            bound = since.timeIntervalSinceReferenceDate
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReadError(description: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, bound)

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let urlText = sqlite3_column_text(statement, 0) else { continue }
            let raw = sqlite3_column_double(statement, 2)
            let lastVisit: Date? = switch family {
            case .chromium: Date(timeIntervalSince1970: raw / 1_000_000 - 11_644_473_600)
            case .firefox: Date(timeIntervalSince1970: raw / 1_000_000)
            case .safari: Date(timeIntervalSinceReferenceDate: raw)
            }
            rows.append(Row(
                url: String(cString: urlText),
                visits: Int(sqlite3_column_int64(statement, 1)),
                lastVisit: lastVisit
            ))
        }
        return rows
    }

    // MARK: Aggregation

    /// `https://www.github.com/x/y` → `github.com`. Non-web schemes and
    /// bare hosts without a dot (localhost, intranet names) return nil.
    public static func domain(of url: String) -> String? {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(), host.contains(".")
        else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return nil }
        return host
    }

    static func aggregate(_ rows: [(Browser, Row)]) -> [SiteUsage] {
        var byDomain: [String: SiteUsage] = [:]
        for (browser, row) in rows {
            guard let domain = domain(of: row.url) else { continue }
            var usage = byDomain[domain] ?? SiteUsage(domain: domain, visits: 0, browsers: [])
            usage.visits += max(row.visits, 1)
            if !usage.browsers.contains(browser) { usage.browsers.append(browser) }
            if let last = row.lastVisit, last > (usage.lastVisit ?? .distantPast) { usage.lastVisit = last }
            byDomain[domain] = usage
        }
        return byDomain.values.sorted { $0.visits == $1.visits ? $0.domain < $1.domain : $0.visits > $1.visits }
    }
}
