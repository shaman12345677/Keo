import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoCodec {
    /// Uloží JPEG už ve správné poloze (bez EXIF orientation).
    /// Max. strana 1280 px drží inventurní export v rozumné velikosti i u stovky fotek.
    static func prepareInventoryJPEG(_ data: Data, maxSide: CGFloat = 1280, quality: CGFloat = 0.72) -> (full: Data, thumb: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let fullImage = thumbnail(from: source, maxSide: maxSide),
              let thumbImage = thumbnail(from: source, maxSide: 150) else { return nil }
        guard let full = jpegData(fullImage, quality: quality),
              let thumb = jpegData(thumbImage, quality: 0.7) else { return nil }
        return (full, thumb)
    }

    private static func thumbnail(from source: CGImageSource, maxSide: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxSide),
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
