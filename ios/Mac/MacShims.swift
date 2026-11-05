import AppKit
import SwiftUI

// The app's screens are shared with iOS. These let that code compile unchanged on the Mac;
// anything that needs a genuinely different desktop treatment is branched with Platform.isMac.
typealias UIImage = NSImage

extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

extension NSColor {
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemGroupedBackground: NSColor { .controlBackgroundColor }
    static var tertiarySystemGroupedBackground: NSColor { .underPageBackgroundColor }
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var tertiarySystemFill: NSColor { .quaternaryLabelColor }
    static var separator: NSColor { .separatorColor }
    static var systemGray5: NSColor { .quaternaryLabelColor }
    static var systemGray6: NSColor { .quaternaryLabelColor }
}

extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}

enum MacTitleDisplayMode { case automatic, inline, large }
enum MacKeyboardType { case URL, decimalPad, numberPad, default_ }
enum MacCapitalization { case never, words, sentences, characters }

extension View {
    func navigationBarTitleDisplayMode(_ mode: MacTitleDisplayMode) -> some View { self }
    func keyboardType(_ type: MacKeyboardType) -> some View { self }
    func textInputAutocapitalization(_ value: MacCapitalization?) -> some View { self }
}

extension Color {
    init(_ color: NSColor) { self.init(nsColor: color) }
}
