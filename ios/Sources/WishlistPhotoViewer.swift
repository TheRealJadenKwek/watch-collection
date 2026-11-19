import SwiftUI

extension WishlistItem {
    /// Whether the candidate has a render or a photo to show.
    var hasPictures: Bool { !CoverPages(cover: cover, photos: photos).isEmpty }
}

/// A candidate's pictures, large: its render first (the picture its card shows), then its photos, each whole. Opened
/// by clicking a wishlist card's picture. On the Mac the arrows, or the arrow keys, step through them.
struct WishlistPhotoViewer: View {
    @ObservedObject var store: AppStore
    /// The candidate as it was opened; what shows is its latest copy (`live`), so a sync's changes come in.
    let opened: WishlistItem
    @State private var page = 0
    @Environment(\.dismiss) private var dismiss

    private var live: WishlistItem? { store.data?.wishlist.first { $0.id == opened.id } }
    private var item: WishlistItem { live ?? opened }
    /// Desktop size on the Mac's large window; the phone's own page size there.
    private var maxPixel: Int { Platform.isMac ? DisplayImageCache.full : DisplayImageCache.page }

    var body: some View {
        let pages = CoverPages(cover: item.cover, photos: item.photos)
        VStack(spacing: 0) {
            header
            ZStack {
                WatchTheme.card
                if pages.isEmpty {
                    WatchPlaceholder()
                } else {
                    PhotoPager(selection: $page, count: pages.count) { index in
                        picture(index, of: pages)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    #if os(iOS)
                    // Whole photos leave light ground under the dots: give them their backing so they show.
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                    #endif
                    // A sync that takes pictures away keeps the page in range.
                    .onChange(of: pages.count) { _, count in page = min(page, max(count - 1, 0)) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WatchTheme.raised)
        .desktopSheet(width: 900, height: 720)
        .onChange(of: live == nil) { _, removed in
            // Deleted here or by a sync: close.
            if removed { dismiss() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if !item.brand.isEmpty { Eyebrow(item.brand) }
                Text(item.name)
                    .font(AtelierType.cardTitle)
                    .foregroundStyle(WatchTheme.ink)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .quietButton()
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, WatchTheme.panelPadding)
        .padding(.vertical, 14)
    }

    /// One page: the render, or a photo shown whole.
    @ViewBuilder
    private func picture(_ index: Int, of pages: CoverPages) -> some View {
        if pages.isRender(index) {
            RemoteWatchImage(cover: pages.render, allowsRemoteFetch: !store.isOffline, maxPixel: maxPixel)
        } else if let filename = pages.photo(index) {
            RemoteWatchImage(
                asset: store.photoAsset(itemID: item.id, filename: filename, wishlist: true),
                allowsRemoteFetch: !store.isOffline,
                fitWholePhoto: true,
                maxPixel: maxPixel
            )
        }
    }
}
