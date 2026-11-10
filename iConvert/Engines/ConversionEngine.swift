import Foundation

nonisolated struct ConversionJob: Sendable {
    let source: URL
    let sourceFormat: Format
    let target: Format
    let options: ConversionOptions
    /// Empty temporary folder. Engines write here; the runner moves results into place.
    let workDirectory: URL

    var baseName: String { source.deletingPathExtension().lastPathComponent }

    var primaryOutput: URL {
        workDirectory.appending(path: baseName).appendingPathExtension(target.id)
    }
}

nonisolated protocol ConversionEngine: Sendable {
    /// The tool this engine depends on, or `nil` when it is built into macOS.
    var requiredTool: ExternalTool? { get }
    var isAvailable: Bool { get }
    func targets(from source: Format) -> Set<Format>
    /// Reports progress from 0 to 1 and returns the files written to the work directory.
    func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL]
}

extension ConversionEngine {
    nonisolated var requiredTool: ExternalTool? { nil }
    nonisolated var isAvailable: Bool { true }
}

/// Picks an engine for each conversion. Order is priority: the first engine offering
/// a route wins, so built-in media handling beats FFmpeg, and LibreOffice and Pandoc beat
/// the simpler built-in document conversion when they are installed.
nonisolated struct EngineRegistry: Sendable {
    let engines: [any ConversionEngine]

    init(tools: [ExternalTool: URL]) {
        engines = [
            ImageEngine(),
            VideoEngine(),
            AudioEngine(),
            FFmpegEngine(executable: tools[.ffmpeg]),
            LibreOfficeEngine(executable: tools[.libreOffice]),
            PandocEngine(executable: tools[.pandoc]),
            TextEngine(),
            ImageMagickEngine(executable: tools[.imageMagick]),
        ]
    }

    /// Available targets for a source, in menu order.
    func routes(from source: Format) -> [Format] {
        let targets = engines.filter(\.isAvailable).reduce(into: Set<Format>()) {
            $0.formUnion($1.targets(from: source))
        }
        return Format.all.filter(targets.contains)
    }

    func engine(from source: Format, to target: Format) -> (any ConversionEngine)? {
        engines.first { $0.isAvailable && $0.targets(from: source).contains(target) }
    }

    /// The tool to install when a source has no available route at all.
    func missingTool(for source: Format) -> ExternalTool? {
        engines.first { !$0.isAvailable && !$0.targets(from: source).isEmpty }?.requiredTool
    }
}

nonisolated enum ConversionRunner {
    /// Runs one conversion off the main actor. Results only appear in the destination once
    /// complete, so a failed or cancelled job never leaves a partial file behind.
    @concurrent
    static func run(
        source: URL,
        sourceFormat: Format,
        target: Format,
        options: ConversionOptions,
        engine: any ConversionEngine,
        destination: URL?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        let fileManager = FileManager.default
        let folder = destination ?? source.deletingLastPathComponent()
        let work = try workDirectory(near: folder)
        defer { try? fileManager.removeItem(at: work) }

        let job = ConversionJob(
            source: source,
            sourceFormat: sourceFormat,
            target: target,
            options: options,
            workDirectory: work
        )
        let outputs = try await engine.convert(job, progress: progress)
        try Task.checkCancellation()

        let nonEmpty = outputs.filter { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size > 0
        }
        guard !nonEmpty.isEmpty else { throw ConversionError.emptyOutput }

        return try nonEmpty.map { try moveWithoutOverwriting($0, into: folder) }
    }

    private static func workDirectory(near folder: URL) throws -> URL {
        let fileManager = FileManager.default
        if let url = try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: folder,
            create: true
        ) {
            return url
        }
        let url = fileManager.temporaryDirectory.appending(path: "iConvert-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Never replaces an existing file: `a.mp4` becomes `a 2.mp4`, and so on. Foundation's
    /// `moveItem` checks and then renames, so parallel jobs wanting one name could overwrite
    /// each other. Claiming the name atomically closes that gap.
    static func moveWithoutOverwriting(_ file: URL, into folder: URL) throws -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var attempt = 1
        while true {
            let name = attempt == 1 ? base : "\(base) \(attempt)"
            let candidate = folder.appending(path: name).appendingPathExtension(ext)
            if try claim(file, as: candidate) { return candidate }
            attempt += 1
        }
    }

    /// Returns `false` when the name is taken.
    private static func claim(_ file: URL, as candidate: URL) throws -> Bool {
        if renamex_np(file.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return true }
        switch errno {
        case EEXIST:
            return false
        case EXDEV, ENOTSUP, EINVAL:
            // Other volume, or a file system without exclusive rename: reserve the name, then copy.
            let descriptor = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            guard descriptor >= 0 else {
                if errno == EEXIST { return false }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            close(descriptor)
            guard copyfile(file.path, candidate.path, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                let code = errno
                try? FileManager.default.removeItem(at: candidate)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            return true
        default:
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
