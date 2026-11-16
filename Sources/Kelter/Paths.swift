import Foundation

/// Where Kelter keeps its engines, bottles, downloads and logs.
/// `KELTER_HOME` moves everything elsewhere, which the tests use.
enum Paths {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["KELTER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kelter", isDirectory: true)
    }

    static var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    static var engines: URL { root.appendingPathComponent("Engines", isDirectory: true) }
    static var bottles: URL { root.appendingPathComponent("Bottles", isDirectory: true) }
    static var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    static var settingsFile: URL { root.appendingPathComponent("settings.json") }

    static func ensure(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The shim that keeps Steam's web helper from painting black. Lives next to the binary
    /// in the app bundle; during development it is taken from the project's Resources folder.
    static var webhelperShim: URL? { bundledResource("steamwebhelper-shim.exe") }

    /// A file from the app bundle's Resources, or from the project's Resources during development.
    static func bundledResource(_ name: String) -> URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(name), fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        // `swift run` and `swift test`: walk up from the binary, then from this source file.
        let starts = [
            URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent(),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
        ]
        for start in starts {
            var directory = start
            for _ in 0..<6 {
                let candidate = directory.appendingPathComponent("Resources/\(name)")
                if fm.fileExists(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
        }
        return nil
    }
}
