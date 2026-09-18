import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Shrinks a photo before it goes into the store.
///
/// Not a nicety. A photo off a modern phone is 12 megapixels and 3–5 MB, and
/// a progress log is one or more of those a week for years. Kept at full size
/// they'd dominate the database, the backup and every iCloud sync, to display
/// something that is never shown larger than a phone screen.
///
/// Uses ImageIO's thumbnail path rather than decoding and redrawing, so a
/// 12-megapixel source is never fully decoded into memory.
enum ImageDownscaler {

    /// Longest edge of the stored image. Comfortably more than a 3x phone
    /// screen can show, so the full-size view stays sharp.
    static let maxDimension = 1_600
    /// Longest edge of the grid thumbnail.
    static let thumbnailDimension = 400
    static let jpegQuality = 0.82

    enum DownscaleError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file isn't an image this app can read."
            }
        }
    }

    struct Result: Sendable {
        let image: Data
        let thumbnail: Data
    }

    /// Produce the stored image and its thumbnail from arbitrary image data.
    static func prepare(_ data: Data) throws -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DownscaleError.unreadable
        }
        guard let image = try? downscale(source, to: maxDimension),
              let thumbnail = try? downscale(source, to: thumbnailDimension)
        else {
            throw DownscaleError.unreadable
        }
        return Result(image: image, thumbnail: thumbnail)
    }

    private static func downscale(_ source: CGImageSource, to maxPixels: Int) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Honour the EXIF orientation while resizing. Without this a photo
            // taken in portrait comes back on its side, which is exactly the
            // kind of thing nobody notices until there are fifty of them.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary)
        else { throw DownscaleError.unreadable }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw DownscaleError.unreadable }

        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw DownscaleError.unreadable
        }
        return output as Data
    }
}
