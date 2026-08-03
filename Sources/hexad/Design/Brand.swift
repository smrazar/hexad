import AppKit

/// hexad's own mark, drawn from the app artwork rather than borrowed from SF Symbols.
///
/// One loader rather than one per call site, so the menu bar and the onboarding screen cannot drift
/// onto different artwork. The bundled resource is generated from `Assets/hexad-glyph.svg` at build
/// time by `Scripts/make-glyph.swift`.
enum Brand {

    /// The mark as a **template** image: one colour, its shape carried by alpha, so macOS inverts
    /// it for a light or dark menu bar and tints it wherever else it is drawn. PDF rather than PNG
    /// because the menu bar height varies with the display and a vector never softens.
    ///
    /// Falls back to a system hexagon if the resource is somehow missing — an invisible status item
    /// is indistinguishable from a crashed app, and a `--self-check` run has no bundle at all.
    static func mark(height: CGFloat) -> NSImage? {
        let image: NSImage?
        if let url = Bundle.main.url(forResource: "MenuGlyph", withExtension: "pdf") {
            image = NSImage(contentsOf: url)
        } else {
            image = NSImage(systemSymbolName: "hexagon", accessibilityDescription: "hexad")
        }

        // Sized here rather than by the caller's frame, so the aspect stays the artwork's instead
        // of AppKit squaring it off. The glyph is taller than it is wide.
        guard let image, image.size.height > 0 else { return image }
        image.size = NSSize(width: height * (image.size.width / image.size.height), height: height)
        image.isTemplate = true
        image.accessibilityDescription = "hexad"
        return image
    }
}
