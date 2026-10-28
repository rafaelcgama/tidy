#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO

extension DecodedPhoto {
    /// Reads an image's size and a grayscale preview of at most 64 pixels a side, upright.
    /// The preview is made from the image itself, not an embedded thumbnail, so copies with and
    /// without one hash the same.
    @Sendable public static func imageIO(_ url: URL) -> DecodedPhoto? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // Orientations 5 to 8 are rotated a quarter turn, so width and height swap.
        let rotated = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let (w, h) = (thumbnail.width, thumbnail.height)
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn, let preview = GrayImage(width: w, height: h, pixels: pixels) else { return nil }
        return DecodedPhoto(preview: preview, pixelWidth: rotated ? height : width, pixelHeight: rotated ? width : height)
    }
}
#endif
