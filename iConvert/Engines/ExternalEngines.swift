import Foundation

/// Optional command-line tools that widen the set of formats. Found at runtime, because an
/// app opened from Finder doesn't inherit the shell's PATH.
nonisolated enum ExternalTool: String, CaseIterable, Identifiable, Sendable {
    case ffmpeg, pandoc, libreOffice, imageMagick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ffmpeg: "FFmpeg"
        case .pandoc: "Pandoc"
        case .libreOffice: "LibreOffice"
        case .imageMagick: "ImageMagick"
        }
    }

    var unlocks: String {
        switch self {
        case .ffmpeg: "MP3, OGG, Opus, MKV, WebM, AVI, WMV e FLV"
        case .pandoc: "Markdown in uscita, EPUB e LaTeX"
        case .libreOffice: "Excel, PowerPoint e Word in PDF con immagini e tabelle"
        case .imageMagick: "WebP in uscita e SVG in ingresso"
        }
    }

    var installCommand: String {
        switch self {
        case .ffmpeg: "brew install ffmpeg"
        case .pandoc: "brew install pandoc"
        case .libreOffice: "brew install --cask libreoffice"
        case .imageMagick: "brew install imagemagick"
        }
    }

    private var candidates: [String] {
        let binaryFolders = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        switch self {
        case .ffmpeg: return binaryFolders.map { "\($0)/ffmpeg" }
        case .pandoc: return binaryFolders.map { "\($0)/pandoc" }
        case .imageMagick: return binaryFolders.map { "\($0)/magick" }
        case .libreOffice:
            return ["/Applications/LibreOffice.app/Contents/MacOS/soffice"] + binaryFolders.map { "\($0)/soffice" }
        }
    }

    func locate() -> URL? {
        candidates
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(filePath: $0) }
    }

    static func locateAll() -> [ExternalTool: URL] {
        allCases.reduce(into: [:]) { found, tool in
            if let url = tool.locate() { found[tool] = url }
        }
    }
}

// MARK: - FFmpeg

nonisolated struct FFmpegEngine: ConversionEngine {
    let executable: URL?

    var requiredTool: ExternalTool? { .ffmpeg }
    var isAvailable: Bool { executable != nil }

    private static let videoTargets: Set<Format> = [.mp4, .mov, .m4v, .mkv, .webm, .avi, .gif]
    private static let audioTargets: Set<Format> = [.mp3, .m4a, .aac, .wav, .aiff, .flac, .ogg, .opus]

    func targets(from source: Format) -> Set<Format> {
        switch source.category {
        case .video: Self.videoTargets.union(Self.audioTargets)
        case .audio: Self.audioTargets.subtracting([source])
        case .image: source == .gif ? Self.videoTargets.subtracting([.gif]) : []
        case .document: []
        }
    }

    func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        guard let executable else { throw ConversionError.noRoute }
        let duration = await Self.duration(of: job.source, ffmpeg: executable)
        let arguments = Self.arguments(
            source: job.source, target: job.target, output: job.primaryOutput, options: job.options
        )
        try await ProcessRunner.run(executable, arguments, toolName: "FFmpeg") { line in
            guard let duration, duration > 0, line.hasPrefix("out_time_us="),
                  let microseconds = Double(line.dropFirst("out_time_us=".count))
            else { return }
            progress(min(max(microseconds / 1_000_000 / duration, 0), 1))
        }
        return [job.primaryOutput]
    }

    private static func duration(of source: URL, ffmpeg: URL) async -> Double? {
        let probe = ffmpeg.deletingLastPathComponent().appending(path: "ffprobe")
        let output = try? await ProcessRunner.run(
            probe,
            ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", source.path],
            toolName: "ffprobe"
        )
        return output.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func arguments(source: URL, target: Format, output: URL, options: ConversionOptions) -> [String] {
        let bitrate = "\(options.audioBitrate)k"
        let aac = ["-c:a", "aac", "-b:a", bitrate]
        var codec: [String]

        switch target {
        case .mp3: codec = ["-vn", "-c:a", "libmp3lame", "-b:a", bitrate]
        case .m4a: codec = ["-vn"] + aac
        case .aac: codec = ["-vn"] + aac + ["-f", "adts"]
        case .wav: codec = ["-vn", "-c:a", "pcm_s16le"]
        case .aiff: codec = ["-vn", "-c:a", "pcm_s16be"]
        case .flac: codec = ["-vn", "-c:a", "flac"]
        // Homebrew's FFmpeg has no Vorbis encoder, so OGG files carry Opus, the format's modern codec.
        case .ogg: codec = ["-vn", "-c:a", "libopus", "-b:a", bitrate]
        case .opus: codec = ["-vn", "-c:a", "libopus", "-b:a", bitrate]
        case .gif:
            let edge = options.videoPreset.maxHeight ?? 640
            let scale = "scale='min(\(edge),iw)':-2:flags=lanczos"
            let filter = "fps=12,\(scale),split[a][b];[a]palettegen[p];[b][p]paletteuse"
            codec = ["-an", "-filter_complex", filter, "-loop", "0"]
        case .webm:
            codec = videoFilter(options) + ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus", "-b:a", bitrate]
        case .avi:
            codec = videoFilter(options) + ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame", "-b:a", bitrate]
        default:
            let video = options.videoPreset.usesHEVC
                ? ["-c:v", "libx265", "-crf", "24", "-tag:v", "hvc1"]
                : ["-c:v", "libx264", "-crf", "20"]
            codec = videoFilter(options) + video + ["-preset", "medium", "-pix_fmt", "yuv420p"] + aac
            if target != .mkv { codec += ["-movflags", "+faststart"] }
        }

        return ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", source.path]
            + codec
            + ["-progress", "pipe:1", "-nostats", output.path]
    }

    /// Never upscales, and keeps both dimensions even, which H.264 and HEVC require.
    private static func videoFilter(_ options: ConversionOptions) -> [String] {
        if let height = options.videoPreset.maxHeight {
            return ["-vf", "scale=-2:'min(\(height),trunc(ih/2)*2)'"]
        }
        return ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
    }
}

// MARK: - Pandoc

nonisolated struct PandocEngine: ConversionEngine {
    let executable: URL?

    var requiredTool: ExternalTool? { .pandoc }
    var isAvailable: Bool { executable != nil }

    private static let formats: Set<Format> = [.md, .html, .docx, .odt, .rtf, .epub, .tex, .txt]

    func targets(from source: Format) -> Set<Format> {
        Self.formats.contains(source) ? Self.formats.subtracting([source]) : []
    }

    func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        guard let executable else { throw ConversionError.noRoute }
        try await ProcessRunner.run(executable, Self.arguments(job), toolName: "Pandoc")
        return [job.primaryOutput]
    }

    static func arguments(_ job: ConversionJob) -> [String] {
        // Relative image paths in the document mean "next to the source file".
        let folder = job.source.deletingLastPathComponent().path
        var arguments = ["--standalone", "--resource-path=\(folder)", "-o", job.primaryOutput.path]
        switch job.sourceFormat {
        case .txt: arguments += ["-f", "markdown"]
        default: break
        }
        switch job.target {
        case .txt: arguments += ["-t", "plain"]
        case .tex: arguments += ["-t", "latex"]
        case .md: arguments += ["-t", "gfm"]
        default: break
        }
        arguments.append(job.source.path)
        return arguments
    }
}

// MARK: - LibreOffice

nonisolated struct LibreOfficeEngine: ConversionEngine {
    let executable: URL?

    var requiredTool: ExternalTool? { .libreOffice }
    var isAvailable: Bool { executable != nil }

    private static let word: Set<Format> = [.doc, .docx, .odt, .rtf]
    private static let sheets: Set<Format> = [.xls, .xlsx, .ods, .csv]
    private static let slides: Set<Format> = [.ppt, .pptx, .odp]

    func targets(from source: Format) -> Set<Format> {
        for family in [Self.word, Self.sheets, Self.slides] where family.contains(source) {
            return family.union([.pdf]).subtracting([source])
        }
        return []
    }

    func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        guard let executable else { throw ConversionError.noRoute }
        // A private profile lets several conversions run at once, and alongside the user's own LibreOffice.
        let profile = job.workDirectory.appending(path: "profile", directoryHint: .isDirectory)
        let results = job.workDirectory.appending(path: "results", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)

        var arguments = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore"]
        if job.sourceFormat == .csv {
            // UTF-8, split on commas, semicolons (what Excel writes in Italy) or tabs.
            arguments.append("--infilter=CSV:44/59/9,34,76")
        }
        arguments += ["--convert-to", Self.outputFilter(for: job.target), "--outdir", results.path, job.source.path]
        try await ProcessRunner.run(executable, arguments, toolName: "LibreOffice")

        let produced = results.appending(path: job.baseName).appendingPathExtension(job.target.id)
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw ConversionError.emptyOutput
        }
        try FileManager.default.moveItem(at: produced, to: job.primaryOutput)
        return [job.primaryOutput]
    }
}

extension LibreOfficeEngine {
    nonisolated static func outputFilter(for target: Format) -> String {
        target == .csv ? "csv:Text - txt - csv (StarCalc):44,34,76" : target.id
    }
}

// MARK: - ImageMagick

nonisolated struct ImageMagickEngine: ConversionEngine {
    let executable: URL?

    var requiredTool: ExternalTool? { .imageMagick }
    var isAvailable: Bool { executable != nil }

    private static let targetsList: Set<Format> = [.webp, .png, .jpg, .tiff, .gif, .bmp]

    func targets(from source: Format) -> Set<Format> {
        guard source.category == .image else { return [] }
        return Self.targetsList.subtracting([source])
    }

    func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        guard let executable else { throw ConversionError.noRoute }
        // ImageMagick reads `[1]` and `%d` in paths as commands, so it only ever sees neutral names.
        let input = job.workDirectory.appending(path: "input").appendingPathExtension(job.sourceFormat.id)
        let output = job.workDirectory.appending(path: "output").appendingPathExtension(job.target.id)
        try FileManager.default.createSymbolicLink(at: input, withDestinationURL: job.source)

        var arguments = [input.path]
        if job.target == .jpg || job.target == .bmp {
            arguments += ["-background", "white", "-alpha", "remove", "-alpha", "off"]
        }
        arguments += ["-quality", "\(Int(job.options.imageQuality * 100))"]
        if let limit = job.options.imageMaxDimension {
            arguments += ["-resize", "\(limit)x\(limit)>"]
        }
        arguments.append(output.path)
        try await ProcessRunner.run(executable, arguments, toolName: "ImageMagick")
        try FileManager.default.moveItem(at: output, to: job.primaryOutput)
        return [job.primaryOutput]
    }
}
