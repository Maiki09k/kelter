import Foundation

/// Finds and ends a game's Windows processes. Wine lists them in `ps` with the game's path: as a Unix
/// path when Kelter started the game directly, as a Windows path when Steam started it.
enum GameProcess {
    /// Process ids of the game itself, read from `ps -axo pid=,args=`. First-start installers in the
    /// game folder (.NET, DirectX, Visual C++) don't count, see `isSettingUp`.
    static func ids(of game: InstalledGame, in listing: String) -> [Int32] {
        processes(of: game, in: listing).filter { !$0.installer }.map(\.id)
    }

    /// True while Steam prepares the game's first start: its install script or a redistributable
    /// installer from the game folder runs.
    static func isSettingUp(_ game: InstalledGame, in listing: String) -> Bool {
        let folder = game.installDirectory.lastPathComponent.lowercased()
        let script = listing.lowercased().split(separator: "\n").contains {
            $0.contains("/installscript") && $0.contains(folder)
        }
        return script || processes(of: game, in: listing).contains(where: \.installer)
    }

    private static func processes(of game: InstalledGame, in listing: String) -> [(id: Int32, installer: Bool)] {
        let folder = game.installDirectory.lastPathComponent.lowercased()
        let markers = ["steamapps/common/\(folder)/", #"steamapps\common\"# + folder + #"\"#]
        return listing.split(separator: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let space = text.firstIndex(of: " "), let id = Int32(text[..<space]) else { return nil }
            let arguments = text[text.index(after: space)...].trimmingCharacters(in: .whitespaces).lowercased()
            guard let path = executablePath(arguments, markers: markers) else { return nil }
            return (id, isInstaller(path))
        }
    }

    /// A Wine process of the game starts with its .exe path (Unix or Windows form). Anything else
    /// that merely mentions the folder (a shell command, a Finder search) is not the game.
    static func isGameProcess(_ arguments: String, markers: [String]) -> Bool {
        executablePath(arguments, markers: markers).map { !isInstaller($0) } ?? false
    }

    private static func executablePath(_ arguments: String, markers: [String]) -> Substring? {
        guard let exe = arguments.range(of: ".exe") else { return nil }
        let path = arguments[..<exe.upperBound]
        let startsLikePath = path.hasPrefix("/") || (path.count > 3 && path.dropFirst().hasPrefix(#":\"#))
        guard startsLikePath else { return nil }
        let inFolder = markers.contains { marker in
            guard let found = path.range(of: marker) else { return false }
            let before = path[..<found.lowerBound]
            return !["\"", "'", "=", "|", ";", "$", " -"].contains { before.contains($0) }
        }
        return inFolder ? path : nil
    }

    /// Redistributable installers Steam runs from a game's folder before the first start.
    static func isInstaller(_ path: Substring) -> Bool {
        let lower = path.lowercased()
        if lower.contains("_commonredist") || lower.contains(#"\redist\"#) || lower.contains("/redist/") { return true }
        let name = lower.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? lower
        return ["setup", "redist", "install", "dotnetfx", "dxsetup", "vc_", "unins", "oalinst", "physx"].contains { name.contains($0) }
    }

    static func listing() -> String { Shell.capture("/bin/ps", ["-axo", "pid=,args="]) }

    /// App ids of the games that currently run.
    static func running(_ games: [InstalledGame]) -> Set<String> {
        let list = listing()
        return Set(games.filter { !ids(of: $0, in: list).isEmpty }.map(\.appID))
    }

    /// Asks the game to quit, then forces it; also the way out of a game that hangs, or of a
    /// first-start installer that hangs. Ending the process undoes a display mode switch the game
    /// made. Returns true when nothing is left.
    @discardableResult
    static func stop(_ game: InstalledGame) async -> Bool {
        let all = { processes(of: game, in: listing()).map(\.id) }
        for signal in [SIGTERM, SIGKILL] {
            let found = all()
            if found.isEmpty { return true }
            for id in found { kill(id, signal) }
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if all().isEmpty { return true }
            }
        }
        return all().isEmpty
    }
}
