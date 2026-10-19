import AppKit
import SwiftUI

/// A static, neutral texture over the system surface. Generated once, never animated.
struct SettingsBackground: View {
    var sidebar = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if sidebar && !reduceTransparency {
                Rectangle().fill(.regularMaterial)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
            if !reduceTransparency && contrast != .increased {
                Rectangle()
                    .fill(ImagePaint(image: Self.grain, scale: 0.5))
                    .blendMode(.softLight)
                    .opacity(colorScheme == .dark ? 0.16 : 0.09)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private static let grain: Image = {
        let side = 256
        var state: UInt64 = 0x4C696E676572
        var pixels = [UInt8](repeating: 0, count: side * side)
        for index in pixels.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            pixels[index] = UInt8(truncatingIfNeeded: state >> 32)
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8,
                                  bitsPerPixel: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return Image(nsImage: NSImage(size: .zero)) }
        return Image(decorative: image, scale: 1)
    }()
}
