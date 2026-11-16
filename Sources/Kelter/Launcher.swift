import Foundation

/// The steps behind every button, shared by the window and the command line.
enum Launcher {
    static let bottle = Bottle.steam
    static var steam: SteamClient { SteamClient(bottle: bottle) }

    enum SetupStep: Equatable, Sendable {
        case engine(EngineInstaller.Stage)
        case bottle
        case steam
        case firstStart
    }

    /// Engine, bottle and Steam, each only if missing. Ends with Steam's first start, which
    /// downloads the real client (about 400 MB) and shows the login.
    static func setUp(options: GameOptions, progress: @escaping @Sendable (SetupStep) -> Void) async throws {
        if !EngineInstaller.isInstalled {
            try await EngineInstaller.install { progress(.engine($0)) }
        }
        if !bottle.exists {
            progress(.bottle)
            try await bottle.create()
        }
        if !steam.isInstalled {
            progress(.steam)
            try await steam.install()
        }
        progress(.firstStart)
        try await openSteam(options: options)
    }

    /// Shows Steam. A running Steam is only brought to the front, never restarted: a restart would
    /// cut off downloads and end running games.
    static func openSteam(options: GameOptions) async throws {
        try requireReady()
        if bottle.isRunning {
            try await steam.send([], options: steam.runningProfile ?? options)
            return
        }
        try await startSteam(options: options, extraArguments: [])
    }

    /// Opens Steam's own page for a Steam link (steam://…), starting Steam first if needed.
    static func openInSteam(_ link: String, options: GameOptions) async throws {
        try requireReady()
        if !bottle.isRunning {
            try await startSteam(options: options, extraArguments: ["-silent"])
            _ = await steam.waitUntilSignedIn(seconds: 120)
        }
        try await steam.send([link], options: steam.runningProfile ?? options)
    }

    private static func startSteam(options: GameOptions, extraArguments: [String]) async throws {
        // Bottles from before Kelter 1.1 lack the .NET registration; added once, before Steam runs.
        if !bottle.isRunning { try? await bottle.installMonoSupport() }
        try steam.launch(options: options, extraArguments: extraArguments)
        let steam = self.steam
        Task { await ShimGuard.shared.watch(steam, options: options, extraArguments: extraArguments) }
    }

    /// Starts a game and returns once its process runs. Steam passes its environment to games it
    /// starts, so Steam is restarted only when the game needs other graphics settings than the
    /// running Steam has. Games with their own executable (GameFixes) start directly and only need
    /// a signed-in Steam. `steamArguments` go to Steam itself (for example -cef-enable-debugging)
    /// and force a fresh Steam. `progress` gets short status texts for the window.
    static func play(appID: String, options: GameOptions, steamDefaults: GameOptions? = nil, steamArguments: [String] = [],
                     progress: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try requireReady()
        guard let game = SteamLibrary.scan(steam).first(where: { $0.appID == appID }) else {
            throw KelterError.message("Das Spiel \(appID) ist nicht installiert.")
        }
        if !GameProcess.ids(of: game, in: GameProcess.listing()).isEmpty {
            throw KelterError.message("\(game.name) läuft schon.")
        }
        guard game.isReady else {
            throw KelterError.message("\(game.name) wird noch geladen oder aktualisiert. Den Stand zeigt Steam unter „Downloads verwalten“.")
        }
        KelterLog.write("Start \(game.name) (\(appID)): Grafik \(options.graphics.rawValue), Bildschirm \(options.display), Auflösung \(options.resolution)")

        let fix = GameFixes.all[appID]
        fix?.prepare(game)
        let direct = fix?.directExecutable

        // A direct start only needs a signed-in Steam; Steam's own graphics settings don't matter.
        // Only MSync must match, every Wine process of the bottle needs the same.
        let profileMatches: Bool
        if direct != nil {
            profileMatches = steam.runningProfile.map { $0.fastSync == options.fastSync } ?? false
        } else {
            profileMatches = steam.runningProfile == options.steamProfile
        }
        // A Steam started for a direct game gets the normal settings, so the next game through
        // Steam doesn't need a restart.
        var steamOptions = options
        if direct != nil, var defaults = steamDefaults {
            defaults.fastSync = options.fastSync
            steamOptions = defaults
        }
        try await ensureSteam(options: steamOptions, matches: profileMatches, steamArguments: steamArguments,
                              reason: game.name, progress: progress)

        if DisplaySwitcher.apply(display: options.display, resolution: options.resolution) != nil {
            progress("Bildschirm wird umgestellt …")
            // Wine needs a moment to see the new layout before the game asks for its screen.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        progress("\(game.name) startet …")
        if let direct, let fix {
            try startDirect(game: game, executable: direct, fix: fix, options: options)
        } else {
            // Steam hands everything after "-applaunch <id>" to the game as its start options.
            let arguments = ["-applaunch", appID] + (fix?.arguments() ?? []) + options.argumentList
            try await steam.send(arguments, options: steam.runningProfile ?? options)
        }

        if await waitForProcess(of: game, seconds: 150, progress: progress) {
            KelterLog.write("\(game.name) läuft")
            return
        }
        KelterLog.write("\(game.name): nach 150 s kein Prozess")
        // Most often Steam waits for an answer (an agreement, a first-time setup); show it.
        _ = try? await steam.send([], options: steam.runningProfile ?? options)
        throw KelterError.message("\(game.name) ist nach zweieinhalb Minuten nicht gestartet. Steam wartet vermutlich auf dich, zum Beispiel bei einer Vereinbarung; das Steam-Fenster ist jetzt vorn.")
    }

    /// Makes sure a signed-in Steam with fitting settings runs. Restarts Steam only when it must,
    /// and never while a game runs.
    private static func ensureSteam(options: GameOptions, matches: Bool, steamArguments: [String],
                                    reason: String, progress: @escaping @Sendable (String) -> Void) async throws {
        if bottle.isRunning, matches, steamArguments.isEmpty {
            if !steam.isSignedIn {
                progress("Warte auf die Steam-Anmeldung …")
                try await waitForSignIn(options: options)
            }
            return
        }
        if bottle.isRunning {
            let playing = SteamLibrary.scan(steam).filter { GameProcess.running([$0]).contains($0.appID) }
            if let other = playing.first {
                throw KelterError.message("\(reason) braucht andere Grafik-Einstellungen als das laufende Steam. Dafür muss Steam neu starten, das würde \(other.name) beenden. Beende zuerst \(other.name).")
            }
            KelterLog.write("Steam-Neustart für \(reason): andere Grafik-Einstellungen")
            progress("Steam startet mit den Einstellungen für \(reason) neu …")
            await steam.shutdown()
        } else {
            progress("Steam startet …")
        }
        try await startSteam(options: options, extraArguments: steamArguments + ["-silent"])
        progress("Warte auf die Steam-Anmeldung …")
        try await waitForSignIn(options: options)
        // Steam takes commands a moment after the sign-in.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }

    private static func waitForSignIn(options: GameOptions) async throws {
        if await steam.waitUntilSignedIn(seconds: 120) { return }
        _ = try? await steam.send([], options: options)
        throw KelterError.message("Steam hat sich nicht angemeldet. Das Steam-Fenster ist jetzt vorn: bitte dort anmelden und das Spiel dann erneut starten.")
    }

    /// Waits for the game's own process. While Steam installs redistributables for a first start,
    /// the wait is extended (up to 15 minutes in all).
    static func waitForProcess(of game: InstalledGame, seconds: Double,
                               progress: @escaping @Sendable (String) -> Void = { _ in }) async -> Bool {
        let start = Date()
        var deadline = start.addingTimeInterval(seconds)
        var announced = false
        while Date() < deadline {
            let listing = GameProcess.listing()
            if !GameProcess.ids(of: game, in: listing).isEmpty { return true }
            if GameProcess.isSettingUp(game, in: listing) {
                if !announced {
                    progress("Steam richtet \(game.name) für den ersten Start ein …")
                    KelterLog.write("\(game.name): Steam installiert Zusatzpakete (Ersteinrichtung)")
                    announced = true
                }
                deadline = min(max(deadline, Date().addingTimeInterval(60)), start.addingTimeInterval(900))
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// Starts the game's executable itself while Steam runs in the background.
    /// steam_appid.txt keeps the Steam API from handing the start back to Steam's launch entry.
    private static func startDirect(game: InstalledGame, executable: String, fix: GameFixes.Fix, options: GameOptions) throws {
        try game.appID.write(to: game.installDirectory.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)
        let env = LaunchEnvironment.game(engine: bottle.engine, prefix: bottle.prefix, options: options)
            .merging(fix.environment) { _, fixed in fixed }
        let arguments = fix.arguments() + options.argumentList
        try Shell.spawn(bottle.wine, [game.installDirectory.appendingPathComponent(executable).path] + arguments,
                        environment: env, log: Paths.logs.appendingPathComponent("game-\(game.appID).log"),
                        directory: game.installDirectory)
    }

    static func stopSteam() async {
        await steam.shutdown()
        DisplaySwitcher.restore()
    }

    /// Removes a game the way Steam's own "Uninstall" does: game folder, Steam's record of it
    /// (appmanifest), its shader cache and workshop files. Everything goes to the Trash, so a
    /// mistake can be undone. Saves stay (Steam Cloud and userdata are not touched). Steam is
    /// stopped meanwhile, otherwise it keeps the game in memory and writes the record back.
    static func uninstall(_ game: InstalledGame, options: GameOptions) async throws {
        try requireReady()
        if !GameProcess.ids(of: game, in: GameProcess.listing()).isEmpty {
            throw KelterError.message("\(game.name) läuft noch. Erst beenden, dann deinstallieren.")
        }
        let targets = try uninstallTargets(game)
        let steamWasRunning = bottle.isRunning
        if steamWasRunning, let other = SteamLibrary.scan(steam).first(where: { GameProcess.running([$0]).contains($0.appID) }) {
            throw KelterError.message("Zum Deinstallieren hält Kelter Steam kurz an. Das würde \(other.name) beenden; bitte erst \(other.name) beenden.")
        }
        if steamWasRunning { await steam.shutdown() }
        KelterLog.write("Deinstalliere \(game.name) (\(game.appID))")
        let fm = FileManager.default
        for url in targets where fm.fileExists(atPath: url.path) {
            try fm.trashItem(at: url, resultingItemURL: nil)
        }
        if steamWasRunning { try await startSteam(options: options, extraArguments: ["-silent"]) }
    }

    /// What uninstalling removes. Refuses anything that is not a game folder inside steamapps/common,
    /// so a broken manifest can never take the whole library or Steam with it.
    static func uninstallTargets(_ game: InstalledGame) throws -> [URL] {
        guard let manifest = game.manifest else { throw KelterError.message("Zu \(game.name) fehlt Steams Eintrag.") }
        let steamapps = manifest.deletingLastPathComponent().standardizedFileURL
        let common = steamapps.appendingPathComponent("common").standardizedFileURL
        let folder = game.installDirectory.standardizedFileURL
        guard steamapps.lastPathComponent == "steamapps",
              folder.deletingLastPathComponent().standardizedFileURL.path == common.path,
              !folder.lastPathComponent.isEmpty, folder.path != common.path,
              !game.appID.isEmpty, game.appID.allSatisfy(\.isNumber) else {
            throw KelterError.message("Der Spielordner von \(game.name) sieht ungewöhnlich aus (\(folder.path)). Kelter löscht ihn darum nicht.")
        }
        let id = game.appID
        return [
            folder,
            manifest,
            steamapps.appendingPathComponent("shadercache/\(id)"),
            steamapps.appendingPathComponent("downloading/\(id)"),
            steamapps.appendingPathComponent("workshop/appworkshop_\(id).acf"),
            steamapps.appendingPathComponent("workshop/content/\(id)"),
            steamapps.appendingPathComponent("workshop/downloads/\(id)"),
        ]
    }

    // MARK: Accounts

    /// Signs Steam in with another remembered account. Steam is restarted for it, so this refuses
    /// while a game runs. When the account's sign-in token has expired, Steam's window comes to the
    /// front for the password; Kelter never sees it.
    static func switchAccount(to account: SteamAccount, options: GameOptions,
                              progress: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try requireReady()
        try stopSteamForAccountChange(options: options, progress: progress)
        if bottle.isRunning { await steam.shutdown() }
        try await steam.setAutoLoginUser(account.accountName)
        try steam.setAlwaysAskForAccount(false)
        KelterLog.write("Kontowechsel zu \(account.title)")
        progress("Steam meldet \(account.title) an …")
        try await startSteam(options: options, extraArguments: ["-silent"])
        try await waitForSignIn(options: options)
        if let signedIn = steam.signedInSteamID, signedIn != account.steamID {
            throw KelterError.message("Steam hat ein anderes Konto angemeldet. Bitte im Steam-Fenster „\(account.title)“ wählen.")
        }
    }

    /// Opens Steam's own sign-in so another account can be added; Steam remembers it from then on.
    static func addAccount(options: GameOptions, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try requireReady()
        try stopSteamForAccountChange(options: options, progress: progress)
        if bottle.isRunning { await steam.shutdown() }
        try await steam.setAutoLoginUser("")
        KelterLog.write("Neues Konto: Steam zeigt seine Anmeldung")
        progress("Steam öffnet die Anmeldung …")
        try await startSteam(options: options, extraArguments: [])
    }

    private static func stopSteamForAccountChange(options: GameOptions, progress: @escaping @Sendable (String) -> Void) throws {
        guard bottle.isRunning else { return }
        if let other = SteamLibrary.scan(steam).first(where: { GameProcess.running([$0]).contains($0.appID) }) {
            throw KelterError.message("Für den Kontowechsel startet Steam neu, das würde \(other.name) beenden. Bitte erst \(other.name) beenden.")
        }
        progress("Steam wird für den Kontowechsel beendet …")
    }

    /// Runs any Windows program in the bottle (used by the graphics check).
    static func run(windowsProgram path: String, options: GameOptions, log: URL) async throws -> Int32 {
        try requireReady()
        let env = LaunchEnvironment.game(engine: bottle.engine, prefix: bottle.prefix, options: options)
        return try await Shell.run(bottle.wine, [path], environment: env, log: log)
    }

    static func requireReady() throws {
        guard EngineInstaller.isInstalled else { throw KelterError.missing("Die Engine") }
        try? EngineInstaller.prepareRenderers(in: bottle.engine)
        guard bottle.exists else { throw KelterError.missing("Die Bottle") }
        guard steam.isInstalled else { throw KelterError.missing("Steam") }
    }
}
