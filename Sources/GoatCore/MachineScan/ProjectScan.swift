import Foundation

/// What kind of work happens in a project directory, read off the marker
/// files at its root. No source is opened — a `Package.swift` says
/// "Swift" well enough.
public enum ProjectLanguage: String, CaseIterable, Sendable, Hashable, Comparable {
    case swift = "Swift"
    case typescript = "TypeScript"
    case javascript = "JavaScript"
    case python = "Python"
    case rust = "Rust"
    case go = "Go"
    case elixir = "Elixir"
    case ruby = "Ruby"
    case java = "Java/Kotlin"
    case dotnet = ".NET"
    case terraform = "Terraform"
    case docker = "Docker"

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Root files (exact) and suffixes (`*.xcodeproj`) that mark the language.
    var markers: (files: [String], suffixes: [String]) {
        switch self {
        case .swift: (["Package.swift"], [".xcodeproj", ".xcworkspace"])
        case .typescript: (["tsconfig.json"], [])
        case .javascript: (["package.json"], [])
        case .python: (["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"], [])
        case .rust: (["Cargo.toml"], [])
        case .go: (["go.mod"], [])
        case .elixir: (["mix.exs"], [])
        case .ruby: (["Gemfile"], [])
        case .java: (["build.gradle", "build.gradle.kts", "pom.xml"], [])
        case .dotnet: ([], [".csproj", ".sln"])
        case .terraform: ([], [".tf"])
        case .docker: (["Dockerfile", "compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"], [])
        }
    }
}

/// A project directory a harness has been used in.
public struct ProjectSignal: Sendable, Hashable, Identifiable {
    public var path: String
    public var languages: [ProjectLanguage]
    /// Last commit-ish activity: `.git/index` mtime when there's a repo, else the directory's.
    public var lastActive: Date?
    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

public enum ProjectScan {
    /// Only roots that still exist are returned; the home directory itself
    /// is skipped (Claude Code registers it when launched from `~`).
    public static func scan(roots: [String], home: String) -> [ProjectSignal] {
        let fm = FileManager.default
        return roots.compactMap { root -> ProjectSignal? in
            guard root != home, root != "/" else { return nil }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let entries = Set((try? fm.contentsOfDirectory(atPath: root)) ?? [])
            return ProjectSignal(
                path: root,
                languages: languages(in: entries),
                lastActive: lastActive(root)
            )
        }
        .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    static func languages(in entries: Set<String>) -> [ProjectLanguage] {
        var found = ProjectLanguage.allCases.filter { language in
            let markers = language.markers
            return markers.files.contains(where: entries.contains)
                || entries.contains { entry in markers.suffixes.contains { entry.hasSuffix($0) } }
        }
        // package.json alongside tsconfig.json is a TypeScript project, not both.
        if found.contains(.typescript) { found.removeAll { $0 == .javascript } }
        return found
    }

    static func lastActive(_ root: String) -> Date? {
        let fm = FileManager.default
        for candidate in [root + "/.git/index", root + "/.git/HEAD", root] {
            if let attributes = try? fm.attributesOfItem(atPath: candidate),
               let date = attributes[.modificationDate] as? Date {
                return date
            }
        }
        return nil
    }
}
