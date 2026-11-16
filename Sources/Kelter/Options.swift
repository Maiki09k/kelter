import Foundation

/// Which Vulkan implementation games that render with Vulkan (Doom Eternal, DXVK) talk to.
enum VulkanDriver: String, Codable, CaseIterable, Identifiable, Sendable {
    case moltenVK, moltenVKGames, kosmicKrisp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moltenVK: "MoltenVK"
        case .moltenVKGames: "MoltenVK für Spiele"
        case .kosmicKrisp: "KosmicKrisp"
        }
    }

    var detail: String {
        switch self {
        case .moltenVK: "Bewährt, aber ohne einige Vulkan-Funktionen."
        case .moltenVKGames: "Kelters MoltenVK 1.4.2 mit Anpassung für id-Tech-Spiele wie DOOM Eternal: meldet Funktionen, die Metal nicht hat."
        case .kosmicKrisp: "Mesa-Treiber mit vollem Vulkan 1.3. Experimentell: im Test kam das Bild schwarz an."
        }
    }

    var icdFile: String {
        switch self {
        case .moltenVK: "MoltenVK_icd.json"
        case .moltenVKGames: EngineInstaller.gamesMoltenVKICD
        case .kosmicKrisp: "kosmickrisp_mesa_icd.json"
        }
    }
}

/// Settings for one game, or for Steam itself when no game is chosen.
struct GameOptions: Codable, Equatable, Hashable, Sendable {
    var graphics: Graphics = .automatic
    var vulkanDriver: VulkanDriver = .moltenVK
    var metalHUD = false
    var advertiseAVX = true
    var fastSync = true
    var dlssToMetalFX = true
    var rayTracing = false
    var metalFXUpscaling = false
    /// Metal's fast math in MoltenVK: a few FPS more, but known for depth flicker and wrong
    /// colours (MoltenVK PR #1179, issue #2055). Off by default.
    var fastMath = false
    /// DXVK compiles shaders in the background and skips draws meanwhile: less stutter, but
    /// objects pop in or are missing for a moment. Off by default.
    var asyncShaders = false
    var arguments = ""
    /// "auto" (external display if connected), "builtin" or a display key (see Displays.key).
    var display = Displays.automatic
    /// "macos" (keep the Mac's resolution), "native" (all pixels) or "WIDTHxHEIGHT".
    var resolution = Displays.macOSResolution

    init() {}

    // Tolerates settings files written by older versions with fewer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = GameOptions()
        graphics = (try? c.decode(Graphics.self, forKey: .graphics)) ?? fallback.graphics
        vulkanDriver = (try? c.decode(VulkanDriver.self, forKey: .vulkanDriver)) ?? fallback.vulkanDriver
        metalHUD = (try? c.decode(Bool.self, forKey: .metalHUD)) ?? fallback.metalHUD
        advertiseAVX = (try? c.decode(Bool.self, forKey: .advertiseAVX)) ?? fallback.advertiseAVX
        fastSync = (try? c.decode(Bool.self, forKey: .fastSync)) ?? fallback.fastSync
        dlssToMetalFX = (try? c.decode(Bool.self, forKey: .dlssToMetalFX)) ?? fallback.dlssToMetalFX
        rayTracing = (try? c.decode(Bool.self, forKey: .rayTracing)) ?? fallback.rayTracing
        metalFXUpscaling = (try? c.decode(Bool.self, forKey: .metalFXUpscaling)) ?? fallback.metalFXUpscaling
        fastMath = (try? c.decode(Bool.self, forKey: .fastMath)) ?? fallback.fastMath
        asyncShaders = (try? c.decode(Bool.self, forKey: .asyncShaders)) ?? fallback.asyncShaders
        arguments = (try? c.decode(String.self, forKey: .arguments)) ?? fallback.arguments
        display = (try? c.decode(String.self, forKey: .display)) ?? fallback.display
        resolution = (try? c.decode(String.self, forKey: .resolution)) ?? fallback.resolution
    }

    /// What Steam's own environment depends on. Start options travel with "-applaunch" and the
    /// display is set by Kelter, so neither may force a Steam restart.
    var steamProfile: GameOptions {
        var profile = self
        profile.arguments = ""
        profile.display = Displays.automatic
        profile.resolution = Displays.macOSResolution
        return profile
    }

    /// Splits the free text arguments like a shell would for simple cases ("a b" "c").
    var argumentList: [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for character in arguments {
            if character == "\"" { quoted.toggle(); continue }
            if character == " " && !quoted {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

struct KelterSettings: Codable, Equatable {
    var defaults = GameOptions()
    var games: [String: GameOptions] = [:]
    /// Forces macOS Game Mode on while a game runs (system policy, reset to automatic afterwards).
    var forceGameMode = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaults = (try? c.decode(GameOptions.self, forKey: .defaults)) ?? GameOptions()
        games = (try? c.decode([String: GameOptions].self, forKey: .games)) ?? [:]
        forceGameMode = (try? c.decode(Bool.self, forKey: .forceGameMode)) ?? false
    }

    /// The player's own settings for a game, else the defaults with Kelter's known fixes for it.
    func options(for appID: String?) -> GameOptions {
        guard let appID else { return defaults }
        return games[appID] ?? GameFixes.options(for: appID, base: defaults)
    }

    static func load() -> KelterSettings {
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              let settings = try? JSONDecoder().decode(KelterSettings.self, from: data) else { return KelterSettings() }
        return settings
    }

    func save() throws {
        try Paths.ensure(Paths.root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.settingsFile, options: .atomic)
    }
}

/// The environment every Wine process gets. Pass it straight to the wine binary: anything that
/// goes through a system tool (/usr/bin/env, nohup, sh) loses the DYLD_ variables to SIP.
enum LaunchEnvironment {
    static func base(engine: URL, prefix: URL) -> [String: String] {
        let icd = engine.appendingPathComponent("Resources/vulkan/icd.d/MoltenVK_icd.json").path
        return [
            "WINEPREFIX": prefix.path,
            // Sikarugir's Wine only starts child processes when it knows it runs as a Wine 11 wrapper.
            "SikarugirAppWine11": "1",
            "DYLD_FALLBACK_LIBRARY_PATH": engine.appendingPathComponent("Frameworks").path + ":/usr/lib",
            "WINEDEBUG": "-all",
            "WINEBOOT_HIDE_DIALOG": "1",
            "VK_DRIVER_FILES": icd,
            "VK_ICD_FILENAMES": icd,
            "GST_PLUGIN_PATH": engine.appendingPathComponent("Frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0").path,
            // Quiet unless set from outside (for example MVK_CONFIG_LOG_LEVEL=2 to measure frame times).
            "MVK_CONFIG_LOG_LEVEL": ProcessInfo.processInfo.environment["MVK_CONFIG_LOG_LEVEL"] ?? "0",
        ]
    }

    /// Bumped when the environment of a running Steam changes meaning, so Kelter restarts an old
    /// Steam once instead of starting games with outdated settings. 2: ESync flag, fast math off.
    static let revision = 2

    static func game(engine: URL, prefix: URL, options: GameOptions) -> [String: String] {
        var env = base(engine: engine, prefix: prefix)
        let icd = engine.appendingPathComponent("Resources/vulkan/icd.d/\(options.vulkanDriver.icdFile)").path
        env["VK_DRIVER_FILES"] = icd
        env["VK_ICD_FILENAMES"] = icd
        // id Tech's launcher only accepts NVIDIA, AMD or Intel; Kelter's MoltenVK reports AMD on request.
        if options.vulkanDriver == .moltenVKGames { env["KELTER_MVK_VENDOR_AMD"] = "1" }
        if options.fastSync {
            env["WINEMSYNC"] = "1"
            // D3DMetal checks for ESync and misbehaves under MSync without it (Whisky sets both,
            // BottleSettings.swift; Wine itself prefers MSync when both are set).
            env["WINEESYNC"] = "1"
        }
        // MoltenVK 1.4 enables fast math "on demand", which in practice means on for most games.
        env["MVK_CONFIG_FAST_MATH_ENABLED"] = options.fastMath ? "1" : "0"
        if options.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if options.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }

        let renderer = engine.appendingPathComponent("renderer")
        switch options.graphics {
        case .automatic:
            // The engine picks per DLL: D3DMetal wins for 64-bit d3d11/d3d12/dxgi, DXMT supplies
            // the 32-bit ones, and the DX9-only DXVK folder supplies d3d9. Measured 14.11.2026:
            // all four cases (DX9/DX11, 32/64 bit) draw at the display's 120 Hz.
            env["WINEDLLPATH_D3DMETAL"] = renderer.appendingPathComponent("d3dmetal/wine").path
            env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = renderer.appendingPathComponent("d3dmetal/external/libd3dshared.dylib").path
            env["WINEDLLPATH_DXMT"] = renderer.appendingPathComponent("dxmt/wine").path
            env["WINEDLLPATH_D9VK"] = renderer.appendingPathComponent(EngineInstaller.dx9OnlyRenderer + "/wine").path
            env["DXMT_CONFIG"] = dxmtCorrectness
            if options.asyncShaders { env["DXVK_ASYNC"] = "1" }
            env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
            if options.dlssToMetalFX { env["D3DM_ENABLE_METALFX"] = "1" }
            if options.rayTracing { env["D3DM_SUPPORT_DXR"] = "1" }
        case .d3dmetal:
            env["WINEDLLPATH_D3DMETAL"] = renderer.appendingPathComponent("d3dmetal/wine").path
            env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = renderer.appendingPathComponent("d3dmetal/external/libd3dshared.dylib").path
            if options.dlssToMetalFX { env["D3DM_ENABLE_METALFX"] = "1" }
            if options.rayTracing { env["D3DM_SUPPORT_DXR"] = "1" }
        case .dxmt:
            env["WINEDLLPATH_DXMT"] = renderer.appendingPathComponent("dxmt/wine").path
            env["DXMT_CONFIG"] = dxmtCorrectness
            if options.metalFXUpscaling { env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1" }
        case .dxvk:
            // DXVK 3 needs Vulkan features MoltenVK lacks (shaderCullDistance); 1.10 runs on MoltenVK.
            let build = options.vulkanDriver == .kosmicKrisp ? "dxvk3" : "dxvk"
            env["WINEDLLPATH_DXVK"] = renderer.appendingPathComponent("\(build)/wine").path
            if options.asyncShaders { env["DXVK_ASYNC"] = "1" }
            env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        case .vulkan, .wined3d:
            // Vulkan games must not see the DirectX translators: their dxgi/nvapi crash DOOM Eternal.
            break
        }
        return env
    }

    /// DXMT's own fixes for broken pixels: NaN texture coordinates sample as 0 instead of garbage,
    /// and fused multiply-add is split so depth and colour passes compute identical positions
    /// (both documented in DXMT's dxmt.conf, off there by default).
    static let dxmtCorrectness = "d3d11.sampleNaNToZero=True;d3d11.defuseFma=True;"
}
