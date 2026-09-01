import Foundation

/// Applications installed on this Mac, from the two conventional folders.
/// Name plus bundle identifier is all the recommender needs; nothing is
/// launched or loaded.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    public var name: String
    public var bundleID: String?
    public var path: String
    public var id: String { path }
}

public enum InstalledApps {
    /// The folders macOS installs into, for a given home.
    public static func defaultDirectories(home: String) -> [String] {
        ["/Applications", home + "/Applications", "/Applications/Utilities"]
    }

    public static func scan(directories: [String]) -> [InstalledApp] {
        scan(directories: directories, recorder: nil)
    }

    static func scan(directories: [String], recorder: ScanRecorder?) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for root in directories {
            _ = recorder?.probe(root)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for entry in entries where entry.hasSuffix(".app") {
                let path = root + "/" + entry
                apps.append(InstalledApp(
                    name: String(entry.dropLast(4)),
                    bundleID: bundleIdentifier(at: path),
                    path: path
                ))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func bundleIdentifier(at appPath: String) -> String? {
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any]
        else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }
}
