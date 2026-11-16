import CoreGraphics
import Foundation

/// `Kelter --cli <command>`: the same steps as the window, for scripts and tests.
enum CLI {
    static func run(_ arguments: [String]) async -> Int32 {
        let command = arguments.first ?? "help"
        let settings = KelterSettings.load()
        do {
            switch command {
            case "status":
                if EngineInstaller.isInstalled { try? EngineInstaller.prepareRenderers(in: EngineInstaller.directory) }
                let steam = Launcher.steam
                print("Engine:      \(EngineInstaller.isInstalled ? "installiert" : "fehlt") (\(EngineInstaller.directory.path))")
                print("Bottle:      \(Launcher.bottle.exists ? "vorhanden" : "fehlt") (\(Launcher.bottle.prefix.path))")
                print("Steam:       \(steam.isInstalled ? (steam.isBootstrapped ? "bereit" : "installiert, noch nicht gestartet") : "fehlt")")
                print("Läuft:       \(Launcher.bottle.isRunning ? "ja" : "nein")")
                print("Web-Helfer:  \(steam.helperNeedsShim ? "ohne Shim (schwarze Fenster)" : "in Ordnung")")
            case "install-engine":
                try await EngineInstaller.install { stage in
                    switch stage {
                    case let .downloading(file, fraction): print(String(format: "Laden %@ %.0f %%", file, fraction * 100))
                    case .unpacking: print("Entpacken …")
                    }
                }
                print("Engine bereit: \(EngineInstaller.directory.path)")
            case "setup":
                try await Launcher.setUp(options: settings.defaults) { print("Schritt: \($0)") }
                print("Eingerichtet. Steam startet und lädt sich nach; der Web-Helfer wird überwacht …")
                let restarted = await Launcher.steam.guardShim(options: settings.defaults, extraArguments: [])
                print(restarted ? "Steam nach dem Nachladen mit Shim neu gestartet." : "Steam läuft ohne Neustart.")
            case "steam":
                try await Launcher.openSteam(options: settings.defaults)
                print("Steam gestartet.")
                if arguments.contains("--wait") { _ = await Launcher.steam.guardShim(options: settings.defaults, extraArguments: []) }
            case "guard":
                let restarted = await Launcher.steam.guardShim(options: settings.defaults, extraArguments: [],
                                                               seconds: Double(arguments.dropFirst().first ?? "") ?? 120)
                print(restarted ? "Echten Web-Helfer erkannt, Steam mit Shim neu gestartet." : "Nichts zu tun.")
            case "games":
                let games = SteamLibrary.scan(Launcher.steam)
                let running = GameProcess.running(games)
                for game in games {
                    let state = running.contains(game.appID) ? "läuft" : game.isReady ? "bereit" : "lädt"
                    print("\(game.appID)\t\(state)\t\(game.name)")
                }
            case "quit":
                // quit <App-ID>: ends a running game, also one that hangs.
                guard arguments.count > 1,
                      let game = SteamLibrary.scan(Launcher.steam).first(where: { $0.appID == arguments[1] }) else {
                    print("Aufruf: quit <App-ID> (siehe games)"); return 2
                }
                print(await GameProcess.stop(game) ? "\(game.name) beendet." : "\(game.name) läuft noch.")
            case "play":
                guard arguments.count > 1 else { print("Aufruf: play <App-ID> [--steam=<Steam-Option> …]"); return 2 }
                let steamArguments = arguments.dropFirst(2).compactMap { $0.hasPrefix("--steam=") ? String($0.dropFirst(8)) : nil }
                try await Launcher.play(appID: arguments[1], options: settings.options(for: arguments[1]),
                                        steamDefaults: settings.defaults, steamArguments: steamArguments) { print($0) }
                print("Spiel läuft.")
                // Display changes are undone when this process ends, so stay until the game ends.
                if DisplaySwitcher.isActive, let game = SteamLibrary.scan(Launcher.steam).first(where: { $0.appID == arguments[1] }) {
                    print("Bildschirm umgestellt; Kelter wartet, bis das Spiel endet …")
                    while !GameProcess.ids(of: game, in: GameProcess.listing()).isEmpty {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                    DisplaySwitcher.restore()
                }
            case "uninstall":
                guard arguments.count > 1,
                      let game = SteamLibrary.scan(Launcher.steam).first(where: { $0.appID == arguments[1] }) else {
                    print("Aufruf: uninstall <App-ID> [--dry-run] (siehe games)"); return 2
                }
                if arguments.contains("--dry-run") {
                    for url in try Launcher.uninstallTargets(game) where FileManager.default.fileExists(atPath: url.path) { print(url.path) }
                    return 0
                }
                try await Launcher.uninstall(game, options: settings.defaults)
                print("\(game.name) liegt im Papierkorb.")
            case "accounts":
                let steam = Launcher.steam
                let active = steam.autoLoginUser ?? ""
                let signedIn = Launcher.bottle.isRunning ? steam.signedInSteamID : nil
                for account in steam.accounts {
                    let mark = account.accountName.caseInsensitiveCompare(active) == .orderedSame ? "aktiv" : "-"
                    print("\(account.steamID)\t\(mark)\t\(signedIn == account.steamID ? "angemeldet" : "-")\t\(account.title)")
                }
            case "account":
                // account <SteamID|Kontoname|neu>
                guard arguments.count > 1 else { print("Aufruf: account <SteamID|Kontoname|neu> (siehe accounts)"); return 2 }
                if arguments[1] == "neu" {
                    try await Launcher.addAccount(options: settings.defaults) { print($0) }
                    print("Steam zeigt seine Anmeldung.")
                    return 0
                }
                guard let account = Launcher.steam.accounts.first(where: {
                    $0.steamID == arguments[1] || $0.accountName.caseInsensitiveCompare(arguments[1]) == .orderedSame
                }) else { print("Konto nicht gefunden (siehe accounts)."); return 2 }
                try await Launcher.switchAccount(to: account, options: settings.defaults) { print($0) }
                print("Angemeldet: \(account.title)")
            case "displays":
                for id in Displays.active() {
                    let modes = Displays.modes(id).map(\.0.title).joined(separator: ", ")
                    print("\(Displays.key(id))\t\(id == CGMainDisplayID() ? "Haupt" : "-")\tmacOS \(Displays.current(id).title)\t1x: \(modes)")
                }
            case "stop":
                await Launcher.stopSteam()
                print("Steam beendet.")
            case "set":
                // set <App-ID|default> graphics=dxmt vulkan=kosmicKrisp hud=1
                guard arguments.count > 2 else { print("Aufruf: set <App-ID|default> schlüssel=wert …"); return 2 }
                var all = settings
                let key = arguments[1]
                var options = key == "default" ? all.defaults : all.options(for: key)
                for pair in arguments.dropFirst(2) {
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    switch parts[0] {
                    case "graphics": options.graphics = Graphics(rawValue: parts[1]) ?? options.graphics
                    case "vulkan": options.vulkanDriver = VulkanDriver(rawValue: parts[1]) ?? options.vulkanDriver
                    case "hud": options.metalHUD = parts[1] == "1"
                    case "args": options.arguments = parts[1]
                    case "display": options.display = parts[1]
                    case "resolution": options.resolution = parts[1]
                    default: print("Unbekannt: \(parts[0])")
                    }
                }
                if key == "default" { all.defaults = options } else { all.games[key] = options }
                try all.save()
                print("\(key): \(options.graphics.title), Vulkan \(options.vulkanDriver.title), HUD \(options.metalHUD ? "an" : "aus")")
            case "env":
                // env <App-ID>: the environment a game gets, as export lines for a shell.
                let appID = arguments.dropFirst().first
                let options = settings.options(for: appID)
                let env = LaunchEnvironment.game(engine: EngineInstaller.directory, prefix: Launcher.bottle.prefix, options: options)
                    .merging(appID.flatMap { GameFixes.all[$0]?.environment } ?? [:]) { _, fixed in fixed }
                for key in env.keys.sorted() { print("export \(key)=\"\(env[key]!)\"") }
            case "reset":
                guard arguments.count > 1 else { print("Aufruf: reset <App-ID>"); return 2 }
                var all = settings
                all.games[arguments[1]] = nil
                try all.save()
                let options = all.options(for: arguments[1])
                print("\(arguments[1]): eigene Einstellungen entfernt → \(options.graphics.title), Vulkan \(options.vulkanDriver.title), Startoptionen \"\(options.arguments)\"")
            case "run":
                guard arguments.count > 2, let graphics = Graphics(rawValue: arguments[1]) else {
                    print("Aufruf: run <d3dmetal|dxmt|dxvk|wined3d> <Programm.exe> [moltenVK|kosmicKrisp]"); return 2
                }
                var options = settings.defaults
                options.graphics = graphics
                if arguments.count > 3, let driver = VulkanDriver(rawValue: arguments[3]) { options.vulkanDriver = driver }
                let log = Paths.logs.appendingPathComponent("run-\(graphics.rawValue).log")
                let status = try await Launcher.run(windowsProgram: arguments[2], options: options, log: log)
                print(Shell.logTail(log, lines: 20))
                return status
            default:
                print("Befehle: status, install-engine, setup, steam [--wait], games, play <App-ID>, quit <App-ID>, uninstall <App-ID> [--dry-run], accounts, account <ID|neu>, displays, stop, set, reset, env, guard, run <grafik> <exe>")
                return command == "help" ? 0 : 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Fehler: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
