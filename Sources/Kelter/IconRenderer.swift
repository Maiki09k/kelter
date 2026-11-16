import AppKit
import SwiftUI

/// Draws the app icon (used by scripts/install.sh): a wine red tile with a bunch of grapes, the
/// fruit a Kelter (wine press) presses. Drawn from plain shapes; SF Symbols may not be used in
/// app icons under Apple's licence.
enum IconRenderer {
    @MainActor
    static func write(to url: URL) {
        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// Grape centres on the 1024 canvas: rows of 4, 3, 2 and 1, packed like a real bunch.
    static let grapes: [CGPoint] = {
        let spacing: CGFloat = 124, rowHeight: CGFloat = 107, top: CGFloat = 392
        return [4, 3, 2, 1].enumerated().flatMap { row, count in
            (0..<count).map { index in
                CGPoint(x: 512 + (CGFloat(index) - CGFloat(count - 1) / 2) * spacing,
                        y: top + CGFloat(row) * rowHeight)
            }
        }
    }()

    @MainActor
    static var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.62, green: 0.13, blue: 0.24), KelterApp.wine],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
            // Stem and leaf above the bunch.
            Capsule()
                .fill(.white)
                .frame(width: 24, height: 96)
                .rotationEffect(.degrees(14))
                .position(x: 500, y: 296)
            Ellipse()
                .fill(.white.opacity(0.82))
                .frame(width: 170, height: 74)
                .rotationEffect(.degrees(-24))
                .position(x: 598, y: 262)
            ForEach(Array(grapes.enumerated()), id: \.offset) { _, center in
                Circle()
                    .fill(.white)
                    .frame(width: 112, height: 112)
                    .position(center)
            }
        }
        .frame(width: 1024, height: 1024)
    }
}
