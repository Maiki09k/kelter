import Foundation

enum KelterError: LocalizedError {
    case commandFailed(String, Int32, String)
    case checksumMismatch(String)
    case missing(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, tail):
            return "\(command) endete mit Code \(status).\(tail.isEmpty ? "" : "\n\(tail)")"
        case let .checksumMismatch(file):
            return "Die Prüfsumme von \(file) stimmt nicht. Die Datei wurde gelöscht, bitte erneut laden."
        case let .missing(what):
            return "\(what) fehlt."
        case let .message(text):
            return text
        }
    }
}

/// Runs command line tools. Output always goes to a log file, never to a pipe: Wine starts a
/// wineserver that inherits stdout and outlives the command, so a pipe would never reach EOF.
enum Shell {
    @discardableResult
    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String] = [:],
        log: URL,
        appendLog: Bool = false
    ) async throws -> Int32 {
        let process = try makeProcess(executable, arguments, environment: environment, log: log, append: appendLog)
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
        return status
    }

    /// Like `run`, but throws with the end of the log when the tool fails.
    static func check(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String] = [:],
        log: URL,
        appendLog: Bool = false
    ) async throws {
        let status = try await run(executable, arguments, environment: environment, log: log, appendLog: appendLog)
        guard status == 0 else {
            throw KelterError.commandFailed(executable.lastPathComponent, status, logTail(log))
        }
    }

    /// Starts a long running program (Steam) and returns at once.
    @discardableResult
    static func spawn(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
        log: URL,
        directory: URL? = nil
    ) throws -> Process {
        let process = try makeProcess(executable, arguments, environment: environment, log: log, append: false)
        if let directory { process.currentDirectoryURL = directory }
        try process.run()
        return process
    }

    /// Output of a quick tool such as `ps`, read synchronously.
    static func capture(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func logTail(_ log: URL, lines: Int = 6) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }

    private static func makeProcess(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
        log: URL,
        append: Bool
    ) throws -> Process {
        try Paths.ensure(log.deletingLastPathComponent())
        if !append || !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: log)
        if append { handle.seekToEndOfFile() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        return process
    }
}
