import CoreGraphics
import Foundation

/// Known fixes per Steam app, applied when the player has not chosen own settings for that game.
/// Each entry is measured on Kelter's engine, not copied from a forum.
enum GameFixes {
    struct Fix {
        let note: String
        let options: (inout GameOptions) -> Void
        /// Runs before every start, for example to skip a launcher that cannot draw under Wine.
        let prepare: (InstalledGame) -> Void
        /// Started directly (with Steam running in the background) instead of through Steam's
        /// launch entry, for games whose own launcher does not work under Wine.
        var directExecutable: String? = nil
        /// Start options the game always gets, in front of the player's own (theirs win on conflicts).
        /// Built at every start, so they can follow the current screen size.
        var arguments: () -> [String] = { [] }
        /// Extra environment for the game process (only with `directExecutable`).
        var environment: [String: String] = [:]
    }

    static let all: [String: Fix] = [
        // DOOM Eternal: Vulkan only. Needs Kelter's MoltenVK build (subgroups in vertex stages,
        // geometryShader and friends reported, MoltenVK issue #2818). Its own full screen makes Wine
        // switch the display mode and hangs, so it runs as a borderless window over the whole screen.
        // Its Electron launcher stays white under Wine.
        "782330": Fix(
            note: "Vulkan über Kelters MoltenVK-Anpassung, randloses Vollbild, FPS unbegrenzt, startet ohne den Electron-Launcher und ohne Intro-Videos.",
            options: { options in
                options.graphics = .vulkan
                options.vulkanDriver = .moltenVKGames
            },
            prepare: { game in
                setJSONValue(file: game.installDirectory.appendingPathComponent("doom-launcher-settings.json"),
                             key: "launch_target", value: "retail")
            },
            directExecutable: "DOOMEternalx64vk.exe",
            // r_fullscreen 1 makes Wine switch the Mac's display mode, after which DOOM hangs; 2 is a
            // borderless window, sized here to the main screen (measured 14.11.2026: 129 instead of
            // 120 FPS in the 1504x823 window). com_adaptiveTickMaxHz caps the frame rate (250 by
            // default; 1000 is the engine's maximum).
            arguments: { borderlessFullScreen() + ["+com_adaptiveTickMaxHz", "1000", "+com_skipIntroVideo", "1"] },
            // MoltenVK encodes queue submissions on its own thread instead of DOOM's render thread:
            // 120 instead of 106 FPS at the same spot (14.11.2026). Prefilling command buffers gave nothing.
            environment: ["MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS": "0"]
        ),
    ]

    /// id Tech start options for a borderless window covering the main screen. Wine's desktop uses
    /// the Mac's points (Retina off), which is what CGDisplayBounds reports.
    static func borderlessFullScreen() -> [String] {
        let size = CGDisplayBounds(CGMainDisplayID()).size
        guard size.width > 0, size.height > 0 else { return ["+r_fullscreen", "0"] }
        return ["+r_fullscreen", "2", "+r_windowPosX", "0", "+r_windowPosY", "0",
                "+r_windowWidth", String(Int(size.width)), "+r_windowHeight", String(Int(size.height))]
    }

    static func options(for appID: String, base: GameOptions) -> GameOptions {
        var options = base
        all[appID]?.options(&options)
        return options
    }

    /// Replaces `"key": "…"` in a small JSON settings file without touching anything else.
    static func setJSONValue(file: URL, key: String, value: String) {
        guard var text = try? String(contentsOf: file, encoding: .utf8),
              let range = text.range(of: "\"\(key)\"\\s*:\\s*\"[^\"]*\"", options: .regularExpression) else { return }
        let replacement = "\"\(key)\": \"\(value)\""
        guard text[range] != replacement else { return }
        text.replaceSubrange(range, with: replacement)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }
}
