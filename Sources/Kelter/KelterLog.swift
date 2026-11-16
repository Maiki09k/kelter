import Foundation

/// Kelter's own diary in Logs/kelter.log: every Steam restart, game start and display change with
/// its reason, so a "Steam started twice" can be traced afterwards instead of guessed.
enum KelterLog {
    static var file: URL { Paths.logs.appendingPathComponent("kelter.log") }
    private static let lock = NSLock()

    static func write(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        try? Paths.ensure(Paths.logs)
        // Keeps one older file once the diary passes 1 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 1_000_000 {
            let previous = Paths.logs.appendingPathComponent("kelter.previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: file, to: previous)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
