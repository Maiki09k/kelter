import Foundation

/// Builds the engine folder:
///
///     Engines/<id>/wine/                 Sikarugir Wine 11 (bin, lib, share)
///     Engines/<id>/Frameworks/           runtime libraries from the template
///     Engines/<id>/renderer/             d3dmetal, dxmt, dxvk3, d9vk …
///     Engines/<id>/Resources/vulkan/     MoltenVK ICD (points at ../../../Frameworks)
enum EngineInstaller {
    enum Stage: Equatable, Sendable {
        case downloading(file: String, fraction: Double)
        case unpacking
    }

    static var directory: URL { Paths.engines.appendingPathComponent(Catalog.engineID, isDirectory: true) }

    /// DXVK 1.10's d3d9.dll alone, so it can serve DirectX 9 next to D3DMetal and DXMT without
    /// taking over their d3d11/dxgi (DXVK 3's own d3d9 needs Vulkan features MoltenVK lacks).
    static let dx9OnlyRenderer = "dxvk-d3d9"

    /// Kelter's own MoltenVK build for id Tech games (shim/moltenvk-idtech.patch), shipped in the
    /// app bundle and placed next to the template's libraries with its own ICD file.
    static let gamesMoltenVKLibrary = "libMoltenVK-kelter.dylib"
    static let gamesMoltenVKICD = "kelter_moltenvk_icd.json"

    /// Files Kelter derives from the downloaded renderers. Also run on every start, so engines
    /// installed by an older Kelter get them without a reinstall.
    static func prepareRenderers(in engine: URL) throws {
        let fm = FileManager.default
        if let bundled = Paths.bundledResource(gamesMoltenVKLibrary),
           fm.fileExists(atPath: engine.appendingPathComponent("Resources/vulkan/icd.d").path) {
            let target = engine.appendingPathComponent("Frameworks/\(gamesMoltenVKLibrary)")
            if !SteamClient.sameFile(bundled, target) {
                try? fm.removeItem(at: target)
                try fm.copyItem(at: bundled, to: target)
            }
            let icd = engine.appendingPathComponent("Resources/vulkan/icd.d/\(gamesMoltenVKICD)")
            let json = """
            {
                "file_format_version" : "1.0.0",
                "ICD": {
                    "library_path": "../../../Frameworks/\(gamesMoltenVKLibrary)",
                    "api_version" : "1.4.0",
                    "is_portability_driver" : false
                }
            }

            """
            if (try? String(contentsOf: icd, encoding: .utf8)) != json {
                try json.write(to: icd, atomically: true, encoding: .utf8)
            }
        }
        for arch in ["x86_64-windows", "i386-windows"] {
            let source = engine.appendingPathComponent("renderer/dxvk/wine/\(arch)/d3d9.dll")
            let folder = engine.appendingPathComponent("renderer/\(dx9OnlyRenderer)/wine/\(arch)")
            let target = folder.appendingPathComponent("d3d9.dll")
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { continue }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
        }
    }
    static var marker: URL { directory.appendingPathComponent("kelter-engine.json") }

    /// Files the engine cannot run without; checked after unpacking and on every start.
    static let requiredFiles = [
        "wine/bin/wine",
        "wine/bin/wineserver",
        "Frameworks/libinotify.0.dylib",
        "Frameworks/libgnutls.30.dylib",
        "renderer/d3dmetal/external/libd3dshared.dylib",
        "renderer/d3dmetal/wine/x86_64-windows/d3d11.dll",
        "renderer/dxmt/wine/x86_64-unix/winemetal.so",
        "renderer/dxvk/wine/x86_64-windows/d3d11.dll",
        "renderer/dxvk3/wine/x86_64-windows/d3d11.dll",
        "renderer/dxvk/wine/x86_64-windows/d3d9.dll",
        "Resources/vulkan/icd.d/MoltenVK_icd.json",
    ]

    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: marker.path)
            && requiredFiles.allSatisfy { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    static func install(progress: @escaping @Sendable (Stage) -> Void) async throws {
        let fm = FileManager.default
        try Paths.ensure(Paths.engines)
        try Paths.ensure(Paths.logs)

        let files = Catalog.engineDownloads
        let total = Double(files.reduce(0) { $0 + $1.bytes })
        var finished: Int64 = 0
        for file in files {
            let before = Double(finished)
            try await Downloader.fetch(file) { fraction in
                progress(.downloading(file: file.fileName, fraction: (before + fraction * Double(file.bytes)) / total))
            }
            finished += file.bytes
        }

        progress(.unpacking)
        let staging = Paths.engines.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let wineDir = staging.appendingPathComponent("wine", isDirectory: true)
        try Paths.ensure(wineDir)

        let log = Paths.logs.appendingPathComponent("engine-install.log")
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        try await Shell.check(tar, ["-xf", Catalog.wine.localURL.path, "-C", wineDir.path, "--strip-components", "1"], log: log)

        let root = Catalog.templateRoot
        try await Shell.check(tar, [
            "-xf", Catalog.template.localURL.path, "-C", staging.path, "--strip-components", "2",
            "\(root)/Frameworks", "\(root)/SharedSupport/renderer", "\(root)/Resources/vulkan",
        ], log: log, appendLog: true)

        try fm.moveItem(at: staging.appendingPathComponent("SharedSupport/renderer"),
                        to: staging.appendingPathComponent("renderer"))
        try? fm.removeItem(at: staging.appendingPathComponent("SharedSupport"))
        // The template's own launcher library is not used by Kelter.
        try? fm.removeItem(at: staging.appendingPathComponent("Frameworks/SikarugirSdk.framework"))

        try await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", staging.path],
                            log: log, appendLog: true)
        try prepareRenderers(in: staging)

        for file in requiredFiles where !fm.fileExists(atPath: staging.appendingPathComponent(file).path) {
            throw KelterError.missing("Engine-Datei \(file)")
        }

        let info: [String: String] = [
            "id": Catalog.engineID,
            "wine": Catalog.wine.fileName,
            "template": Catalog.template.fileName,
            "installed": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: staging.appendingPathComponent("kelter-engine.json"))

        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.moveItem(at: staging, to: directory)
    }
}
