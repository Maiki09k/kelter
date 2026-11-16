import AppKit
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case library, steam, engine
    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Bibliothek"
        case .steam: "Steam"
        case .engine: "Engine"
        }
    }

    var symbol: String {
        switch self {
        case .library: "square.grid.2x2"
        case .steam: "gamecontroller"
        case .engine: "cpu"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    // KELTER_PAGE=steam|engine opens that page at launch (used for checking the layout).
    @State private var selection: SidebarItem? =
        SidebarItem(rawValue: ProcessInfo.processInfo.environment["KELTER_PAGE"] ?? "") ?? .library

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { StatusFooter().padding(12) }
        } detail: {
            switch selection ?? .library {
            case .library: LibraryView()
            case .steam: SteamView()
            case .engine: EngineView()
            }
        }
        .alert("Das hat nicht geklappt", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct StatusFooter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.steamRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(model.statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

// MARK: Library

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    // KELTER_SELECT=<App-ID> opens a game's settings at launch (used for checking the layout).
    @State private var selected: InstalledGame.ID? = ProcessInfo.processInfo.environment["KELTER_SELECT"]
    @State private var pendingUninstall: InstalledGame?

    // Top alignment keeps covers in one line when a card below shows download progress.
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20, alignment: .top)]

    var body: some View {
        Group {
            if model.phase != .ready {
                SetupView()
            } else if model.games.isEmpty {
                EmptyLibraryView()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(model.games) { game in
                            GameCard(game: game, isSelected: selected == game.id, isRunning: model.isRunning(game))
                                .onTapGesture { selected = game.id }
                                .onTapGesture(count: 2) { if game.isReady { model.play(game) } }
                            .contextMenu {
                                if model.isRunning(game) {
                                    Button("Beenden") { model.stopGame(game) }
                                } else {
                                    Button("Spielen") { model.play(game) }.disabled(!game.isReady || model.busy != nil)
                                }
                                Button("Spielordner im Finder zeigen") { model.reveal(game.installDirectory) }
                                Divider()
                                Button("Deinstallieren …") { pendingUninstall = game }
                                    .disabled(model.isRunning(game) || model.busy != nil)
                            }
                        }
                    }
                    .padding(24)
                }
                .inspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                    if let game = model.games.first(where: { $0.id == selected }) {
                        GameInspector(game: game, pendingUninstall: $pendingUninstall)
                            .inspectorColumnWidth(min: 300, ideal: 330, max: 420)
                    }
                }
            }
        }
        .navigationTitle("Bibliothek")
        .toolbar { SteamToolbar() }
        .confirmationDialog(uninstallTitle, isPresented: Binding(
            get: { pendingUninstall != nil },
            set: { if !$0 { pendingUninstall = nil } }
        ), titleVisibility: .visible, presenting: pendingUninstall) { game in
            Button("In den Papierkorb legen", role: .destructive) {
                if selected == game.id { selected = nil }
                model.uninstall(game)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { game in
            Text(uninstallMessage(game))
        }
    }

    private var uninstallTitle: String {
        "\(pendingUninstall?.name ?? "Spiel") deinstallieren?"
    }

    private func uninstallMessage(_ game: InstalledGame) -> String {
        let size = game.sizeOnDisk > 0 ? " (" + ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file) + ")" : ""
        let steam = model.steamRunning ? " Steam wird dafür kurz angehalten." : ""
        return "Spielordner\(size), Shader-Cache und Steams Eintrag kommen in den Papierkorb; der Platz wird frei, sobald du ihn leerst. Spielstände in der Steam-Cloud bleiben erhalten.\(steam)"
    }
}

struct SteamToolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.phase == .ready {
                AccountMenu()
                if model.steamRunning {
                    Button("Steam beenden", systemImage: "stop.circle") { model.stopSteam() }
                }
                Button("Spiele installieren", systemImage: "arrow.down.circle") { model.openInSteam("steam://open/games") }
                    .help("Öffnet deine Steam-Bibliothek. Dort „Installieren“ wählen; das Spiel erscheint dann hier mit Fortschritt.")
                    .disabled(model.busy != nil)
                Button("Steam öffnen", systemImage: "arrow.up.forward.app") { model.openSteam() }
                    .disabled(model.busy != nil)
            }
        }
    }
}

/// Quick switch between remembered Steam accounts, next to the Steam buttons.
struct AccountMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.accounts) { account in
                Button {
                    model.switchAccount(to: account)
                } label: {
                    if account.id == model.activeAccount?.id {
                        Label(account.title, systemImage: "checkmark")
                    } else {
                        Text(account.title)
                    }
                }
            }
            if !model.accounts.isEmpty { Divider() }
            Button("Konto hinzufügen …") { model.addAccount() }
        } label: {
            Label(model.activeAccount?.title ?? "Steam-Konto", systemImage: "person.crop.circle")
                .labelStyle(.titleAndIcon)
        }
        .help("Steam-Konto wechseln oder hinzufügen")
        .disabled(model.busy != nil)
    }
}

struct GameCard: View {
    let game: InstalledGame
    let isSelected: Bool
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Cover(url: game.cover, title: game.name)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.08)),
                                      lineWidth: isSelected ? 3 : 1)
                )
            Text(game.name)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            if isRunning {
                Label("Läuft", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(RunningLabelStyle())
            } else if let progress = game.downloadProgress {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: progress)
                    Text(DownloadText.short(game))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if !game.isReady {
                Text("Wartet auf Steam")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

enum DownloadText {
    static func short(_ game: InstalledGame) -> String {
        let percent = Int(((game.downloadProgress ?? 0) * 100).rounded(.down))
        let total = ByteCountFormatter.string(fromByteCount: game.bytesToDownload, countStyle: .file)
        return "Lädt \(percent) % von \(total)"
    }
}

/// A small dot in front of the text, the same as the Steam status in the sidebar.
struct RunningLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6))
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

struct Cover: View {
    let url: URL?
    let title: String

    var body: some View {
        if let url, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            // Steam caches cover art only once a game appeared in its own library. Until then Kelter
            // draws one: a calm colour picked from the name, the title set like a book cover.
            let colors = Self.palette(for: title)
            // Overlays only: the gradient alone decides the size, so every card keeps the same width.
            LinearGradient(colors: [colors.top, colors.bottom], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .topTrailing) {
                    Text(String(title.prefix(1)))
                        .font(.system(size: 240, weight: .black, design: .serif))
                        .foregroundStyle(.white.opacity(0.07))
                        .fixedSize()
                        .offset(x: 36, y: -50)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Rectangle().fill(.white.opacity(0.5)).frame(width: 28, height: 2)
                        Text(title)
                            .font(.system(size: 21, weight: .bold, design: .serif))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(4)
                            .minimumScaleFactor(0.6)
                    }
                    .padding(16)
                }
                .clipped()
                .accessibilityElement()
                .accessibilityLabel(title)
        }
    }

    private static let palettes: [(top: Color, bottom: Color)] = [
        (Color(red: 0.47, green: 0.11, blue: 0.19), Color(red: 0.20, green: 0.04, blue: 0.08)), // wine
        (Color(red: 0.16, green: 0.25, blue: 0.36), Color(red: 0.06, green: 0.09, blue: 0.15)), // slate
        (Color(red: 0.13, green: 0.33, blue: 0.27), Color(red: 0.04, green: 0.12, blue: 0.10)), // forest
        (Color(red: 0.56, green: 0.36, blue: 0.13), Color(red: 0.24, green: 0.13, blue: 0.04)), // ochre
        (Color(red: 0.07, green: 0.34, blue: 0.40), Color(red: 0.02, green: 0.13, blue: 0.17)), // petrol
        (Color(red: 0.33, green: 0.31, blue: 0.29), Color(red: 0.12, green: 0.11, blue: 0.10)), // stone
    ]

    /// The same name always gets the same colour (no Hasher: its seed changes on every launch).
    static func palette(for title: String) -> (top: Color, bottom: Color) {
        palettes[title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % palettes.count]
    }
}

struct GameInspector: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @Binding var pendingUninstall: InstalledGame?

    var body: some View {
        let options = Binding(
            get: { model.options(for: game) },
            set: { model.setOptions($0, for: game) }
        )
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(game.name).font(.title3.weight(.semibold))
                    Text(sizeText).foregroundStyle(.secondary)
                    if model.isRunning(game) {
                        Button(role: .destructive) {
                            model.stopGame(game)
                        } label: {
                            Text("Beenden").frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .disabled(model.busy != nil)
                        Text("Läuft. Beenden schließt das Spiel sofort, auch wenn es hängt; nicht Gespeichertes geht verloren.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            model.play(game)
                        } label: {
                            Text("Spielen").frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .disabled(!game.isReady || model.busy != nil)
                        if let progress = game.downloadProgress {
                            ProgressView(value: progress)
                            Text(DownloadText.short(game) + (model.steamRunning ? "" : ". Steam ist aus; der Download läuft weiter, sobald Steam läuft."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !game.isReady {
                            Text("Steam muss das Spiel noch laden oder aktualisieren. Den Stand zeigt Steam unter „Downloads verwalten“.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let owner = otherOwner {
                            Text("Installiert von „\(owner)“. Mit dem aktiven Konto startet es nur, wenn dieses das Spiel auch besitzt oder geliehen hat (Familienbibliothek).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if let fix = GameFixes.all[game.appID] {
                Section("Kelter-Anpassung") {
                    Text(fix.note).foregroundStyle(.secondary)
                    let fixed = fix.arguments()
                    if !fixed.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Feste Startoptionen")
                            Text(fixed.joined(separator: " "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            OptionsSection(options: options)
            Section {
                Button("Spielordner im Finder zeigen") { model.reveal(game.installDirectory) }
                if model.hasOwnOptions(game) {
                    Button("Auf Standard zurücksetzen") { model.resetOptions(for: game) }
                }
                Button("Deinstallieren …", role: .destructive) { pendingUninstall = game }
                    .disabled(model.isRunning(game) || model.busy != nil)
            }
        }
        .formStyle(.grouped)
    }

    /// Name of the account that installed the game, when it is not the active one.
    private var otherOwner: String? {
        guard let owner = game.lastOwner, owner != "0", let active = model.activeAccount, owner != active.steamID else { return nil }
        return model.accounts.first(where: { $0.steamID == owner })?.title ?? "anderes Konto"
    }

    private var sizeText: String {
        guard game.sizeOnDisk > 0 else { return "App-ID \(game.appID)" }
        let size = ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file)
        return "\(size) · App-ID \(game.appID)"
    }
}

struct OptionsSection: View {
    @Binding var options: GameOptions

    var body: some View {
        DisplaySection(options: $options)
        Section("Grafik") {
            Picker("Übersetzer", selection: $options.graphics) {
                ForEach(Graphics.allCases) { Text($0.title).tag($0) }
            }
            Text(options.graphics.detail).font(.callout).foregroundStyle(.secondary)
            switch options.graphics {
            case .automatic, .d3dmetal:
                Toggle("DLSS durch MetalFX ersetzen", isOn: $options.dlssToMetalFX)
                Toggle("Raytracing", isOn: $options.rayTracing)
            case .dxmt:
                Toggle("Mit MetalFX hochskalieren", isOn: $options.metalFXUpscaling)
            case .dxvk, .vulkan, .wined3d:
                EmptyView()
            }
            if options.graphics == .automatic || options.graphics == .dxvk {
                Toggle("DirectX-9-Shader im Hintergrund übersetzen", isOn: $options.asyncShaders)
                    .help("Weniger Ruckler beim ersten Mal, dafür fehlen Objekte kurz oder ploppen auf. Aus = sauberes Bild.")
            }
            Toggle("Metal-Leistungsanzeige", isOn: $options.metalHUD)
        }
        Section("Vulkan") {
            Picker("Treiber", selection: $options.vulkanDriver) {
                ForEach(VulkanDriver.allCases) { Text($0.title).tag($0) }
            }
            Text(options.vulkanDriver.detail).font(.callout).foregroundStyle(.secondary)
            Toggle("Schnelle Shader-Mathematik", isOn: $options.fastMath)
            Text(options.fastMath
                 ? "An: etwas mehr FPS, aber bekannte Ursache für flackernde Kanten und falsche Farben."
                 : "Aus: rechnet so genau wie Windows, saubereres Bild. Empfohlen.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section("System") {
            Toggle("AVX für Rosetta melden", isOn: $options.advertiseAVX)
            Toggle("Schnelle Synchronisierung (MSync)", isOn: $options.fastSync)
            TextField("Startoptionen", text: $options.arguments, prompt: Text("zum Beispiel -dx11"))
        }
    }
}

/// Which screen a game opens on and at which resolution.
struct DisplaySection: View {
    @EnvironmentObject var model: AppModel
    @Binding var options: GameOptions

    var body: some View {
        let target = targetDisplay
        Section("Bildschirm") {
            Picker("Bildschirm", selection: $options.display) {
                Text(automaticTitle).tag(Displays.automatic)
                ForEach(model.displays) { display in
                    Text(display.name).tag(display.id)
                }
                if options.display != Displays.automatic, !model.displays.contains(where: { $0.id == options.display }) {
                    Text("Gespeicherter Bildschirm (nicht angeschlossen)").tag(options.display)
                }
            }
            Picker("Auflösung", selection: $options.resolution) {
                Text("Wie macOS" + (target.map { " (\($0.current.title))" } ?? "")).tag(Displays.macOSResolution)
                Text("Volle Auflösung" + (target?.resolutions.first.map { " (\($0.title))" } ?? "")).tag(Displays.nativeResolution)
                ForEach(otherResolutions(target), id: \.self) { resolution in
                    Text(resolution.title).tag(resolution.tag)
                }
                if !knownTags(target).contains(options.resolution) {
                    Text(DisplayResolution(tag: options.resolution)?.title ?? options.resolution).tag(options.resolution)
                }
            }
            Text(explanation(target))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var automaticTitle: String {
        model.displays.contains(where: { !$0.isBuiltIn }) ? "Automatisch (extern)" : "Automatisch"
    }

    /// The display the game would open on right now.
    private var targetDisplay: GameDisplay? {
        if let chosen = model.displays.first(where: { $0.id == options.display }) { return chosen }
        let external = model.displays.filter { !$0.isBuiltIn }
        return external.first(where: \.isMain) ?? external.first ?? model.displays.first(where: \.isBuiltIn) ?? model.displays.first
    }

    private func otherResolutions(_ display: GameDisplay?) -> [DisplayResolution] {
        guard let display else { return [] }
        return Array(display.resolutions.dropFirst().filter { $0.width >= 1280 }.prefix(6))
    }

    private func knownTags(_ display: GameDisplay?) -> [String] {
        [Displays.macOSResolution, Displays.nativeResolution] + otherResolutions(display).map(\.tag)
    }

    private func explanation(_ display: GameDisplay?) -> String {
        guard let display else { return "Kein Bildschirm erkannt." }
        var text = options.display == Displays.automatic
            ? "Automatisch nimmt einen angeschlossenen externen Bildschirm, sonst den eingebauten. Gerade: „\(display.name)“"
            : "Das Spiel öffnet auf „\(display.name)“"
        if !display.isMain { text += ", Kelter macht ihn solange zum Hauptbildschirm (Menüleiste)" }
        switch options.resolution {
        case Displays.macOSResolution:
            text += ". Auflösung wie am Mac eingestellt: am flüssigsten."
        default:
            text += ". Kelter stellt den Bildschirm auf jeden echten Pixel um: schärfer, braucht aber mehr Grafikleistung."
        }
        return text + " Nach dem Spiel stellt Kelter alles zurück."
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Text("Noch keine Spiele installiert").font(.title2.weight(.semibold))
            Text("Öffne Steam, melde dich an und installiere ein Spiel. Es erscheint dann hier.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Steam öffnen") { model.openSteam() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy != nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Steam auf dem Mac einrichten").font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                SetupLine(number: 1, text: "Engine laden: Wine 11 mit D3DMetal, DXMT und DXVK (rund 260 MB)")
                SetupLine(number: 2, text: "Windows-Umgebung anlegen und Steam installieren")
                SetupLine(number: 3, text: "Steam lädt sich beim ersten Start nach (rund 400 MB), dann meldest du dich an")
            }
            switch model.phase {
            case let .settingUp(message, fraction):
                VStack(alignment: .leading, spacing: 8) {
                    if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                    Text(message).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 460)
            default:
                Button("Einrichten") { model.setUp() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Text("Etwa 5 bis 10 Minuten, je nach Leitung. Spiele mit Kernel-Anti-Cheat laufen nicht.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct SetupLine: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
        }
    }
}

// MARK: Steam and engine

struct SteamView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Steam") {
                LabeledContent("Status", value: statusText)
                HStack {
                    Button("Steam öffnen") { model.openSteam() }
                        .disabled(model.phase != .ready || model.busy != nil)
                    if model.steamRunning {
                        Button("Steam beenden") { model.stopSteam() }
                    }
                }
            }
            Section {
                ForEach(model.accounts) { account in
                    AccountRow(account: account, isActive: account.id == model.activeAccount?.id)
                }
                Button("Konto hinzufügen …") { model.addAccount() }
                    .disabled(model.phase != .ready || model.busy != nil)
                Text("Wechseln startet Steam mit dem gewählten Konto neu, ohne Passwort, solange Steam es sich gemerkt hat. Neue Konten meldest du in Steams eigenem Fenster an („Angemeldet bleiben“ anhaken); Kelter sieht keine Passwörter. Alle Konten teilen sich die installierten Spiele.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Konten")
            }
            Section {
                Toggle("Game Mode beim Spielen erzwingen", isOn: $model.settings.forceGameMode)
                    .disabled(!model.gameModeAvailable)
                Text(model.gameModeAvailable
                     ? "Gibt dem Spiel Vorrang bei CPU und GPU und senkt die Bluetooth-Latenz; bei DOOM Eternal rund 8 % mehr FPS. Das ist eine macOS-Einstellung; Kelter stellt sie wieder auf Automatisch, sobald kein Spiel mehr läuft."
                     : "Braucht Xcode (Werkzeug gamepolicyctl).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Leistung")
            }
            Section {
                OptionsSection(options: Binding(
                    get: { model.options(for: nil) },
                    set: { model.setOptions($0, for: nil) }
                ))
            } header: {
                Text("Standard für Spiele ohne eigene Einstellungen")
            }
            Section("Ordner und Protokolle") {
                Button("Steam-Ordner im Finder zeigen") { model.reveal(Launcher.steam.directory) }
                Button("Steam-Protokoll öffnen") { model.openLog(Launcher.steam.log) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Steam")
    }

    private var statusText: String {
        if model.phase != .ready { return "Noch nicht eingerichtet" }
        if model.steamRunning { return "Läuft" }
        return model.steamBootstrapped ? "Bereit" : "Lädt sich beim ersten Start nach"
    }
}

struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let account: SteamAccount
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let url = account.avatar, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(account.title)
                if account.personaName != account.accountName {
                    Text(account.accountName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isActive {
                Label(model.steamRunning ? "Angemeldet" : "Aktiv", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(RunningLabelStyle())
            } else {
                Button("Wechseln") { model.switchAccount(to: account) }
                    .disabled(model.phase != .ready || model.busy != nil)
            }
        }
    }
}

struct EngineView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Engine") {
                LabeledContent("Wine", value: "Sikarugir 11.0 (Gcenx)")
                LabeledContent("Grafik", value: "D3DMetal, DXMT, DXVK, WineD3D")
                LabeledContent("Vulkan", value: "MoltenVK 1.4.2, dazu Kelters Anpassung für id-Tech-Spiele")
                LabeledContent("Status", value: EngineInstaller.isInstalled ? "Installiert" : "Fehlt")
                Button("Engine-Ordner im Finder zeigen") { model.reveal(EngineInstaller.directory) }
                    .disabled(!EngineInstaller.isInstalled)
            }
            Section("Grenzen") {
                Text("Spiele mit Kernel-Anti-Cheat (zum Beispiel Call of Duty, Valorant, Rainbow Six Siege) laufen unter Wine nicht. Manche DirectX-12-Spiele stottern oder starten nicht; dann hilft oft ein anderer Übersetzer.")
                    .foregroundStyle(.secondary)
            }
            Section("Herkunft") {
                Text("Wine-Engine und Laufzeitbibliotheken: Sikarugir (Gcenx, LGPL). D3DMetal: Apple Game Porting Toolkit, nur für den privaten Gebrauch. DXMT: 3Shain. DXVK: Philip Rebohle und Mitwirkende. MoltenVK und SPIRV-Cross: Khronos Group (Apache 2.0), für DOOM Eternal mit Kelters Patches selbst gebaut.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Engine")
    }
}
