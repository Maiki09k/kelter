import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case needsSetup
        case settingUp(String, Double?)
        case ready
    }

    @Published private(set) var phase: Phase = .needsSetup
    @Published private(set) var games: [InstalledGame] = []
    @Published private(set) var steamRunning = false
    @Published private(set) var steamBootstrapped = false
    /// App ids of games that run right now.
    @Published private(set) var runningGames: Set<String> = []
    /// Looked up once in the background: finding gamepolicyctl runs xcrun, never from a view body.
    @Published private(set) var gameModeAvailable = false
    @Published private(set) var busy: String?
    /// Remembered Steam accounts and the one Steam signs in (AutoLoginUser).
    @Published private(set) var accounts: [SteamAccount] = []
    @Published private(set) var activeAccountName: String?
    /// SteamID64 signed in right now (only while Steam runs).
    @Published private(set) var signedInID: String?
    /// Connected displays for the game settings, updated when one is plugged in or removed.
    @Published private(set) var displays: [GameDisplay] = []
    @Published var errorMessage: String?
    @Published var settings = KelterSettings.load() {
        didSet { try? settings.save() }
    }

    private var timer: Timer?
    /// A game started through Steam needs a few seconds before its process shows up.
    private var lastLaunch: Date?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        Task.detached(priority: .utility) {
            let available = GameMode.isAvailable
            await MainActor.run { self.gameModeAvailable = available }
        }
        // Never leave Game Mode forced on or a display switched after Kelter quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            GameMode.release()
            DisplaySwitcher.restore()
        }
        displays = Displays.list()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displays = Displays.list() }
        }
    }

    var isReady: Bool {
        EngineInstaller.isInstalled && Launcher.bottle.exists && Launcher.steam.isInstalled
    }

    func refresh() {
        if case .settingUp = phase { return }
        phase = isReady ? .ready : .needsSetup
        let launchedRecently = lastLaunch.map { Date().timeIntervalSince($0) < 60 } ?? false
        Task.detached(priority: .utility) {
            let steam = Launcher.steam
            let running = Launcher.bottle.isRunning
            let bootstrapped = steam.isBootstrapped
            let games = steam.isInstalled ? SteamLibrary.scan(steam) : []
            let playing = running ? GameProcess.running(games) : []
            let accounts = steam.accounts
            let active = steam.autoLoginUser
            let signedIn = running ? steam.signedInSteamID : nil
            // No game left: hand Game Mode and the display back to macOS.
            if playing.isEmpty && !launchedRecently {
                GameMode.release()
                DisplaySwitcher.restore()
            }
            await MainActor.run {
                if self.games != games { self.games = games }
                if self.runningGames != playing { self.runningGames = playing }
                if self.accounts != accounts { self.accounts = accounts }
                if self.activeAccountName != active { self.activeAccountName = active }
                if self.signedInID != signedIn { self.signedInID = signedIn }
                self.steamRunning = running
                self.steamBootstrapped = bootstrapped
            }
        }
    }

    func options(for game: InstalledGame?) -> GameOptions { settings.options(for: game?.appID) }

    func setOptions(_ options: GameOptions, for game: InstalledGame?) {
        if let game { settings.games[game.appID] = options } else { settings.defaults = options }
    }

    func resetOptions(for game: InstalledGame) {
        settings.games[game.appID] = nil
    }

    func hasOwnOptions(_ game: InstalledGame) -> Bool { settings.games[game.appID] != nil }

    // MARK: Actions

    func setUp() {
        guard case .needsSetup = phase else { return }
        phase = .settingUp("Wird vorbereitet …", nil)
        let options = settings.defaults
        Task {
            do {
                try await Launcher.setUp(options: options) { step in
                    Task { @MainActor in self.show(step) }
                }
                phase = .ready
            } catch {
                phase = .needsSetup
                errorMessage = error.localizedDescription
            }
            refresh()
        }
    }

    private func show(_ step: Launcher.SetupStep) {
        switch step {
        case let .engine(.downloading(file, fraction)):
            phase = .settingUp("Engine wird geladen (\(file))", fraction)
        case .engine(.unpacking):
            phase = .settingUp("Engine wird entpackt …", nil)
        case .bottle:
            phase = .settingUp("Windows-Umgebung wird angelegt …", nil)
        case .steam:
            phase = .settingUp("Steam wird installiert …", nil)
        case .firstStart:
            phase = .settingUp("Steam startet zum ersten Mal und lädt sich nach. Danach erscheint die Anmeldung.", nil)
        }
    }

    func openSteam() {
        perform("Steam wird geöffnet …") { [settings] in
            try await Launcher.openSteam(options: settings.defaults)
        }
    }

    func stopSteam() {
        perform("Steam wird beendet …") {
            await Launcher.stopSteam()
            GameMode.release()
        }
    }

    func isRunning(_ game: InstalledGame) -> Bool { runningGames.contains(game.appID) }

    func play(_ game: InstalledGame) {
        guard !isRunning(game), busy == nil else { return }  // a second start would open the game twice
        let options = options(for: game)
        let defaults = settings.defaults
        let forceGameMode = settings.forceGameMode
        lastLaunch = Date()
        let model = self
        perform("\(game.name) startet …") {
            try await Launcher.play(appID: game.appID, options: options, steamDefaults: defaults) { text in
                Task { @MainActor in
                    model.lastLaunch = Date()
                    if model.busy != nil { model.busy = text }
                }
            }
            if forceGameMode { GameMode.force() }
        }
    }

    /// Opens Steam's install dialog for a game, or its store page.
    func openInSteam(_ link: String) {
        perform("Steam wird geöffnet …") { [settings] in
            try await Launcher.openInSteam(link, options: settings.defaults)
        }
    }

    /// The remembered account Steam signs in, if any.
    /// The account Steam is signed in with, else the one it signs in on its next start.
    var activeAccount: SteamAccount? {
        if let signedInID, let account = accounts.first(where: { $0.steamID == signedInID }) { return account }
        guard let name = activeAccountName, !name.isEmpty else { return nil }
        return accounts.first { $0.accountName.caseInsensitiveCompare(name) == .orderedSame }
    }

    func switchAccount(to account: SteamAccount) {
        guard busy == nil, account.id != activeAccount?.id || !steamRunning else { return }
        let defaults = settings.defaults
        let model = self
        perform("Wechsel zu \(account.title) …") {
            try await Launcher.switchAccount(to: account, options: defaults) { text in
                Task { @MainActor in if model.busy != nil { model.busy = text } }
            }
        }
    }

    func addAccount() {
        guard busy == nil else { return }
        let defaults = settings.defaults
        perform("Steam öffnet die Anmeldung …") {
            try await Launcher.addAccount(options: defaults)
        }
    }

    func uninstall(_ game: InstalledGame) {
        guard !isRunning(game), busy == nil else { return }
        let defaults = settings.defaults
        perform("\(game.name) wird deinstalliert …") {
            try await Launcher.uninstall(game, options: defaults)
        }
    }

    /// Ends a game, also one that hangs.
    func stopGame(_ game: InstalledGame) {
        lastLaunch = nil
        perform("\(game.name) wird beendet …") {
            if await !GameProcess.stop(game) {
                throw KelterError.message("\(game.name) ließ sich nicht beenden.")
            }
        }
    }

    /// What the sidebar footer says.
    var statusLine: String {
        if let busy { return busy }
        if let game = games.first(where: isRunning) { return "\(game.name) läuft" }
        let account = activeAccount.map { " · \($0.title)" } ?? ""
        return steamRunning ? "Steam läuft\(account)" : "Steam ist aus\(account)"
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openLog(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func perform(_ message: String, _ work: @escaping @Sendable () async throws -> Void) {
        busy = message
        Task {
            do { try await work() } catch { errorMessage = error.localizedDescription }
            // Steam needs a moment before its wineserver shows up.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            busy = nil
            refresh()
        }
    }
}
