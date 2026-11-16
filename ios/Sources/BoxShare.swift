import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// The two shared pictures (brief 8, Share): the box as it is on screen, top down, and the product view (5.8).
// Each is one view drawn whole by ImageRenderer, on the page background of the current colour scheme.

/// The top-down card: kicker, title, subtitle, the box front on with the lid as it is on screen, and a line
/// naming what is on trial and what stepped out for it.
struct BoxShareCard: View {
    var title: String
    var subtitle: String
    var geometry: BoxGeometry
    var finish: BoxFinish
    var lidClosed: Bool
    var slots: [Int: BoxSlotContent]
    var emptyTile: CGImage?
    var onTrial: [String] = []
    var steppingOut: [String] = []
    var dark = false

    private var ink: Color { Color(hex: dark ? 0xF4F4F4 : 0x212121) }
    private var muted: Color { Color(hex: dark ? 0xA0A0A0 : 0x767676) }

    var body: some View {
        VStack(spacing: 0) {
            Text("WATCH BOX")
                .font(.system(size: 10.5, weight: .regular).width(.expanded))
                .tracking(1.4)
                .foregroundStyle(muted)
            Text(title)
                .font(.system(size: 44, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(ink)
                .padding(.top, 6)
            Text(subtitle)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(muted)
                .padding(.top, 6)
            BoxSceneView(geometry: geometry, finish: finish, lidClosed: lidClosed, slots: slots,
                         emptyTile: emptyTile, outlined: dark)
                .padding(.top, 22)
            if let line = BoxShare.trialLine(onTrial: onTrial, steppingOut: steppingOut) {
                BoxTrialLine(text: line, color: muted)
                    .padding(.top, 26)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 34)
        .frame(width: 760)
        .background(Color(hex: dark ? 0x0E0E0E : 0xFFFFFF))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }
}

/// The line under a picture with a trial in it, after the trial's green.
struct BoxTrialLine: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(WatchTheme.Box.trial).frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
            Text(text)
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
    }
}

/// The product view card: the closed box from the front and above with its drawer, and the same trial line as the
/// top-down card.
struct BoxProductShareCard: View {
    var title: String
    var subtitle: String
    var geometry: BoxGeometry
    var finish: BoxFinish
    var slots: [Int: BoxSlotContent]
    var emptyTile: CGImage?
    var onTrial: [String] = []
    var steppingOut: [String] = []
    var dark = false

    var body: some View {
        VStack(spacing: 0) {
            Text("WATCH BOX")
                .font(.system(size: 10.5, weight: .regular).width(.expanded))
                .tracking(1.4)
                .foregroundStyle(Color(hex: dark ? 0xA0A0A0 : 0x767676))
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(Color(hex: dark ? 0xF4F4F4 : 0x212121))
                .padding(.top, 6)
            Text(subtitle)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Color(hex: dark ? 0xA0A0A0 : 0x767676))
                .padding(.top, 6)
            BoxProductView(geometry: geometry, finish: finish, slots: slots, emptyTile: emptyTile)
                .padding(.top, 26)
            if let line = BoxShare.trialLine(onTrial: onTrial, steppingOut: steppingOut) {
                BoxTrialLine(text: line, color: Color(hex: dark ? 0xA0A0A0 : 0x767676))
                    .padding(.top, 26)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 40)
        .frame(width: 402)
        .background(Color(hex: dark ? 0x0E0E0E : 0xFFFFFF))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// A shared picture, drawn only when it is shared (the PNG is made then, not on every redraw).
struct BoxSharePicture: Transferable {
    var name: String
    var render: @MainActor () -> CGImage?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { picture in
            SentTransferredFile(try await picture.file())
        }
        .suggestedFileName { $0.name + ".png" }
    }

    func file() async throws -> URL {
        let png = await MainActor.run { render().flatMap(BoxShare.png) }
        guard let png else { throw CocoaError(.fileWriteUnknown) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("box-pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + ".png")
        try png.write(to: url, options: .atomic)
        return url
    }
}

enum BoxShare {
    /// 3x on the phone, 2x on the Mac.
    static var scale: CGFloat { Platform.isMac ? 2 : 3 }

    @MainActor
    static func image<Content: View>(_ view: Content) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A box's count: "11 watches, 1 space open", "12 spaces open", or "Full". With candidates on trial in the
    /// picture, it counts what the picture shows: "11 watches, 1 on trial" when that fills it, "10 watches, 1 on
    /// trial, 1 space open" when not.
    static func counts(watches: Int, onTrial: Int = 0, capacity: Int) -> String {
        let open = max(0, capacity - watches - onTrial)
        let spaces = open == 1 ? "1 space open" : "\(open) spaces open"
        guard onTrial > 0 else {
            if open == 0 { return "Full" }
            if watches == 0 { return spaces }
            return (watches == 1 ? "1 watch, " : "\(watches) watches, ") + spaces
        }
        var parts: [String] = []
        if watches > 0 { parts.append(watches == 1 ? "1 watch" : "\(watches) watches") }
        parts.append("\(onTrial) on trial")
        if open > 0 { parts.append(spaces) }
        return parts.joined(separator: ", ")
    }

    /// "On trial: A and B." and, when owned watches made room for them, "C steps out to make room."; nil without a
    /// trial in the picture.
    static func trialLine(onTrial: [String], steppingOut: [String]) -> String? {
        guard !onTrial.isEmpty else { return nil }
        var line = "On trial: " + BoxShareCard.list(onTrial) + "."
        if !steppingOut.isEmpty {
            line += " " + BoxShareCard.list(steppingOut) + (steppingOut.count == 1 ? " steps" : " step") + " out to make room."
        }
        return line
    }

    /// "Black Box" to "black-box".
    static func fileName(_ title: String, _ suffix: String) -> String {
        let slug = title.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (slug.isEmpty ? "watch-box" : slug) + suffix
    }
}

/// The Share pill: the top-down picture and the product view, and on the Mac "Save Picture…" into Downloads.
struct BoxShareMenu: View {
    let store: AppStore
    var card: BoxShareCard
    var product: BoxProductShareCard

    var body: some View {
        Menu {
            ShareLink(item: picture(card, name: BoxShare.fileName(card.title, "")), preview: SharePreview(card.title)) {
                Label("Top-down picture", systemImage: "square.grid.3x2")
            }
            ShareLink(item: picture(product, name: BoxShare.fileName(product.title, "-product")), preview: SharePreview(product.title)) {
                Label("Product view", systemImage: "shippingbox")
            }
            #if os(macOS)
            Button("Save Picture…") { save() }
            #endif
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .menuIndicator(.hidden)
    }

    private func picture<Content: View>(_ view: Content, name: String) -> BoxSharePicture {
        let store = store
        return BoxSharePicture(name: name) {
            let image = BoxShare.image(view)
            if image == nil { store.notice = "Could not make the picture." }
            return image
        }
    }

    #if os(macOS)
    private func save() {
        guard let image = BoxShare.image(card), let png = BoxShare.png(image) else {
            store.notice = "Could not make the picture."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = BoxShare.fileName(card.title, "") + ".png"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            store.notice = "Could not make the picture."
        }
    }
    #endif
}
