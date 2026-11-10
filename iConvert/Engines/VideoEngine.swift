import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Video through AVFoundation's export presets, plus animated GIF.
nonisolated struct VideoEngine: ConversionEngine {
    private static let readable: Set<Format> = [.mp4, .mov, .m4v, .threeGP]
    private static let gifFramesPerSecond = 12.0
    private static let gifMaxFrames = 1800.0
    private static let gifDefaultEdge = 640

    func targets(from source: Format) -> Set<Format> {
        Self.readable.contains(source) ? [.mp4, .mov, .m4v, .gif] : []
    }

    func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let asset = AVURLAsset(url: job.source)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw ConversionError.noVideoTrack
        }
        if job.target == .gif {
            try await writeGIF(asset: asset, job: job, progress: progress)
        } else {
            try await export(asset: asset, job: job, progress: progress)
        }
        return [job.primaryOutput]
    }

    private func export(
        asset: AVURLAsset,
        job: ConversionJob,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileType: AVFileType = switch job.target {
        case .mov: .mov
        case .m4v: .m4v
        default: .mp4
        }
        let preset = job.options.videoPreset.exportPreset
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType),
              let session = AVAssetExportSession(asset: asset, presetName: preset)
        else { throw ConversionError.incompatiblePreset }
        session.shouldOptimizeForNetworkUse = true

        // `states` exists to be observed while `export` runs, which the SDK doesn't express as Sendable.
        nonisolated(unsafe) let observed = session
        let monitor = Task {
            for await state in observed.states(updateInterval: 0.25) {
                if case let .exporting(exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: job.primaryOutput, as: fileType)
    }

    private func writeGIF(
        asset: AVURLAsset,
        job: ConversionJob,
        progress: @Sendable (Double) -> Void
    ) async throws {
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw ConversionError.unreadableFile }

        let fps = min(Self.gifFramesPerSecond, Self.gifMaxFrames / duration)
        let frameCount = max(Int(duration * fps), 1)
        let times = (0..<frameCount).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }

        let edge = job.options.videoPreset.maxHeight ?? Self.gifDefaultEdge
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: edge, height: edge)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 24)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 24)

        guard let destination = CGImageDestinationCreateWithURL(
            job.primaryOutput as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else { throw ConversionError.noRoute }

        let container = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, container)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps],
        ] as CFDictionary

        var written = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            let image = try result.image
            CGImageDestinationAddImage(destination, image, frameProperties)
            written += 1
            progress(Double(written) / Double(frameCount))
        }
        try Task.checkCancellation()
        guard written > 0, CGImageDestinationFinalize(destination) else {
            throw ConversionError.emptyOutput
        }
    }
}
