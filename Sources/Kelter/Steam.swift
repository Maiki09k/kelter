import Foundation

/// The Windows Steam client inside a bottle.
struct SteamClient: Sendable {
    let bottle: Bottle

    static let windowsExecutable = #"C:\Program Files (x86)\Steam\steam.exe"#
    static let realHelperName = "steamwebhelper.kelter-real.exe"

    var directory: URL { bottle.driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true) }
    var cefDirectory: URL { directory.appendingPathComponent("bin/cef/cef.win64", isDirectory: true) }
    var helper: URL { cefDirectory.appendingPathComponent("steamwebhelper.exe") }
    var realHelper: URL { cefDirectory.appendingPathComponent(Self.realHelperName) }
    var log: URL { Paths.logs.appendingPathComponent("steam.log") }
    var profileFile: URL { bottle.prefix.appendingPathComponent(".kelter-steam-profile.json") }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("steam.exe").path) }

    /// Steam downloads its actual client on first start; the web helper appears then.
    var isBootstrapped: Bool { FileManager.default.fileExists(atPath: helper.path) }

    func install() async throws {
        try await Downloader.fetch(Catalog.steamSetup) { _ in }
        var env = bottle.baseEnvironment
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="
        try await Shell.check(bottle.wine, [Catalog.steamSetup.localURL.path, "/S"], environment: env, log: log)
        try await Shell.run(bottle.wineserver, ["-w"], environment: env, log: log, appendLog: true)
        guard isInstalled else { throw KelterError.message("Steam wurde nicht installiert. Details: \(log.path)") }
    }

    // MARK: Web helper shim

    /// True when steamwebhelper.exe is the real Steam binary (fresh install or Steam update),
    /// which would paint every Steam window black.
    var helperNeedsShim: Bool {
        guard isBootstrapped, let shim = Paths.webhelperShim else { return false }
        return !Self.sameFile(helper, shim)
    }

    /// Puts the shim in front of the real web helper. Returns true when files changed.
    @discardableResult
    func installShim() throws -> Bool {
        let fm = FileManager.default
        guard let shim = Paths.webhelperShim else { throw KelterError.missing("steamwebhelper-shim.exe in der App") }
        guard isBootstrapped else { return false }
        if Self.sameFile(helper, shim) {
            if fm.fileExists(atPath: realHelper.path) { return false }
            // Shim without the real helper behind it: let Steam restore its file on the next start.
            try fm.removeItem(at: helper)
            return true
        }
        if fm.fileExists(atPath: realHelper.path) { try fm.removeItem(at: realHelper) }
        try fm.moveItem(at: helper, to: realHelper)
        try fm.copyItem(at: shim, to: helper)
        return true
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let sizeA = (try? fm.attributesOfItem(atPath: a.path))?[.size] as? Int,
              let sizeB = (try? fm.attributesOfItem(atPath: b.path))?[.size] as? Int,
              sizeA == sizeB else { return false }
        return fm.contentsEqual(atPath: a.path, andPath: b.path)
    }

    // MARK: Running

    /// Options Steam was last started with, so a game with other options restarts it.
    var runningProfile: GameOptions? {
        guard bottle.isRunning, let data = try? Data(contentsOf: profileFile),
              let stored = try? JSONDecoder().decode(StoredProfile.self, from: data),
              stored.revision == LaunchEnvironment.revision else { return nil }
        return stored.options
    }

    /// The running Steam's settings plus the meaning of its environment at the time.
    struct StoredProfile: Codable {
        let revision: Int
        let options: GameOptions
    }

    @discardableResult
    func launch(options: GameOptions, extraArguments: [String]) throws -> Process {
        try installShim()
        markSessionStart()
        let profile = options.steamProfile
        let env = LaunchEnvironment.game(engine: bottle.engine, prefix: bottle.prefix, options: profile)
        // -noverifyfiles keeps Steam from restoring its original web helper on every start. It must not
        // be set on the very first start: the fresh bootstrapper then skips downloading the client.
        let verify = isBootstrapped ? ["-noverifyfiles"] : []
        // Games are handed over with "-applaunch" once Steam is signed in (see Launcher.play).
        let arguments = [Self.windowsExecutable] + verify + extraArguments
        let process = try Shell.spawn(bottle.wine, arguments, environment: env, log: log)
        if let data = try? JSONEncoder().encode(StoredProfile(revision: LaunchEnvironment.revision, options: profile)) {
            try? data.write(to: profileFile)
        }
        KelterLog.write("Steam gestartet: \((verify + extraArguments).joined(separator: " ")), Grafik \(profile.graphics.rawValue), Vulkan \(profile.vulkanDriver.rawValue)")
        return process
    }

    /// Hands a command to the Steam that already runs (it forwards it and exits).
    @discardableResult
    func send(_ arguments: [String], options: GameOptions) async throws -> Process {
        let env = LaunchEnvironment.game(engine: bottle.engine, prefix: bottle.prefix, options: options)
        return try Shell.spawn(bottle.wine, [Self.windowsExecutable] + arguments, environment: env,
                               log: Paths.logs.appendingPathComponent("steam-command.log"))
    }

    /// Asks Steam to quit, then ends whatever is left in the bottle.
    func shutdown() async {
        await ShimGuard.shared.stop()
        if bottle.isRunning {
            KelterLog.write("Steam wird beendet")
            let request = try? await send(["-shutdown"], options: runningProfile ?? GameOptions())
            _ = await bottle.waitUntilStopped(seconds: 20)
            // The forwarding steam.exe can outlive Steam itself; it has nothing left to do.
            if let request, request.isRunning { request.terminate() }
        }
        if bottle.isRunning { await bottle.stop() }
        try? FileManager.default.removeItem(at: profileFile)
    }

    // MARK: Sign-in

    var connectionLog: URL { directory.appendingPathComponent("logs/connection_log.txt") }
    private var sessionMarker: URL { bottle.prefix.appendingPathComponent(".kelter-steam-session") }

    /// Remembers where Steam's connection log stood before a fresh start.
    func markSessionStart() {
        let size = (try? FileManager.default.attributesOfItem(atPath: connectionLog.path))?[.size] as? Int ?? 0
        try? String(size).write(to: sessionMarker, atomically: true, encoding: .utf8)
    }

    /// True once Steam logged "Logged On" since the last start Kelter made.
    var isSignedIn: Bool {
        guard let data = try? Data(contentsOf: connectionLog) else { return false }
        var offset = (try? String(contentsOf: sessionMarker, encoding: .utf8)).flatMap { Int($0) } ?? 0
        // Steam starts a new log when the old one gets big; then everything in it is from this session.
        if data.count < offset { offset = 0 }
        let fresh = data.count > offset ? data.subdata(in: offset..<data.count) : Data()
        return String(decoding: fresh, as: UTF8.self).contains("[Logged On")
    }

    func waitUntilSignedIn(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isSignedIn { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return isSignedIn
    }

    /// After a start, Steam may update itself and bring back the real web helper, which paints every
    /// Steam window black. This watches the first minutes and restarts Steam once with the shim when
    /// that happens, but never while a game runs (a restart would end it). Returns true if it did.
    func guardShim(options: GameOptions, extraArguments: [String], seconds: Double = 180) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, bottle.isRunning else { return false }
            // The helper file shows up while Steam still unpacks its client; only step in once
            // Steam has finished and actually started the real helper.
            guard helperNeedsShim, Self.webhelperIsRunning else { continue }
            if !GameProcess.running(SteamLibrary.scan(self)).isEmpty {
                KelterLog.write("Echter Web-Helfer erkannt, aber ein Spiel läuft: kein Neustart")
                return false
            }
            KelterLog.write("Echter Web-Helfer erkannt (Steam-Update): Neustart mit Shim")
            await bottle.stop()
            for _ in 0..<2 {
                _ = try? launch(options: options, extraArguments: extraArguments)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if bottle.isRunning { return true }
            }
            return true
        }
        return false
    }

    static var webhelperIsRunning: Bool {
        Shell.capture("/bin/ps", ["-axo", "args="]).contains(#"cef.win64\steamwebhelper.exe"#)
    }
}

/// Only one watcher at a time: every Steam start replaces the previous one, and a Steam that Kelter
/// shuts down on purpose is never brought back by an old watcher.
actor ShimGuard {
    static let shared = ShimGuard()
    private var task: Task<Void, Never>?

    func watch(_ steam: SteamClient, options: GameOptions, extraArguments: [String]) {
        task?.cancel()
        task = Task.detached(priority: .utility) {
            _ = await steam.guardShim(options: options, extraArguments: extraArguments)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
