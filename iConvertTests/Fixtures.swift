import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import iConvert

/// A temporary folder with real media files built on demand, so tests exercise the actual
/// system encoders rather than checked-in samples.
struct Sandbox {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "iConvertTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL { folder.appending(path: name) }

    func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func write(_ text: String, to name: String) throws -> URL {
        let url = url(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A half transparent, half red image.
    func png(_ name: String = "image.png", width: Int = 400, height: Int = 200) throws -> URL {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let url = url(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return url
    }

    func animatedGIF(_ name: String = "anim.gif", frames: Int = 4) throws -> URL {
        let url = url(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)!
        for index in 0..<frames {
            let context = CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(CGColor(srgbRed: Double(index) / Double(frames), green: 0.5, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        }
        _ = CGImageDestinationFinalize(destination)
        return url
    }

    /// A PDF whose pages hold only drawn rectangles, which is what a scan looks like to text extraction.
    func imageOnlyPDF(_ name: String = "scan.pdf", pages: Int = 2) throws -> URL {
        let url = url(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.3, alpha: 1))
            context.fill(CGRect(x: 40, y: 40, width: 100, height: 100))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// A sine tone. Writes through AVAudioFile, the same API under test only on the input side.
    func tone(
        _ name: String = "tone.wav",
        seconds: Double = 1,
        sampleRate: Double = 44_100,
        channels: AVAudioChannelCount = 2,
        bitDepth: Int = 16
    ) throws -> URL {
        let url = url(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = Float(sin(2 * .pi * 440 * Double(frame) / sampleRate)) * 0.4
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        try file.write(from: buffer)
        file.close()
        return url
    }

    /// A short silent H.264 movie.
    func silentMovie(_ name: String = "silent.mov", width: Int = 640, height: Int = 360, frames: Int = 30) async throws -> URL {
        let url = url(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pixels: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixels)
            let buffer = pixels!
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(index * 8), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }

    /// A short movie with both picture and sound.
    func movie(_ name: String = "movie.mov") async throws -> URL {
        let picture = AVURLAsset(url: try await silentMovie("picture-\(UUID().uuidString).mov"))
        let sound = AVURLAsset(url: try tone("sound-\(UUID().uuidString).wav"))
        let composition = AVMutableComposition()
        let duration = try await picture.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)

        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try videoTrack.insertTimeRange(range, of: try await picture.loadTracks(withMediaType: .video)[0], at: .zero)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try audioTrack.insertTimeRange(range, of: try await sound.loadTracks(withMediaType: .audio)[0], at: .zero)

        let url = url(name)
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        try await session.export(to: url, as: .mov)
        return url
    }

    /// Runs a conversion the way the queue does, with the system engines only.
    func convert(
        _ source: URL,
        to target: Format,
        options: ConversionOptions = ConversionOptions(),
        destination: URL? = nil
    ) async throws -> [URL] {
        guard let format = Format.detect(source) else { throw ConversionError.noRoute }
        let registry = EngineRegistry(tools: [:])
        guard let engine = registry.engine(from: format, to: target) else { throw ConversionError.noRoute }
        return try await ConversionRunner.run(
            source: source,
            sourceFormat: format,
            target: target,
            options: options,
            engine: engine,
            destination: destination,
            progress: { _ in }
        )
    }
}

func imageSource(_ url: URL) -> CGImageSource? {
    CGImageSourceCreateWithURL(url as CFURL, nil)
}

func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
    guard let source = imageSource(url),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
}
