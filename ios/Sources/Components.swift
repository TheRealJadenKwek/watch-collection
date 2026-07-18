import SwiftUI
import UIKit

struct OfflineBanner: View {
    let message: String
    var onFixServer: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text(message)
                .font(.caption.weight(.semibold))
            Spacer()
            // Settings must stay reachable precisely when the Mac is not —
            // a wrong server URL can only be fixed from here.
            if let onFixServer {
                Button(action: onFixServer) {
                    Text("Fix server")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(WatchTheme.gold.opacity(0.18))
                        .foregroundStyle(WatchTheme.gold)
                        .clipShape(Capsule())
                }
            } else {
                Text("Read-only")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WatchTheme.gold)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(WatchTheme.raised)
    }
}

struct WatchPlaceholder: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [WatchTheme.raised, WatchTheme.card],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 4) {
                Image(systemName: "applewatch.watchface")
                    .font(.system(size: 34, weight: .thin))
                    .foregroundStyle(WatchTheme.gold.opacity(0.78))
                Text("NO PHOTO")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(WatchTheme.secondary.opacity(0.65))
            }
        }
    }
}

struct RemoteWatchImage: View {
    let asset: PhotoAsset?
    let allowsRemoteFetch: Bool
    @State private var image: UIImage?
    @State private var isLoading = false

    private var loadID: LoadID {
        LoadID(asset: asset, allowsRemoteFetch: allowsRemoteFetch)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                WatchPlaceholder()
            }
            if isLoading && image == nil {
                ProgressView().tint(WatchTheme.gold)
            }
        }
        .clipped()
        .task(id: loadID) {
            image = nil
            guard let asset else {
                isLoading = false
                return
            }
            isLoading = true
            let data = await PhotoStore.shared.load(asset, allowDownload: allowsRemoteFetch)
            if !Task.isCancelled, let data {
                image = UIImage(data: data)
            }
            isLoading = false
        }
    }

    private struct LoadID: Hashable {
        let asset: PhotoAsset?
        let allowsRemoteFetch: Bool
    }
}

struct CapsuleChip: View {
    let text: String
    var color: Color = WatchTheme.secondary
    var filled = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(filled ? WatchTheme.background : color)
            .background(filled ? color : color.opacity(0.12))
            .clipShape(Capsule())
            .overlay { Capsule().stroke(color.opacity(filled ? 0 : 0.25), lineWidth: 0.7) }
    }
}

struct FitChip: View {
    let info: FitInfo

    private var color: Color {
        switch info.key {
        case "perfect", "great": WatchTheme.gold
        case "sweet": WatchTheme.green
        default: WatchTheme.amber
        }
    }

    var body: some View {
        CapsuleChip(text: info.label, color: color)
            .accessibilityHint("Fit based on \(info.basis)")
    }
}

struct DialChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dialColor(name))
                .frame(width: 8, height: 8)
                .overlay { Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.5) }
            Text(name).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(WatchTheme.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(WatchTheme.secondary.opacity(0.1))
        .clipShape(Capsule())
    }
}

struct SectionCard<Content: View>: View {
    let eyebrow: String?
    let title: String
    @ViewBuilder let content: Content

    init(eyebrow: String? = nil, title: String, @ViewBuilder content: () -> Content) {
        self.eyebrow = eyebrow
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(WatchTheme.gold)
            }
            Text(title)
                .font(.title3.weight(.semibold))
                .serifTitle()
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .watchCard()
    }
}

struct EmptyCollectionView: View {
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: "applewatch",
            description: Text(detail)
        )
        .foregroundStyle(WatchTheme.secondary)
    }
}

struct GearToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .foregroundStyle(WatchTheme.gold)
        }
        .accessibilityLabel("Settings")
    }
}

struct RefreshableScreen<Content: View>: View {
    @ObservedObject var store: AppStore
    @ViewBuilder let content: Content

    init(store: AppStore, @ViewBuilder content: () -> Content) {
        self.store = store
        self.content = content()
    }

    var body: some View {
        content
            .refreshable { await store.refresh() }
            .overlay(alignment: .top) {
                if store.isRefreshing {
                    ProgressView()
                        .tint(WatchTheme.gold)
                        .padding(.top, 4)
                }
            }
    }
}

/// Left-aligned wrapping layout for chip rows, so cards keep one compact block
/// instead of one chip per line.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
