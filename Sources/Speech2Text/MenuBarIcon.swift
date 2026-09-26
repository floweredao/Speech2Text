import AppKit

/// Menu bar version of the app icon's glyph: a voice waveform followed by two lines of words.
/// Proportions come from Resources/AppIcon.png; word gaps are widened and every edge sits on a
/// whole point so the shapes stay separate and crisp at menu bar size on 1x and 2x displays.
enum MenuBarIcon {
    static let size = NSSize(width: 28, height: 16)

    static let waveform: [NSRect] = [
        NSRect(x: 0, y: 5, width: 2, height: 6),
        NSRect(x: 3, y: 3, width: 2, height: 10),
        NSRect(x: 6, y: 1, width: 2, height: 14),
        NSRect(x: 9, y: 4, width: 2, height: 8),
        NSRect(x: 12, y: 5, width: 2, height: 6)
    ]

    static let words: [NSRect] = [
        NSRect(x: 16, y: 9, width: 4, height: 2),
        NSRect(x: 21, y: 9, width: 2, height: 2),
        NSRect(x: 24, y: 9, width: 4, height: 2),
        NSRect(x: 16, y: 5, width: 6, height: 2),
        NSRect(x: 23, y: 5, width: 3, height: 2)
    ]

    static var image: NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            for rect in waveform + words {
                let radius = min(rect.width, rect.height) / 2
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Speech2Text"
        return image
    }
}
