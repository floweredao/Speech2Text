import AppKit
import Testing
@testable import Speech2Text

/// Small warning text in Settings must stay readable (WCAG 4.5:1) on the light backgrounds it sits on.
@MainActor @Suite struct SettingsColorTests {
    private func luminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB)!
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func warningTextKeepsContrastOnSettingsBackgrounds(_ name: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: name))
        appearance.performAsCurrentDrawingAppearance {
            for background in [NSColor.windowBackgroundColor, .controlBackgroundColor] {
                #expect(contrast(.warningText, background) >= 4.5, "\(name.rawValue) on \(background)")
            }
        }
    }
}
