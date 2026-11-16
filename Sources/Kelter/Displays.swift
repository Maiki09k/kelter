import AppKit
import CoreGraphics

/// A resolution in real pixels, as offered in the game settings ("2560x1440").
struct DisplayResolution: Hashable, Comparable, Sendable {
    let width: Int
    let height: Int

    var tag: String { "\(width)x\(height)" }
    var title: String { "\(width) × \(height)" }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init?(tag: String) {
        let parts = tag.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        self.init(width: parts[0], height: parts[1])
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.width * lhs.height < rhs.width * rhs.height }
}

/// A connected Mac display, for the settings picker.
struct GameDisplay: Identifiable, Hashable, Sendable {
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    let isMain: Bool
    /// What the Mac uses right now, in points. Wine (Retina mode off) sees exactly this.
    let current: DisplayResolution
    /// Pixel-exact modes, largest first; the first one is the panel's full resolution.
    let resolutions: [DisplayResolution]
}

/// Choosing the screen and resolution a game runs on. Windows games open on the primary monitor,
/// which Wine maps to the Mac's main display (the one with the menu bar), so Kelter makes the chosen
/// display the main one while the game runs. A resolution other than "macos" switches that display
/// to a pixel-exact (1x) mode: Wine then sees every real pixel, without its Retina mode.
enum Displays {
    static let automatic = "auto"
    static let builtIn = "builtin"
    static let macOSResolution = "macos"
    static let nativeResolution = "native"

    /// Drawable displays, without those that only mirror another one.
    static func active() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [CGMainDisplayID()] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [CGMainDisplayID()] }
        return ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    /// Stays the same when the monitor is unplugged and plugged in again.
    static func key(_ id: CGDirectDisplayID) -> String {
        if CGDisplayIsBuiltin(id) != 0 { return builtIn }
        return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    /// "auto" prefers an external display (the main one if several), then the built-in one.
    /// A saved display that is not connected falls back to "auto".
    static func resolve(_ target: String) -> CGDirectDisplayID {
        let ids = active()
        let main = CGMainDisplayID()
        if target != automatic, let match = ids.first(where: { key($0) == target }) { return match }
        let external = ids.filter { CGDisplayIsBuiltin($0) == 0 }
        return external.first(where: { $0 == main }) ?? external.first ?? ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? main
    }

    static func current(_ id: CGDirectDisplayID) -> DisplayResolution {
        let size = CGDisplayBounds(id).size
        return DisplayResolution(width: Int(size.width), height: Int(size.height))
    }

    /// One pixel-exact mode per size (the one with the highest refresh rate), largest first.
    static func modes(_ id: CGDirectDisplayID) -> [(DisplayResolution, CGDisplayMode)] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        var best: [DisplayResolution: CGDisplayMode] = [:]
        for mode in all where mode.isUsableForDesktopGUI() && mode.width == mode.pixelWidth && mode.width >= 1024 {
            let size = DisplayResolution(width: mode.pixelWidth, height: mode.pixelHeight)
            if let known = best[size], known.refreshRate >= mode.refreshRate { continue }
            best[size] = mode
        }
        return best.sorted { $0.key > $1.key }
    }

    /// The pixel-exact resolution a setting asks for on this display; nil keeps the Mac's mode.
    static func resolution(for setting: String, on id: CGDirectDisplayID) -> DisplayResolution? {
        let available = modes(id).map(\.0)
        switch setting {
        case macOSResolution: return nil
        case nativeResolution: return available.first
        default:
            guard let wanted = DisplayResolution(tag: setting) else { return nil }
            return available.contains(wanted) ? wanted : available.first
        }
    }

    /// Main thread only (NSScreen gives the names).
    @MainActor
    static func list() -> [GameDisplay] {
        let main = CGMainDisplayID()
        var unnamed = 0
        return active().map { id in
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let name: String
            if let screen { name = screen.localizedName } else if builtIn { name = "Eingebauter Bildschirm" } else {
                unnamed += 1
                name = "Bildschirm \(unnamed)"
            }
            return GameDisplay(id: key(id), displayID: id, name: name, isBuiltIn: builtIn, isMain: id == main,
                               current: current(id), resolutions: modes(id).map(\.0))
        }
        .sorted { lhs, rhs in lhs.isBuiltIn != rhs.isBuiltIn ? !lhs.isBuiltIn : lhs.name < rhs.name }
    }
}

/// Applies the display choice for one game and hands everything back afterwards. Changes are made
/// "for this app only": macOS also undoes them by itself when Kelter quits or crashes.
enum DisplaySwitcher {
    private static let lock = NSLock()
    private static var changed = false

    static var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return changed
    }

    /// Returns what was changed (for the log and the status line), nil when nothing had to change.
    @discardableResult
    static func apply(display target: String, resolution setting: String) -> String? {
        let id = Displays.resolve(target)
        let makeMain = id != CGMainDisplayID()
        var mode: CGDisplayMode?
        var wanted: DisplayResolution?
        if let resolution = Displays.resolution(for: setting, on: id) {
            let now = CGDisplayCopyDisplayMode(id)
            let alreadyThere = now.map { $0.width == $0.pixelWidth && $0.pixelWidth == resolution.width && $0.pixelHeight == resolution.height } ?? false
            if !alreadyThere {
                mode = Displays.modes(id).first(where: { $0.0 == resolution })?.1
                wanted = resolution
            }
        }
        guard makeMain || mode != nil else { return nil }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            KelterLog.write("Bildschirm: Umstellen nicht möglich (CGBeginDisplayConfiguration)")
            return nil
        }
        if makeMain {
            // The display at 0,0 is the main one; everything else keeps its place relative to it.
            let origin = CGDisplayBounds(id).origin
            for other in Displays.active() {
                let position = CGDisplayBounds(other).origin
                CGConfigureDisplayOrigin(config, other, Int32(position.x - origin.x), Int32(position.y - origin.y))
            }
        }
        if let mode { CGConfigureDisplayWithDisplayMode(config, id, mode, nil) }
        let result = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            KelterLog.write("Bildschirm: Umstellen abgelehnt (Code \(result.rawValue))")
            return nil
        }
        lock.lock(); changed = true; lock.unlock()
        var parts: [String] = []
        if makeMain { parts.append("Hauptbildschirm") }
        if let wanted { parts.append(wanted.title) }
        let text = "Bildschirm \(Displays.key(id)) umgestellt: " + parts.joined(separator: ", ")
        KelterLog.write(text)
        return text
    }

    /// Puts menu bar and resolutions back the way System Settings has them.
    static func restore() {
        lock.lock()
        let wasChanged = changed
        changed = false
        lock.unlock()
        guard wasChanged else { return }
        CGRestorePermanentDisplayConfiguration()
        KelterLog.write("Bildschirm zurückgestellt")
    }
}
