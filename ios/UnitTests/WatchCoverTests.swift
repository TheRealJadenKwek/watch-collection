import XCTest
@testable import WatchCollection

/// Which picture a watch or a candidate is shown by, and how a render sits in a frame.
final class WatchCoverTests: XCTestCase {
    private let tiles = ["black": "box-black-11111111.jpg", "brown": "box-brown-22222222.jpg"]
    private let focus = PhotoFocus(x: 0.4, y: 0.6, zoom: 1.5)

    private func cover(
        wishlist: Bool = false, photos: [String] = ["a.jpg", "b.jpg"], tiles: [String: String]?,
        cutout: BoxCutout? = nil, onDevice: Set<String> = ["box-black-11111111.jpg", "box-brown-22222222.jpg"]
    ) -> WatchCover? {
        WatchCover.choose(itemID: "w", wishlist: wishlist, photos: photos, photoFocus: ["a.jpg": focus],
                          boxTiles: tiles, cutout: cutout) { onDevice.contains($0) }
    }

    func testTheRenderIsTheCoverWhenItsFileIsOnTheDevice() {
        let chosen = cover(tiles: tiles)
        XCTAssertEqual(chosen, WatchCover(itemID: "w", wishlist: false, filename: "box-black-11111111.jpg", isRender: true, focus: nil))
        XCTAssertEqual(chosen?.asset?.directory, "w")
    }

    func testAWishlistCandidateFollowsTheSameRuleInItsOwnFolder() {
        let chosen = cover(wishlist: true, tiles: tiles)
        XCTAssertEqual(chosen?.isRender, true)
        XCTAssertEqual(chosen?.asset?.directory, "wl-w")
        XCTAssertEqual(chosen?.asset?.filename, "box-black-11111111.jpg")
    }

    func testWithoutATileTheFirstPhotoIsTheCoverInItsSavedFraming() {
        let photo = WatchCover(itemID: "w", wishlist: false, filename: "a.jpg", isRender: false, focus: focus)
        XCTAssertEqual(cover(tiles: nil), photo)
        XCTAssertEqual(cover(tiles: [:]), photo)
        XCTAssertEqual(cover(tiles: ["brown": "box-brown-22222222.jpg"]), photo, "covers are drawn in one finish only")
    }

    /// The wishlist showed stock photos on a phone that had not downloaded its renders yet: a render not on this
    /// device is still the cover (the screen fetches it), with the first photo standing in only if it cannot be had.
    func testARenderNotDownloadedYetIsStillTheCoverWithThePhotoStandingIn() {
        let chosen = cover(wishlist: true, tiles: tiles, onDevice: [])
        XCTAssertEqual(chosen?.isRender, true)
        XCTAssertEqual(chosen?.asset?.directory, "wl-w")
        XCTAssertEqual(chosen?.asset?.filename, "box-black-11111111.jpg")
        XCTAssertEqual(chosen?.fallback, WatchCover(itemID: "w", wishlist: true, filename: "a.jpg", isRender: false, focus: focus))
        XCTAssertEqual(chosen?.fallback?.asset?.directory, "wl-w")
        XCTAssertEqual(chosen?.renderPending, true, "a box chip draws its cutout until the render is here")
        // On the device: nothing stands in, nothing pending.
        XCTAssertNil(cover(wishlist: true, tiles: tiles)?.fallback)
        XCTAssertEqual(cover(wishlist: true, tiles: tiles)?.renderPending, false)
        // No photo to stand in: the render alone, still pending.
        let bare = cover(photos: [], tiles: tiles, onDevice: [])
        XCTAssertEqual(bare?.isRender, true)
        XCTAssertNil(bare?.fallback)
        XCTAssertEqual(bare?.renderPending, true)
        // The watch's page: the render's page has no stand-in (the first photo is the next page), and its photos
        // follow as before.
        let pages = CoverPages(cover: chosen, photos: ["a.jpg", "b.jpg"])
        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(pages.isRender(0))
        XCTAssertNil(pages.render?.fallback)
        XCTAssertEqual(pages.render?.filename, "box-black-11111111.jpg")
        XCTAssertEqual(pages.photo(1), "a.jpg")
        // A refused render is never fetched: the photo is the cover.
        XCTAssertEqual(cover(tiles: tiles, cutout: BoxCutout(photo: "a.jpg", useCutout: true), onDevice: [])?.filename, "a.jpg")
        // A photo cover has no stand-in.
        XCTAssertNil(cover(tiles: nil)?.fallback)
    }

    func testARefusedRenderFallsBackToThePhoto() {
        let refused = BoxCutout(photo: "a.jpg", useCutout: true)
        XCTAssertEqual(cover(tiles: tiles, cutout: refused)?.filename, "a.jpg")
        // Settings whose photo has gone no longer apply, as in the box.
        XCTAssertEqual(cover(tiles: tiles, cutout: BoxCutout(photo: "gone.jpg", useCutout: true))?.isRender, true)
        // A hand-set ring does not refuse the render.
        XCTAssertEqual(cover(tiles: tiles, cutout: BoxCutout(photo: "a.jpg", x: 0.5, y: 0.5, r: 0.3))?.isRender, true)
    }

    /// A render a screen could not have is remembered for a while, so a row scrolling back draws its stand-in at
    /// once; loading it forgets the miss.
    func testARenderThatCouldNotBeHadIsRememberedForAWhile() {
        let key = PhotoKey(directory: "wl-misses", filename: "box-black-33333333.jpg")
        let now = Date()
        XCTAssertFalse(RenderMisses.recent(key, at: now))
        RenderMisses.note(key, at: now)
        XCTAssertTrue(RenderMisses.recent(key, at: now.addingTimeInterval(60)))
        XCTAssertFalse(RenderMisses.recent(key, at: now.addingTimeInterval(RenderMisses.span + 1)))
        RenderMisses.clear(key)
        XCTAssertFalse(RenderMisses.recent(key, at: now.addingTimeInterval(60)))
    }

    func testNoPhotosAndNoTileIsNoCover() {
        XCTAssertNil(cover(photos: [], tiles: nil))
        XCTAssertEqual(cover(photos: [], tiles: tiles)?.isRender, true, "a render needs no photo")
    }

    /// An owned watch and an archived one are told apart by nothing here: the model's own covers are the render
    /// (with the first photo standing in while it is not on this device), else the first photo.
    func testOwnedArchivedAndWishlistModelsAllHaveACover() {
        var owned = BoxFixture.watch("field", photos: ["a.jpg"])
        owned.boxTiles = ["black": "box-black-not-on-this-device.jpg"]
        let sold = BoxFixture.watch("sold-one", status: "sold", photos: ["b.jpg"])
        let wanted = BoxFixture.candidate("wanted", photos: ["c.jpg"])
        XCTAssertEqual(owned.cover, WatchCover(itemID: "field", wishlist: false, filename: "box-black-not-on-this-device.jpg",
                                               isRender: true, focus: nil, fallbackPhoto: "a.jpg", renderPending: true))
        XCTAssertEqual(owned.cover?.fallback, WatchCover(itemID: "field", wishlist: false, filename: "a.jpg", isRender: false, focus: nil))
        XCTAssertEqual(sold.cover?.filename, "b.jpg")
        XCTAssertEqual(wanted.cover, WatchCover(itemID: "wanted", wishlist: true, filename: "c.jpg", isRender: false, focus: nil))
        XCTAssertEqual(BoxPiece(watch: owned).cover, owned.cover)
        XCTAssertEqual(BoxPiece(candidate: wanted).cover, wanted.cover)
    }

    func testAPageOpensOnTheRenderThenItsPhotos() {
        let withRender = CoverPages(cover: cover(tiles: tiles), photos: ["a.jpg", "b.jpg"])
        XCTAssertEqual(withRender.count, 3)
        XCTAssertTrue(withRender.isRender(0))
        XCTAssertNil(withRender.photo(0), "nothing to frame or delete on the render's page")
        XCTAssertEqual(withRender.photo(1), "a.jpg")
        XCTAssertEqual(withRender.photo(2), "b.jpg")
        XCTAssertNil(withRender.photo(3))
        XCTAssertEqual(withRender.firstPhotoPage, 1, "Set cover lands on the new cover photo, not the render")
        XCTAssertEqual(withRender.photo(withRender.firstPhotoPage), "a.jpg")

        let photosOnly = CoverPages(cover: cover(tiles: nil), photos: ["a.jpg", "b.jpg"])
        XCTAssertEqual(photosOnly.count, 2)
        XCTAssertFalse(photosOnly.isRender(0))
        XCTAssertEqual(photosOnly.photo(0), "a.jpg")
        XCTAssertNil(photosOnly.photo(-1))
        XCTAssertEqual(photosOnly.firstPhotoPage, 0)

        XCTAssertEqual(CoverPages(cover: cover(photos: [], tiles: tiles), photos: []).count, 1)
        XCTAssertTrue(CoverPages(cover: nil, photos: []).isEmpty)
    }

    // MARK: How a render sits in a frame

    private let tile = CGSize(width: 1024, height: 1536)

    /// The part of the tile inside the frame, as fractions of its width and height.
    private func shown(_ frame: CGSize) -> (width: CGFloat, height: CGFloat, covers: Bool) {
        let layout = RenderLayout(imageSize: tile, frame: frame)
        XCTAssertEqual(layout.size.width / layout.size.height, tile.width / tile.height, accuracy: 0.0001, "never stretched")
        return (min(1, frame.width / layout.size.width), min(1, frame.height / layout.size.height), layout.coversFrame)
    }

    func testEveryFrameShowsTheWholeTileStrapToStrap() {
        // The wishlist row's thumbnail, a collection card, the feature, the watch page's hero, a chip, a grid cell,
        // and a wide and a very tall frame.
        for frame in [CGSize(width: 80, height: 120), CGSize(width: 208, height: 312), CGSize(width: 393, height: 491),
                      CGSize(width: 393, height: 504), CGSize(width: 64, height: 64), CGSize(width: 170, height: 170),
                      CGSize(width: 720, height: 380), CGSize(width: 350, height: 760)] {
            let part = shown(frame)
            XCTAssertEqual(part.width, 1, accuracy: 0.001, "\(frame)")
            XCTAssertEqual(part.height, 1, accuracy: 0.001, "\(frame)")
            // As large as it goes: it touches the frame on one axis.
            let layout = RenderLayout(imageSize: tile, frame: frame)
            XCTAssertTrue(abs(layout.size.width - frame.width) < 0.01 || abs(layout.size.height - frame.height) < 0.01, "\(frame)")
        }
    }

    func testOnlyACardInTheTilesOwnShapeIsFilled() {
        for width in [80.0, 208, 393] {
            let frame = CGSize(width: width, height: width / PhotoShape.plate)
            XCTAssertTrue(RenderLayout(imageSize: tile, frame: frame).coversFrame, "\(frame)")
        }
        // The wishlist card's thumbnail, 80 by 120, is in the tile's shape like every other card picture.
        XCTAssertEqual(WishlistCard.photoAspect, PhotoShape.plate)
        XCTAssertTrue(RenderLayout(imageSize: tile, frame: CGSize(width: 80, height: 120)).coversFrame)
        XCTAssertFalse(RenderLayout(imageSize: tile, frame: CGSize(width: 96, height: 120)).coversFrame, "the old 0.8 thumbnail")
        let wide = RenderLayout(imageSize: tile, frame: CGSize(width: 720, height: 380))
        XCTAssertFalse(wide.coversFrame)
        XCTAssertEqual(wide.size.height, 380, accuracy: 0.01)
        XCTAssertLessThan(wide.size.width, 720)

        let tall = RenderLayout(imageSize: tile, frame: CGSize(width: 350, height: 760))
        XCTAssertFalse(tall.coversFrame)
        XCTAssertEqual(tall.size.width, 350, accuracy: 0.01)
        XCTAssertLessThan(tall.size.height, 760)

        XCTAssertFalse(RenderLayout(imageSize: tile, frame: CGSize(width: 208, height: 260)).coversFrame, "the old 0.8 card")
    }

    func testAnEmptyFrameOrImageIsLeftAlone() {
        XCTAssertTrue(RenderLayout(imageSize: tile, frame: .zero).coversFrame)
        XCTAssertEqual(RenderLayout(imageSize: .zero, frame: CGSize(width: 10, height: 20)).size, CGSize(width: 10, height: 20))
    }
}
