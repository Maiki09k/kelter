import Foundation

/// A Wine prefix on Kelter's engine. Kelter keeps one, "Steam".
struct Bottle: Sendable {
    static var steam: Bottle { Bottle(name: "Steam") }

    let name: String
    let root: URL

    init(name: String, root: URL = Paths.bottles) {
        self.name = name
        self.root = root
    }

    var prefix: URL { root.appendingPathComponent(name, isDirectory: true) }
    var driveC: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }
    var engine: URL { EngineInstaller.directory }
    var wine: URL { engine.appendingPathComponent("wine/bin/wine") }
    var wineserver: URL { engine.appendingPathComponent("wine/bin/wineserver") }
    var log: URL { Paths.logs.appendingPathComponent("\(name)-wine.log") }

    var exists: Bool { FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) }

    var baseEnvironment: [String: String] { LaunchEnvironment.base(engine: engine, prefix: prefix) }

    func create() async throws {
        try Paths.ensure(Paths.bottles)
        var env = baseEnvironment
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="  // no Mono or Gecko prompts; Steam needs neither
        try await Shell.check(wine, ["wineboot", "--init"], environment: env, log: log)
        try await Shell.run(wineserver, ["-w"], environment: env, log: log, appendLog: true)
        guard exists else { throw KelterError.message("Die Bottle wurde nicht angelegt. Details: \(log.path)") }
        try await installMonoSupport()
    }

    // MARK: .NET

    /// wine-mono's support package from the engine. It registers .NET 1.1 to 4.8 and XNA 4 the way
    /// Windows installers check for them. Without it, Steam runs Microsoft's .NET web installer before
    /// the first start of every .NET or XNA game (Terraria, for example), and that hangs under Wine.
    var monoSupportPackage: URL? {
        let mono = engine.appendingPathComponent("wine/share/wine/mono")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: mono.path))?
            .filter { $0.hasPrefix("wine-mono-") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending } ?? []
        guard let latest = versions.last else { return nil }
        let msi = mono.appendingPathComponent("\(latest)/support/winemono-support.msi")
        return FileManager.default.fileExists(atPath: msi.path) ? msi : nil
    }

    var hasMonoSupport: Bool {
        guard let text = try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8) else { return false }
        return text.contains(#"[Software\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full]"#)
    }

    /// Installs the support package once; only while nothing runs in the bottle.
    func installMonoSupport() async throws {
        guard let msi = monoSupportPackage, !hasMonoSupport, !isRunning else { return }
        KelterLog.write(".NET-Unterstützung (wine-mono) wird in die Bottle eingetragen")
        let windowsPath = "Z:" + msi.path.replacingOccurrences(of: "/", with: "\\")
        try await Shell.run(wine, ["msiexec", "/i", windowsPath, "/qn"], environment: baseEnvironment, log: log, appendLog: true)
        try await Shell.run(wineserver, ["-w"], environment: baseEnvironment, log: log, appendLog: true)
        KelterLog.write(hasMonoSupport ? ".NET-Unterstützung eingetragen" : ".NET-Unterstützung fehlt weiterhin, siehe \(log.path)")
    }

    /// The wineserver socket lives in /tmp/.wine-<uid>/server-<device>-<inode>/ while the bottle runs.
    var isRunning: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: prefix.path),
              let device = attributes[.systemNumber] as? Int,
              let inode = attributes[.systemFileNumber] as? Int else { return false }
        let socket = "/tmp/.wine-\(getuid())/server-\(String(device, radix: 16))-\(String(inode, radix: 16))/socket"
        guard FileManager.default.fileExists(atPath: socket) else { return false }
        // A crash can leave the socket behind, so also look for the server process itself.
        let processes = Shell.capture("/bin/ps", ["-axo", "args="])
        let server = engine.path
        return processes.split(separator: "\n").contains { $0.hasPrefix(server) && $0.contains("wineserver") }
    }

    /// Ends every Windows program in the bottle.
    func stop() async {
        _ = try? await Shell.run(wineserver, ["-k"], environment: baseEnvironment, log: log, appendLog: true)
        _ = await waitUntilStopped(seconds: 15)
    }

    func waitUntilStopped(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isRunning { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return !isRunning
    }

    /// Maps "C:\Program Files (x86)\Steam" or "D:\Games" to the Mac path, following dosdevices.
    func unixPath(forWindowsPath windowsPath: String) -> URL? {
        let cleaned = windowsPath.replacingOccurrences(of: "\\\\", with: "\\")
        guard cleaned.count >= 2, cleaned.dropFirst().first == ":", let drive = cleaned.first else { return nil }
        let device = prefix.appendingPathComponent("dosdevices/\(drive.lowercased()):")
        let root = device.resolvingSymlinksInPath()
        let rest = cleaned.dropFirst(2).split(separator: "\\").map(String.init)
        return rest.reduce(root) { $0.appendingPathComponent($1) }
    }
}
