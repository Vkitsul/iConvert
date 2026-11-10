import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images through ImageIO, plus PDF pages rendered to images. Nothing to install.
nonisolated struct ImageEngine: ConversionEngine {
    private static let readable: Set<Format> = [
        .jpg, .png, .heic, .tiff, .gif, .bmp, .webp, .avif, .jp2, .ico, .tga, .psd,
        .jxl, .dng, .cr2, .cr3, .nef, .arw,
    ]
    private static let writable: Set<Format> = [
        .jpg, .png, .heic, .tiff, .gif, .bmp, .avif, .jp2, .ico, .tga, .psd,
    ]
    private static let pageTargets: Set<Format> = [.jpg, .png, .tiff, .heic]
    private static let opaqueTargets: Set<Format> = [.jpg, .bmp]
    private static let multiFrameTargets: Set<Format> = [.gif, .tiff]
    private static let icoMaxDimension = 256
    private static let pdfRenderDPI: CGFloat = 200

    func targets(from source: Format) -> Set<Format> {
        if source == .pdf { return Self.pageTargets }
        guard Self.readable.contains(source) else { return [] }
        return Self.writable.union([.pdf])
    }

    func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        if job.sourceFormat == .pdf {
            return try renderPDFPages(job, progress: progress)
        }
        guard let source = CGImageSourceCreateWithURL(job.source as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { throw ConversionError.unreadableFile }

        if job.target == .pdf {
            try writePDF(from: source, job: job, progress: progress)
        } else {
            try writeImage(from: source, job: job, progress: progress)
        }
        return [job.primaryOutput]
    }

    private func writeImage(
        from source: CGImageSource,
        job: ConversionJob,
        progress: @Sendable (Double) -> Void
    ) throws {
        guard let type = job.target.utType?.identifier else { throw ConversionError.noRoute }
        let sourceCount = CGImageSourceGetCount(source)
        let frameCount = Self.multiFrameTargets.contains(job.target) ? sourceCount : 1
        guard let destination = CGImageDestinationCreateWithURL(
            job.primaryOutput as CFURL, type as CFString, frameCount, nil
        ) else { throw ConversionError.noRoute }

        var maxDimension = job.options.imageMaxDimension
        if job.target == .ico {
            maxDimension = min(maxDimension ?? Self.icoMaxDimension, Self.icoMaxDimension)
        }

        if job.target == .gif, let container = CGImageSourceCopyProperties(source, nil) {
            CGImageDestinationSetProperties(destination, container)
        }

        for index in 0..<frameCount {
            try Task.checkCancellation()
            let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            var properties = sourceProperties
            properties[kCGImageDestinationLossyCompressionQuality] = job.options.imageQuality

            let needsFlattening = Self.opaqueTargets.contains(job.target) && hasAlpha(sourceProperties)
            let oversized = maxDimension.map { $0 < longestEdge(sourceProperties) } ?? false
            let needsSquare = job.target == .ico

            if !needsFlattening && !oversized && !needsSquare {
                // Keeps the original pixels, metadata and orientation flag.
                CGImageDestinationAddImageFromSource(destination, source, index, properties as CFDictionary)
            } else {
                guard var image = decodedImage(source, index: index, maxDimension: oversized ? maxDimension : nil)
                else { throw ConversionError.unreadableFile }
                if needsFlattening {
                    guard let flattened = flatten(image) else { throw ConversionError.unreadableFile }
                    image = flattened
                }
                if needsSquare {
                    guard let square = squared(image) else { throw ConversionError.unreadableFile }
                    image = square
                }
                // Decoding already applied the rotation, so the flag must not apply it twice.
                properties[kCGImagePropertyOrientation] = 1
                properties[kCGImagePropertyPixelWidth] = nil
                properties[kCGImagePropertyPixelHeight] = nil
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            }
            progress(Double(index + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.emptyOutput }
    }

    private func writePDF(
        from source: CGImageSource,
        job: ConversionJob,
        progress: @Sendable (Double) -> Void
    ) throws {
        let count = CGImageSourceGetCount(source)
        var mediaBox = CGRect.zero
        guard let context = CGContext(job.primaryOutput as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.emptyOutput
        }
        for index in 0..<count {
            try Task.checkCancellation()
            guard let image = decodedImage(source, index: index, maxDimension: job.options.imageMaxDimension) else {
                throw ConversionError.unreadableFile
            }
            var page = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.beginPage(mediaBox: &page)
            context.draw(image, in: page)
            context.endPage()
            progress(Double(index + 1) / Double(count))
        }
        context.closePDF()
    }

    private func renderPDFPages(
        _ job: ConversionJob,
        progress: @Sendable (Double) -> Void
    ) throws -> [URL] {
        guard let document = CGPDFDocument(job.source as CFURL) else { throw ConversionError.unreadableFile }
        guard document.isUnlocked else { throw ConversionError.passwordProtected }
        guard let type = job.target.utType?.identifier else { throw ConversionError.noRoute }

        let count = document.numberOfPages
        guard count > 0 else { throw ConversionError.unreadableFile }

        var outputs: [URL] = []
        for number in 1...count {
            try Task.checkCancellation()
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.cropBox)
            var scale = Self.pdfRenderDPI / 72
            if let limit = job.options.imageMaxDimension {
                scale = min(scale, CGFloat(limit) / max(box.width, box.height))
            }
            let rotated = page.rotationAngle % 180 != 0
            let width = Int(((rotated ? box.height : box.width) * scale).rounded())
            let height = Int(((rotated ? box.width : box.height) * scale).rounded())

            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { throw ConversionError.emptyOutput }

            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let target = CGRect(x: 0, y: 0, width: width, height: height)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)

            guard let image = context.makeImage() else { throw ConversionError.emptyOutput }
            let name = count == 1 ? job.baseName : "\(job.baseName)-\(number)"
            let url = job.workDirectory.appending(path: name).appendingPathExtension(job.target.id)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
                throw ConversionError.noRoute
            }
            let properties = [kCGImageDestinationLossyCompressionQuality: job.options.imageQuality] as CFDictionary
            CGImageDestinationAddImage(destination, image, properties)
            guard CGImageDestinationFinalize(destination) else { throw ConversionError.emptyOutput }
            outputs.append(url)
            progress(Double(number) / Double(count))
        }
        return outputs
    }

    private func decodedImage(_ source: CGImageSource, index: Int, maxDimension: Int?) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        options[kCGImageSourceThumbnailMaxPixelSize] = maxDimension ?? longestEdge(properties)
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    private func longestEdge(_ properties: [CFString: Any]) -> Int {
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(width, height)
    }

    private func hasAlpha(_ properties: [CFString: Any]) -> Bool {
        properties[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    /// ICO only holds square images, so the picture is centred on a transparent canvas.
    private func squared(_ image: CGImage) -> CGImage? {
        guard image.width != image.height else { return image }
        let side = max(image.width, image.height)
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(
            x: (side - image.width) / 2, y: (side - image.height) / 2,
            width: image.width, height: image.height
        ))
        return context.makeImage()
    }

    /// JPEG and BMP have no transparency, and would otherwise turn it black.
    private func flatten(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }
}
