import AVFoundation

/// Audio, and the audio track of video files, through AVFoundation.
/// macOS can decode MP3 but not encode it; that route needs FFmpeg.
nonisolated struct AudioEngine: ConversionEngine {
    private static let readableAudio: Set<Format> = [.mp3, .m4a, .aac, .wav, .aiff, .flac, .caf]
    private static let readableVideo: Set<Format> = [.mp4, .mov, .m4v, .threeGP]
    private static let writable: Set<Format> = [.m4a, .wav, .aiff, .flac, .caf]
    private static let aacMaxSampleRate = 48_000.0

    func targets(from source: Format) -> Set<Format> {
        if Self.readableVideo.contains(source) { return Self.writable }
        guard Self.readableAudio.contains(source) else { return [] }
        return Self.writable.subtracting([source])
    }

    func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let asset = AVURLAsset(url: job.source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { throw ConversionError.unreadableFile }

        let channels = min(Int(stream.mChannelsPerFrame), 2)
        var sampleRate = stream.mSampleRate
        if job.target == .m4a { sampleRate = min(sampleRate, Self.aacMaxSampleRate) }

        try transcode(
            asset: asset,
            track: track,
            sampleRate: sampleRate,
            channels: channels,
            sourceBitDepth: Int(stream.mBitsPerChannel),
            duration: duration,
            job: job,
            progress: progress
        )
        return [job.primaryOutput]
    }

    private func transcode(
        asset: AVURLAsset,
        track: AVAssetTrack,
        sampleRate: Double,
        channels: Int,
        sourceBitDepth: Int,
        duration: Double,
        job: ConversionJob,
        progress: @Sendable (Double) -> Void
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        guard reader.canAdd(output) else { throw ConversionError.unreadableFile }
        reader.add(output)
        guard reader.startReading() else { throw ConversionError.unreadableFile }
        defer { reader.cancelReading() }

        guard let pcm = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels)
        ) else { throw ConversionError.unreadableFile }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: job.primaryOutput,
                settings: Self.outputSettings(
                    target: job.target,
                    sampleRate: sampleRate,
                    channels: channels,
                    sourceBitDepth: sourceBitDepth,
                    bitrate: job.options.audioBitrate
                ),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw ConversionError.encoderRejected
        }
        defer { file.close() }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames))
            else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)

            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
            )
            guard status == noErr else { throw ConversionError.unreadableFile }
            try file.write(from: buffer)

            if duration > 0 {
                let position = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                progress(min(max(position / duration, 0), 1))
            }
        }
        if reader.status == .failed {
            throw reader.error ?? ConversionError.unreadableFile
        }
    }

    /// The encoder only accepts certain bitrates, and which ones depends on the sample rate
    /// and channels: a mono voice memo can't be 256 kbps. Takes the closest one not above the request.
    private static func supportedAACBitrate(requestedKbps: Int, sampleRate: Double, channels: Int) -> Int {
        let requested = requestedKbps * 1000
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let input = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)),
              let output = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: input, to: output),
              let rates = converter.applicableEncodeBitRates?.map(\.intValue), let lowest = rates.min()
        else { return requested }
        return rates.filter { $0 <= requested }.max() ?? lowest
    }

    private static func outputSettings(
        target: Format,
        sampleRate: Double,
        channels: Int,
        sourceBitDepth: Int,
        bitrate: Int
    ) -> [String: Any] {
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        // Compressed sources report no bit depth, and 16 bits is what they decode to in practice.
        let depth = [16, 24, 32].contains(sourceBitDepth) ? sourceBitDepth : 16
        switch target {
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = supportedAACBitrate(
                requestedKbps: bitrate, sampleRate: sampleRate, channels: channels
            )
        case .aiff, .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = depth
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = target == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = min(depth, 24)
        default:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = min(depth, 24)
        }
        return settings
    }
}
