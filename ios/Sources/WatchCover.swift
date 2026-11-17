import SwiftUI

/// The one picture a watch or a wishlist candidate is shown by, on a card, a tile, a chip, a list row or the top of
/// its page: its rendered tile (the watch upright on its pillow) when that file is on this device, else its first
/// photo in its saved framing. Owned, archived and wishlist watches all follow the same rule.
struct WatchCover: Hashable {
    var itemID: String
    var wishlist: Bool
    var filename: String
    /// A rendered tile, not one of the item's photos. A render frames itself (`RenderLayout`).
    var isRender: Bool
    /// A photo's saved framing. Nil for a render.
    var focus: PhotoFocus?

    /// The finish every cover is drawn in. The black box is the default box, and its near-black leather is the
    /// quieter ground on a white page.
    static let finish = "black"

    /// The render when the item has one in `finish`, its file is on this device and the cutout was not chosen over
    /// it (the same refusal the box honours); else the first photo; else nothing.
    static func choose(
        itemID: String,
        wishlist: Bool,
        photos: [String],
        photoFocus: [String: PhotoFocus]?,
        boxTiles: [String: String]?,
        cutout: BoxCutout?,
        hasTile: (String) -> Bool
    ) -> WatchCover? {
        let refused = BoxModel.effectiveCutout(cutout, photos: photos)?.useCutout == true
        if !refused, let file = boxTiles?[finish], hasTile(file) {
            return WatchCover(itemID: itemID, wishlist: wishlist, filename: file, isRender: true, focus: nil)
        }
        guard let photo = photos.first else { return nil }
        return WatchCover(itemID: itemID, wishlist: wishlist, filename: photo, isRender: false, focus: photoFocus?[photo])
    }

    /// The same, checking the tile's file in `PhotoStore`.
    static func choose(
        itemID: String,
        wishlist: Bool,
        photos: [String],
        photoFocus: [String: PhotoFocus]?,
        boxTiles: [String: String]?,
        cutout: BoxCutout?
    ) -> WatchCover? {
        choose(itemID: itemID, wishlist: wishlist, photos: photos, photoFocus: photoFocus, boxTiles: boxTiles, cutout: cutout) { file in
            PhotoStore.asset(itemID: itemID, filename: file, wishlist: wishlist, baseURL: nil)
                .flatMap(PhotoStore.existingLocalURL) != nil
        }
    }

    var asset: PhotoAsset? {
        PhotoStore.asset(itemID: itemID, filename: filename, wishlist: wishlist, baseURL: nil)
    }
}

extension Watch {
    var cover: WatchCover? {
        WatchCover.choose(itemID: id, wishlist: false, photos: photos, photoFocus: photoFocus, boxTiles: boxTiles, cutout: boxCutout)
    }
}

extension WishlistItem {
    var cover: WatchCover? {
        WatchCover.choose(itemID: id, wishlist: true, photos: photos, photoFocus: photoFocus, boxTiles: boxTiles, cutout: boxCutout)
    }
}

extension BoxPiece {
    var cover: WatchCover? {
        WatchCover.choose(itemID: itemID, wishlist: wishlist, photos: photos, photoFocus: focus, boxTiles: boxTiles, cutout: boxCutout)
    }
}

/// The pictures a watch's page swipes through: its render first when it has one, then its photos. The photo actions
/// (frame, set cover, delete) only ever act on a photo.
struct CoverPages: Equatable {
    var render: WatchCover?
    var photos: [String]

    init(cover: WatchCover?, photos: [String]) {
        render = cover?.isRender == true ? cover : nil
        self.photos = photos
    }

    var count: Int { photos.count + (render == nil ? 0 : 1) }
    var isEmpty: Bool { count == 0 }

    /// Whether this page is the render.
    func isRender(_ page: Int) -> Bool { render != nil && page == 0 }

    /// The page of the first photo: right after the render when there is one.
    var firstPhotoPage: Int { render == nil ? 0 : 1 }

    /// The photo on this page, or nil on the render's page and outside the pages.
    func photo(_ page: Int) -> String? {
        let index = page - (render == nil ? 0 : 1)
        return photos.indices.contains(index) ? photos[index] : nil
    }
}

/// How a rendered tile sits in a frame of any shape: centred and whole, so the strap or bracelet shows from the top
/// of the pillow to the bottom. A frame in the tile's own shape (`PhotoShape.plate`) is filled exactly; in any other
/// shape the tile falls short of two edges, and `RenderImage` fades it into a dark ground there.
struct RenderLayout: Equatable {
    /// The tile's drawn size. It is centred in the frame.
    let size: CGSize
    /// Whether the tile reaches every edge of the frame.
    let coversFrame: Bool

    init(imageSize: CGSize, frame: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0, frame.width > 0, frame.height > 0 else {
            size = frame
            coversFrame = true
            return
        }
        let scale = min(frame.width / imageSize.width, frame.height / imageSize.height)
        size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        // Half a point of slack, so rounding never calls a filled frame bare.
        coversFrame = size.width >= frame.width - 0.5 && size.height >= frame.height - 0.5
    }
}

/// A rendered tile drawn by `RenderLayout`. Where the tile leaves part of the frame bare, its edges fade into a
/// ground the colour of the leather around the pillow, so the watch sits in the dark instead of in a pasted box.
struct RenderImage: View {
    let image: UIImage

    var body: some View {
        GeometryReader { geo in
            let layout = RenderLayout(imageSize: image.size, frame: geo.size)
            ZStack {
                WatchTheme.renderGround
                tile(layout, frame: geo.size)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func tile(_ layout: RenderLayout, frame: CGSize) -> some View {
        let picture = Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: layout.size.width, height: layout.size.height)
        if layout.coversFrame {
            // The usual case, and the one in every scrolling grid: no mask, nothing drawn off screen.
            picture
        } else {
            picture
                .mask {
                    Self.fade(.horizontal, on: layout.size.width < frame.width)
                }
                .mask {
                    Self.fade(.vertical, on: layout.size.height < frame.height)
                }
        }
    }

    /// Opaque across the middle, clear at both ends of the axis the tile falls short on.
    private static func fade(_ axis: Axis, on: Bool) -> some View {
        let edge = on ? 0.07 : 0
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(on ? 0 : 1), location: 0),
                .init(color: .black, location: edge),
                .init(color: .black, location: 1 - edge),
                .init(color: .black.opacity(on ? 0 : 1), location: 1),
            ],
            startPoint: axis == .horizontal ? .leading : .top,
            endPoint: axis == .horizontal ? .trailing : .bottom
        )
    }
}
