import Foundation

/// macOS Game Mode (CPU and GPU priority for the game, lower Bluetooth latency). It only switches
/// on by itself for real app bundles in full screen, which Wine processes are not, so Kelter can
/// force it with Apple's `gamepolicyctl` from Xcode and hand it back to automatic afterwards.
enum GameMode {
    enum Policy: String { case on, auto }

    static let tool: String? = {
        let path = Shell.capture("/usr/bin/xcrun", ["--find", "gamepolicyctl"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    static var isAvailable: Bool { tool != nil }

    /// Kelter remembers that it forced Game Mode, so it only ever resets what it set itself.
    static var marker: URL { Paths.root.appendingPathComponent(".gamemode-forced") }
    static var forcedByKelter: Bool { FileManager.default.fileExists(atPath: marker.path) }

    static func force() {
        guard let tool else { return }
        _ = Shell.capture(tool, ["game-mode", "set", Policy.on.rawValue])
        try? Paths.ensure(Paths.root)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    static func release() {
        guard let tool, forcedByKelter else { return }
        _ = Shell.capture(tool, ["game-mode", "set", Policy.auto.rawValue])
        try? FileManager.default.removeItem(at: marker)
    }
}
