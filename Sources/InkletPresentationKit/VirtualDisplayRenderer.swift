// Shared with inklet-ios/portal/Shared.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

nonisolated public enum VirtualDisplayRenderer {
    public static let size = CGSize(width: 720, height: 752)
    private static func context(size: CGSize) throws -> CGContext {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 2048, size.height <= 2048 else {
            throw VirtualDisplayError.message("Unsupported display dimensions.")
        }
        guard let value = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VirtualDisplayError.message("Couldn't prepare the display image.")
        }
        value.setFillColor(CGColor(gray: 1, alpha: 1)); value.fill(CGRect(origin: .zero, size: size))
        return value
    }
    private static func png(_ context: CGContext) throws -> Data {
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw VirtualDisplayError.message("Couldn't encode the display image.")
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output), data.length <= 2 * 1024 * 1024 else {
            throw VirtualDisplayError.message("The image is too large. Choose a smaller image.")
        }
        return data as Data
    }
    public static func text(_ input: String, size: CGSize = size) throws -> Data {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 1000 else {
            throw VirtualDisplayError.message("Write between 1 and 1,000 characters.")
        }
        let ctx = try context(size: size)
        let bounds = CGRect(x: 52, y: 60, width: size.width - 104, height: size.height - 120)
        var selected: CTFrame?
        // Fit the complete text, including explicit line breaks; never silently crop it.
        for fontSize in stride(from: 48.0, through: 14.0, by: -1.0) {
            let string = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Georgia" as CFString, fontSize, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1)
            ])
            let setter = CTFramesetterCreateWithAttributedString(string)
            let path = CGPath(rect: bounds, transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: string.length), path, nil)
            if CTFrameGetVisibleStringRange(frame).length == string.length { selected = frame; break }
        }
        guard let selected else { throw VirtualDisplayError.message("This text has too many lines to fit. Shorten it before publishing.") }
        CTFrameDraw(selected, ctx)
        return try png(ctx)
    }
    public static func image(_ data: Data, size: CGSize = size) throws -> Data {
        guard data.count <= 30 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { throw VirtualDisplayError.message("Choose a supported image up to 30 MB.") }
        let ctx = try context(size: size)
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height))
        return try png(ctx)
    }
}
