import Foundation

/// Valve's KeyValues text format ("key" "value" and "key" { … }), as used by
/// libraryfolders.vdf and appmanifest_*.acf. Keys are matched without regard to case.
indirect enum VDF: Equatable {
    case value(String)
    case object([String: VDF])

    subscript(key: String) -> VDF? {
        guard case let .object(children) = self else { return nil }
        return children[key.lowercased()]
    }

    var string: String? {
        if case let .value(text) = self { return text }
        return nil
    }

    var children: [String: VDF] {
        if case let .object(children) = self { return children }
        return [:]
    }

    static func parse(_ text: String) -> VDF {
        var tokens = tokenize(text)[...]
        return .object(parseObject(&tokens))
    }

    private enum Token: Equatable { case text(String), open, close }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { tokens.append(.open); index = text.index(after: index); continue }
            if character == "}" { tokens.append(.close); index = text.index(after: index); continue }
            if character.isWhitespace { index = text.index(after: index); continue }
            if character == "/", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "/" {
                while index < text.endIndex, text[index] != "\n" { index = text.index(after: index) }
                continue
            }
            var word = ""
            if character == "\"" {
                index = text.index(after: index)
                while index < text.endIndex, text[index] != "\"" {
                    if text[index] == "\\", text.index(after: index) < text.endIndex {
                        index = text.index(after: index)
                        switch text[index] {
                        case "n": word.append("\n")
                        case "t": word.append("\t")
                        default: word.append(text[index])
                        }
                    } else {
                        word.append(text[index])
                    }
                    index = text.index(after: index)
                }
                if index < text.endIndex { index = text.index(after: index) }
            } else {
                while index < text.endIndex, !text[index].isWhitespace, text[index] != "{", text[index] != "}" {
                    word.append(text[index])
                    index = text.index(after: index)
                }
            }
            tokens.append(.text(word))
        }
        return tokens
    }

    private static func parseObject(_ tokens: inout ArraySlice<Token>) -> [String: VDF] {
        var result: [String: VDF] = [:]
        while let token = tokens.first {
            tokens = tokens.dropFirst()
            switch token {
            case .close:
                return result
            case .open:
                continue
            case let .text(key):
                guard let next = tokens.first else { return result }
                tokens = tokens.dropFirst()
                switch next {
                case let .text(value): result[key.lowercased()] = .value(value)
                case .open: result[key.lowercased()] = .object(parseObject(&tokens))
                case .close: return result
                }
            }
        }
        return result
    }
}

struct InstalledGame: Identifiable, Hashable, Sendable {
    let appID: String
    let name: String
    let installDirectory: URL
    let sizeOnDisk: Int64
    let lastPlayed: Date?
    /// Steam's StateFlags: 4 means fully installed; anything else is updating or downloading.
    let stateFlags: Int
    let cover: URL?
    /// steamapps/appmanifest_<id>.acf, Steam's record that the game is installed.
    var manifest: URL? = nil
    var bytesToDownload: Int64 = 0
    var bytesDownloaded: Int64 = 0
    /// SteamID64 of the account that installed or last updated the game.
    var lastOwner: String? = nil

    var id: String { appID }
    var isReady: Bool { stateFlags == 4 }

    /// 0…1 while Steam downloads or updates the game, nil when nothing is pending.
    var downloadProgress: Double? {
        guard !isReady, bytesToDownload > 0, bytesDownloaded < bytesToDownload else { return nil }
        return Double(bytesDownloaded) / Double(bytesToDownload)
    }
}

enum SteamLibrary {
    /// Tools and runtimes Steam lists as apps but nobody plays.
    static let hiddenAppIDs: Set<String> = ["228980", "1070560", "1391110", "1628350", "1826330", "2180100"]

    static func scan(_ steam: SteamClient) -> [InstalledGame] {
        var games: [String: InstalledGame] = [:]
        for library in libraryFolders(steam) {
            let steamapps = library.appendingPathComponent("steamapps")
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: steamapps.path) else { continue }
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: steamapps.appendingPathComponent(file), encoding: .utf8),
                      let game = game(fromManifest: text, steamapps: steamapps, steam: steam),
                      !hiddenAppIDs.contains(game.appID) else { continue }
                games[game.appID] = game
            }
        }
        return games.values.sorted { lhs, rhs in
            switch (lhs.lastPlayed, rhs.lastPlayed) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    static func libraryFolders(_ steam: SteamClient) -> [URL] {
        var folders = [steam.directory]
        let candidates = [
            steam.directory.appendingPathComponent("steamapps/libraryfolders.vdf"),
            steam.directory.appendingPathComponent("config/libraryfolders.vdf"),
        ]
        for file in candidates {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let root = VDF.parse(text)["libraryfolders"] ?? .object([:])
            for (_, entry) in root.children {
                // Newer files nest a "path" key, older ones store the path directly.
                let path = entry["path"]?.string ?? entry.string
                guard let path, let url = steam.bottle.unixPath(forWindowsPath: path) else { continue }
                if !folders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { folders.append(url) }
            }
        }
        return folders
    }

    static func game(fromManifest text: String, steamapps: URL, steam: SteamClient) -> InstalledGame? {
        guard let state = VDF.parse(text)["appstate"],
              let appID = state["appid"]?.string,
              let name = state["name"]?.string,
              let installDir = state["installdir"]?.string else { return nil }
        let lastPlayed = state["lastplayed"]?.string.flatMap(TimeInterval.init).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return InstalledGame(
            appID: appID,
            name: name,
            installDirectory: steamapps.appendingPathComponent("common/\(installDir)"),
            sizeOnDisk: Int64(state["sizeondisk"]?.string ?? "") ?? 0,
            lastPlayed: lastPlayed,
            stateFlags: Int(state["stateflags"]?.string ?? "") ?? 0,
            cover: cover(appID: appID, steam: steam),
            manifest: steamapps.appendingPathComponent("appmanifest_\(appID).acf"),
            bytesToDownload: Int64(state["bytestodownload"]?.string ?? "") ?? 0,
            bytesDownloaded: Int64(state["bytesdownloaded"]?.string ?? "") ?? 0,
            lastOwner: state["lastowner"]?.string
        )
    }

    /// Steam caches library art once the game appeared in its library view. Newer clients keep it
    /// in a folder per app (sometimes one level deeper), older ones as flat files.
    static func cover(appID: String, steam: SteamClient) -> URL? {
        let cache = steam.directory.appendingPathComponent("appcache/librarycache")
        let fm = FileManager.default
        for flat in ["\(appID)_library_600x900.jpg", "\(appID)_header.jpg"] {
            let url = cache.appendingPathComponent(flat)
            if fm.fileExists(atPath: url.path) { return url }
        }
        let folder = cache.appendingPathComponent(appID)
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        var header: URL?
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == "library_600x900.jpg" || name == "library_capsule.jpg" { return url }
            if name == "header.jpg" { header = url }
        }
        return header
    }
}
