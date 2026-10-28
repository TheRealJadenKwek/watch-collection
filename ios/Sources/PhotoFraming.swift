import SwiftUI
import UIKit

/// Geometry for drawing an image aspect-filled into a frame, centred on a PhotoFocus.
/// The focus is clamped so the image always covers the frame (no empty edges).
struct FocusLayout {
    let size: CGSize
    let center: CGPoint
    let focus: PhotoFocus

    init(imageSize: CGSize, frame: CGSize, focus requested: PhotoFocus) {
        guard imageSize.width > 0, imageSize.height > 0, frame.width > 0, frame.height > 0 else {
            size = frame
            center = CGPoint(x: frame.width / 2, y: frame.height / 2)
            focus = .centered
            return
        }
        let zoom = min(max(requested.zoom.isFinite ? requested.zoom : 1, 1), PhotoFocus.maximumZoom)
        let scale = max(frame.width / imageSize.width, frame.height / imageSize.height) * zoom
        let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        func clamp(_ value: Double, frameLength: CGFloat, drawnLength: CGFloat) -> Double {
            let margin = Double(frameLength / (2 * drawnLength))
            let safe = value.isFinite ? value : 0.5
            return min(max(safe, margin), 1 - margin)
        }
        let x = clamp(requested.x, frameLength: frame.width, drawnLength: drawn.width)
        let y = clamp(requested.y, frameLength: frame.height, drawnLength: drawn.height)
        size = drawn
        // Place image point (x, y) at the frame centre.
        center = CGPoint(
            x: frame.width / 2 + drawn.width * (0.5 - x),
            y: frame.height / 2 + drawn.height * (0.5 - y)
        )
        focus = PhotoFocus(x: x, y: y, zoom: zoom)
    }
}

struct FocusedImage: View {
    let image: UIImage
    let focus: PhotoFocus?

    var body: some View {
        GeometryReader { geo in
            let layout = FocusLayout(imageSize: image.size, frame: geo.size, focus: focus ?? .centered)
            Image(uiImage: image)
                .resizable()
                .frame(width: layout.size.width, height: layout.size.height)
                .position(layout.center)
        }
        .clipped()
    }
}

struct PhotoFramingTarget: Identifiable {
    let filename: String
    var id: String { filename }
}

/// Drag to reposition and pinch to zoom a photo inside its card frame, with live
/// previews of the other shapes the same photo appears in.
struct PhotoFramingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let asset: PhotoAsset?
    let allowsRemoteFetch: Bool
    /// Width / height of the main editing frame (the card the cover appears on).
    let aspect: CGFloat
    let previews: [(label: String, aspect: CGFloat)]
    let onSave: (PhotoFocus?) async -> Void

    @State private var image: UIImage?
    @State private var focus: PhotoFocus
    @State private var gestureStart: PhotoFocus?
    @State private var isSaving = false

    init(
        asset: PhotoAsset?,
        allowsRemoteFetch: Bool,
        initialFocus: PhotoFocus?,
        aspect: CGFloat,
        previews: [(label: String, aspect: CGFloat)],
        onSave: @escaping (PhotoFocus?) async -> Void
    ) {
        self.asset = asset
        self.allowsRemoteFetch = allowsRemoteFetch
        self.aspect = aspect
        self.previews = previews
        self.onSave = onSave
        _focus = State(initialValue: initialFocus ?? .centered)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 18) {
                    editor
                    Text("Drag to reposition. Pinch to zoom. Double-tap to reset.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                    if let image, !previews.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ALSO APPEARS AS")
                                .font(.caption2.weight(.bold))
                                .tracking(1.2)
                                .foregroundStyle(Color.secondary)
                            HStack(alignment: .bottom, spacing: 12) {
                                ForEach(previews.indices, id: \.self) { index in
                                    VStack(spacing: 6) {
                                        FocusedImage(image: image, focus: focus)
                                            .frame(width: 88 * min(previews[index].aspect, 1.6), height: 88)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        Text(previews[index].label)
                                            .font(.caption2)
                                            .foregroundStyle(Color.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Reset to centre") { focus = .centered }
                        .disabled(focus == .centered || image == nil)
                }
                .padding(16)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WatchTheme.background)
            .navigationTitle("Frame Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        isSaving = true
                        Task {
                            await onSave(isCentered(focus) ? nil : focus)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(image == nil || isSaving)
                }
            }
            .task {
                guard let asset else { return }
                if let data = await PhotoStore.shared.load(asset, allowDownload: allowsRemoteFetch) {
                    image = UIImage(data: data)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var editor: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    FocusedImage(image: image, focus: focus)
                        .allowsHitTesting(false)
                    if gestureStart != nil { ThirdsGrid().allowsHitTesting(false) }
                } else {
                    WatchPlaceholder()
                    ProgressView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            // Gestures live on the fixed frame, not the scaled image, so the hit area
            // never depends on zoom or where the oversized image is positioned.
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { focus = .centered } }
            .gesture(framingGesture(frame: geo.size))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    private func framingGesture(frame: CGSize) -> some Gesture {
        SimultaneousGesture(DragGesture(minimumDistance: 2), MagnifyGesture())
            .onChanged { value in
                guard let image else { return }
                let start = gestureStart ?? focus
                if gestureStart == nil { gestureStart = start }
                let zoom = start.zoom * Double(value.second?.magnification ?? 1)
                let probe = FocusLayout(
                    imageSize: image.size,
                    frame: frame,
                    focus: PhotoFocus(x: start.x, y: start.y, zoom: zoom)
                )
                let translation = value.first?.translation ?? .zero
                // Dragging the photo right reveals more of its left side, so the centred point moves left.
                let requested = PhotoFocus(
                    x: start.x - Double(translation.width / probe.size.width),
                    y: start.y - Double(translation.height / probe.size.height),
                    zoom: zoom
                )
                focus = FocusLayout(imageSize: image.size, frame: frame, focus: requested).focus
            }
            .onEnded { _ in gestureStart = nil }
    }

    private func isCentered(_ value: PhotoFocus) -> Bool {
        abs(value.x - 0.5) < 0.001 && abs(value.y - 0.5) < 0.001 && abs(value.zoom - 1) < 0.001
    }
}

private struct ThirdsGrid: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: geo.size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: geo.size.width * fraction, y: geo.size.height))
                    path.move(to: CGPoint(x: 0, y: geo.size.height * fraction))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * fraction))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
    }
}

extension Watch {
    func focus(for filename: String?) -> PhotoFocus? { filename.flatMap { photoFocus?[$0] } }
}

extension WishlistItem {
    func focus(for filename: String?) -> PhotoFocus? { filename.flatMap { photoFocus?[$0] } }
}
