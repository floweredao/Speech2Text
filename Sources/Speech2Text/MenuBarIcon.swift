import AppKit

/// Menu bar glyph: the voice waveform from the app icon, as the system symbol so it fills a square
/// status item like other menu bar extras and stays crisp and template-tinted in light and dark menu bars.
enum MenuBarIcon {
    static let pointSize: CGFloat = 15

    static var image: NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: String(localized: "말글"))?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = true
        return image
    }
}
