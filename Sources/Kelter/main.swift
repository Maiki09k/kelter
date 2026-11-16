import AppKit
import SwiftUI

struct KelterApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Kelter") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 560)
                .tint(KelterApp.accent)
        }
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unified)
    }

    /// A calm wine red; the press that gave the app its name. The app icon always uses it.
    static let wine = Color(red: 0.55, green: 0.10, blue: 0.20)

    /// The wine red for controls. In dark mode a lighter shade, like macOS's own accent colours:
    /// the dark one is unreadable as text on dark backgrounds (borderless buttons, links).
    static let accent = Color(nsColor: NSColor(name: "KelterAccent") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.88, green: 0.36, blue: 0.44, alpha: 1)
            : NSColor(srgbRed: 0.55, green: 0.10, blue: 0.20, alpha: 1)
    })
}

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--cli") {
    let rest = Array(arguments[(index + 1)...])
    Task {
        let status = await CLI.run(rest)
        exit(status)
    }
    dispatchMain()
} else if let index = arguments.firstIndex(of: "--icon"), index + 1 < arguments.count {
    MainActor.assumeIsolated {
        IconRenderer.write(to: URL(fileURLWithPath: arguments[index + 1]))
    }
    exit(0)
} else {
    // Kelter keeps no window state worth restoring; without this, one crash makes macOS ask
    // "Kelter wurde unerwartet beendet" on every following start.
    UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    KelterApp.main()
}
