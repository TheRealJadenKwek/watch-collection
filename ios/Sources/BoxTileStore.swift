import CoreGraphics
import Foundation
import ImageIO

/// Rendered box tiles, read from the files `PhotoStore` keeps (they download with the photos), decoded at the size
/// they are drawn and kept in memory. Nothing is written: a tile that is not on this device is simply not drawn and
/// the watch shows its cutout.
actor BoxTileStore {
    static let shared = BoxTileStore()

    private let memory: NSCache<NSString, TileBox> = {
        let cache = NSCache<NSString, TileBox>()
        cache.countLimit = 48
        return cache
    }()

    /// The tile at `maxPixel` on its long side, or nil when its file is not on this device.
    func tile(_ asset: PhotoAsset, maxPixel: Int) -> CGImage? {
        let key = "\(asset.directory)/\(asset.filename)@\(maxPixel)" as NSString
        if let hit = memory.object(forKey: key) { return hit.image }
        guard let url = PhotoStore.existingLocalURL(for: asset),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        memory.setObject(TileBox(image), forKey: key)
        return image
    }

    /// Twice the drawn compartment in pixels on its long side (the tile is 1536 px tall), in steps of 128 so a small
    /// change of layout does not decode every tile again.
    nonisolated static func pixelSize(compartmentPoints: CGFloat, scale: CGFloat) -> Int {
        let wanted = max(128, compartmentPoints * scale * 2)
        return min(1536, Int((wanted / 128).rounded(.up)) * 128)
    }
}

private final class TileBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
