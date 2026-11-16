import Foundation

/// A file Kelter downloads. `sha256` nil means the publisher changes it in place (Valve's installer).
struct RemoteFile: Hashable, Sendable {
    let url: URL
    let fileName: String
    let sha256: String?
    let bytes: Int64

    var localURL: URL { Paths.downloads.appendingPathComponent(fileName) }
}

/// How a game's Direct3D calls reach Metal. Every option ships with the engine;
/// the choice is only a set of environment variables at launch.
enum Graphics: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, d3dmetal, dxmt, dxvk, vulkan, wined3d

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatisch"
        case .d3dmetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        case .vulkan: "Vulkan direkt"
        case .wined3d: "WineD3D"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "D3DMetal für 64-Bit-Spiele mit DirectX 11 und 12, DXMT für 32-Bit-Spiele, DXVK über Vulkan für DirectX 9."
        case .d3dmetal: "Apples Übersetzer für DirectX 11 und 12, nur 64 Bit. 32-Bit- und DX9-Spiele fallen auf WineD3D zurück."
        case .dxmt: "DirectX 10 und 11 direkt auf Metal. Oft schneller bei älteren DX11-Spielen."
        case .dxvk: "DirectX 9 bis 11 über Vulkan (DXVK 1.10 mit MoltenVK). Ausweichweg, wenn beide oben haken."
        case .vulkan: "Für Spiele, die selbst Vulkan nutzen (zum Beispiel DOOM Eternal): ohne DirectX-Übersetzer, Grafik über den Vulkan-Treiber."
        case .wined3d: "Wines eigener Weg. Nur für sehr alte Spiele (DirectX 7 und älter)."
        }
    }
}

/// The engine Kelter runs everything on, assembled from two free packages:
/// Gcenx's Sikarugir Wine 11 build, and the Sikarugir wrapper template, which brings the runtime
/// libraries (GnuTLS, FreeType, MoltenVK, GStreamer) and the renderers (D3DMetal, DXMT, DXVK).
enum Catalog {
    static let engineID = "sikarugir-11.0_1+template-1.0.27"

    static let wine = RemoteFile(
        url: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir11.0_1.tar.xz")!,
        fileName: "WS12WineSikarugir11.0_1.tar.xz",
        sha256: "67e29fb3d74f363af39c69ba11f9b13a79812c5db07cf4748672658e4a200a0e",
        bytes: 167_322_744
    )

    static let template = RemoteFile(
        url: URL(string: "https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.27.tar.xz")!,
        fileName: "Template-1.0.27.tar.xz",
        sha256: "dd0778f7b553d63df9b0f4e2cda3f3c6c005aabb75588c84d604afe80cdedbb9",
        bytes: 96_161_660
    )

    /// Top folder inside the template archive; the parts Kelter needs sit below it.
    static let templateRoot = "Template-1.0.27.app/Contents"

    static let steamSetup = RemoteFile(
        url: URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!,
        fileName: "SteamSetup.exe",
        sha256: nil,
        bytes: 2_400_000
    )

    static var engineDownloads: [RemoteFile] { [wine, template] }
}
