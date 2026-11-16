import CryptoKit
import Foundation

/// Downloads a file into Paths.downloads with progress, and keeps it there as a cache:
/// a file that is already present and matches its checksum is not fetched again.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias Progress = @Sendable (Double) -> Void

    private let file: RemoteFile
    private let progress: Progress
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    private init(file: RemoteFile, progress: @escaping Progress) {
        self.file = file
        self.progress = progress
    }

    static func fetch(_ file: RemoteFile, progress: @escaping Progress) async throws {
        try Paths.ensure(Paths.downloads)
        if FileManager.default.fileExists(atPath: file.localURL.path) {
            if let expected = file.sha256 {
                if try await sha256(of: file.localURL) == expected { progress(1); return }
                try? FileManager.default.removeItem(at: file.localURL)
            } else {
                progress(1)
                return
            }
        }
        let downloader = Downloader(file: file, progress: progress)
        try await downloader.run()
        if let expected = file.sha256, try await sha256(of: file.localURL) != expected {
            try? FileManager.default.removeItem(at: file.localURL)
            throw KelterError.checksumMismatch(file.fileName)
        }
    }

    static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private func run() async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            session.downloadTask(with: file.url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : file.bytes
        guard total > 0 else { return }
        progress(min(Double(totalBytesWritten) / Double(total), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns, so it has to move now.
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            moveError = KelterError.message("Download von \(file.fileName) fehlgeschlagen (HTTP \(response.statusCode)).")
            return
        }
        do {
            let partial = file.localURL.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: location, to: partial)
            try? FileManager.default.removeItem(at: file.localURL)
            try FileManager.default.moveItem(at: partial, to: file.localURL)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = error ?? moveError
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
        continuation = nil
    }
}
