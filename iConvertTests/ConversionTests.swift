import AVFoundation
import PDFKit
import Testing
@testable import iConvert

/// Encoder sessions are a limited system resource, so media tests run one at a time. The
/// app's own parallelism is covered by the stress test in `QueueTests`.
@Suite(.serialized, .timeLimit(.minutes(2))) struct MediaTests {}

@Suite struct ImageConversionTests {
    @Test(arguments: [Format.jpg, .heic, .tiff, .gif, .bmp, .avif, .jp2, .ico, .tga, .psd])
    func `a PNG converts to every writable format`(target: Format) async throws {
        let sandbox = try Sandbox()
        let outputs = try await sandbox.convert(try sandbox.png(), to: target)
        let output = try #require(outputs.first)
        #expect(output.pathExtension == target.id)
        #expect(pixelSize(output) != nil)
    }

    @Test func `transparency becomes white in a JPEG, not black`() async throws {
        let sandbox = try Sandbox()
        let output = try #require(try await sandbox.convert(try sandbox.png(), to: .jpg).first)
        let source = try #require(imageSource(output))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // Draw the left, formerly transparent half into the single pixel.
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        #expect(pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240)
    }

    @Test func `max dimension shrinks the longest edge and keeps the aspect ratio`() async throws {
        let sandbox = try Sandbox()
        var options = ConversionOptions()
        options.imageMaxDimension = 100
        let output = try #require(try await sandbox.convert(try sandbox.png(), to: .png, options: options).first)
        let size = try #require(pixelSize(output))
        #expect(size.width == 100)
        #expect(size.height == 50)
    }

    @Test func `max dimension never enlarges`() async throws {
        let sandbox = try Sandbox()
        var options = ConversionOptions()
        options.imageMaxDimension = 4096
        let output = try #require(try await sandbox.convert(try sandbox.png(), to: .jpg, options: options).first)
        #expect(pixelSize(output)?.width == 400)
    }

    @Test func `an animated GIF keeps its frames when staying a GIF`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.animatedGIF("anim.gif", frames: 4)
        let output = try #require(try await sandbox.convert(source, to: .gif).first)
        #expect(CGImageSourceGetCount(try #require(imageSource(output))) == 4)
    }

    @Test func `an animated GIF becomes one still in a PNG`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.animatedGIF()
        let output = try #require(try await sandbox.convert(source, to: .png).first)
        #expect(CGImageSourceGetCount(try #require(imageSource(output))) == 1)
    }

    @Test func `an image becomes a one page PDF`() async throws {
        let sandbox = try Sandbox()
        let output = try #require(try await sandbox.convert(try sandbox.png(), to: .pdf).first)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 1)
    }

    @Test func `every PDF page becomes its own numbered image`() async throws {
        let sandbox = try Sandbox()
        let outputs = try await sandbox.convert(try sandbox.imageOnlyPDF("doc.pdf", pages: 3), to: .png)
        #expect(outputs.map(\.lastPathComponent).sorted() == ["doc-1.png", "doc-2.png", "doc-3.png"])
        #expect(pixelSize(outputs[0]) != nil)
    }

    @Test func `a corrupt image fails with a clear error`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("not an image", to: "broken.png")
        await #expect(throws: ConversionError.unreadableFile) {
            try await sandbox.convert(source, to: .jpg)
        }
    }
}

extension MediaTests { @Suite struct AudioConversionTests {
    @Test(arguments: [Format.m4a, .aiff, .flac, .caf])
    func `a WAV converts and keeps its length`(target: Format) async throws {
        let sandbox = try Sandbox()
        let output = try #require(try await sandbox.convert(try sandbox.tone(seconds: 2), to: target).first)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
    }

    @Test(arguments: ConversionOptions.audioBitrates, [AVAudioChannelCount(1), 2])
    func `AAC encodes at every bitrate, in mono and stereo`(bitrate: Int, channels: AVAudioChannelCount) async throws {
        let sandbox = try Sandbox()
        var options = ConversionOptions()
        options.audioBitrate = bitrate
        let source = try sandbox.tone(channels: channels)
        let output = try #require(try await sandbox.convert(source, to: .m4a, options: options).first)
        #expect(try await AVURLAsset(url: output).load(.duration).seconds > 0.9)
    }

    @Test(arguments: [8_000.0, 11_025, 16_000, 22_050, 32_000, 44_100, 48_000, 96_000], [AVAudioChannelCount(1), 2])
    func `every target handles unusual sample rates at the highest bitrate`(sampleRate: Double, channels: AVAudioChannelCount) async throws {
        let sandbox = try Sandbox()
        var options = ConversionOptions()
        options.audioBitrate = 320
        let source = try sandbox.tone(sampleRate: sampleRate, channels: channels)
        for target in [Format.m4a, .flac, .caf, .aiff] {
            let output = try #require(try await sandbox.convert(source, to: target, options: options).first)
            #expect(try await AVURLAsset(url: output).load(.duration).seconds > 0.9, "\(target.id)")
        }
    }

    @Test(arguments: [16, 24, 32])
    func `lossless targets accept every source bit depth`(bitDepth: Int) async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.tone(bitDepth: bitDepth)
        for target in [Format.flac, .caf, .aiff] {
            let output = try #require(try await sandbox.convert(source, to: target).first)
            #expect(try await AVURLAsset(url: output).load(.duration).seconds > 0.9, "\(target.id)")
        }
    }

    @Test func `a real spoken voice memo converts`() async throws {
        let sandbox = try Sandbox()
        let source = sandbox.url("voice.aiff")
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-o", source.path, "testing"]
        try say.run()
        say.waitUntilExit()
        let output = try #require(try await sandbox.convert(source, to: .m4a).first)
        #expect(try await AVURLAsset(url: output).load(.duration).seconds > 0)
    }

    @Test func `a higher bitrate makes a larger AAC file`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.tone(seconds: 5)
        var low = ConversionOptions()
        low.audioBitrate = 128
        var high = ConversionOptions()
        high.audioBitrate = 320
        let small = try #require(try await sandbox.convert(source, to: .m4a, options: low).first)
        let large = try #require(try await sandbox.convert(source, to: .m4a, options: high).first)
        let smallSize = try #require(try small.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let largeSize = try #require(try large.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(largeSize > smallSize)
    }

    @Test func `96 kHz audio fits AAC by resampling`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.tone(sampleRate: 96_000)
        let output = try #require(try await sandbox.convert(source, to: .m4a).first)
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let stream = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description))
        #expect(stream.pointee.mSampleRate == 48_000)
    }

    @Test func `24 bit audio stays 24 bit in lossless formats`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.tone(bitDepth: 24)
        let output = try #require(try await sandbox.convert(source, to: .aiff).first)
        let file = try AVAudioFile(forReading: output)
        #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24)
    }

    @Test func `audio can be extracted from a video`() async throws {
        let sandbox = try Sandbox()
        let output = try #require(try await sandbox.convert(try await sandbox.movie(), to: .m4a).first)
        let asset = AVURLAsset(url: output)
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
    }

    @Test func `extracting audio from a silent video says so`() async throws {
        let sandbox = try Sandbox()
        let source = try await sandbox.silentMovie()
        await #expect(throws: ConversionError.noAudioTrack) {
            try await sandbox.convert(source, to: .m4a)
        }
    }
}

}

extension MediaTests { @Suite struct VideoConversionTests {
    @Test(arguments: [Format.mp4, .m4v, .mov])
    func `a movie converts and keeps both tracks`(target: Format) async throws {
        let sandbox = try Sandbox()
        let output = try #require(try await sandbox.convert(try await sandbox.movie(), to: target).first)
        #expect(output.pathExtension == target.id)
        let asset = AVURLAsset(url: output)
        #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test(arguments: VideoPreset.allCases)
    func `every quality preset produces a playable MP4`(preset: VideoPreset) async throws {
        let sandbox = try Sandbox()
        var options = ConversionOptions()
        options.videoPreset = preset
        let source = try await sandbox.silentMovie()
        let output = try #require(try await sandbox.convert(source, to: .mp4, options: options).first)
        #expect(try await !AVURLAsset(url: output).loadTracks(withMediaType: .video).isEmpty)
    }

    @Test func `the 480p preset shrinks larger video`() async throws {
        let sandbox = try Sandbox()
        var options = ConversionOptions()
        options.videoPreset = .sdH264
        let source = try await sandbox.silentMovie(width: 1280, height: 720)
        let output = try #require(try await sandbox.convert(source, to: .mp4, options: options).first)
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.height <= 480)
    }

    @Test func `HEVC presets really write HEVC`() async throws {
        let sandbox = try Sandbox()
        var options = ConversionOptions()
        options.videoPreset = .originalHEVC
        let source = try await sandbox.silentMovie()
        let output = try #require(try await sandbox.convert(source, to: .mp4, options: options).first)
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC)
    }

    @Test func `a video becomes an animated GIF`() async throws {
        let sandbox = try Sandbox()
        let output = try #require(try await sandbox.convert(try await sandbox.silentMovie(), to: .gif).first)
        let source = try #require(imageSource(output))
        #expect(CGImageSourceGetCount(source) > 5)
        #expect(pixelSize(output)?.width ?? 0 <= 640)
    }
}

}

@Suite struct DocumentConversionTests {
    private static let markdown = """
    # Café title

    A paragraph with **bold**, *italic* and `code`.

    - first
    - second

    1. one
    2. two

    > a quote

    | A | B |
    |---|---|
    | x | y |

    ```
    let a = 1 < 2
    ```

    [a link](https://example.com)
    """

    @Test func `Markdown renders to proper HTML`() throws {
        let html = try MarkdownRenderer.html(from: Self.markdown, title: "T")
        #expect(html.contains("<h1>Café title</h1>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>italic</em>"))
        #expect(html.contains("<code>code</code>"))
        #expect(html.contains("<li><p>first</p>") || html.contains("<li>first"))
        #expect(html.contains("<ol>"))
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("<table>"))
        #expect(html.contains("let a = 1 &lt; 2"))
        #expect(html.contains("<a href=\"https://example.com\">a link</a>"))
    }

    @Test func `HTML in file names and text is escaped`() throws {
        let html = try MarkdownRenderer.html(from: "a & b", title: "<x>")
        #expect(html.contains("a &amp; b"))
        #expect(html.contains("&lt;x&gt;"))
    }

    @Test(arguments: [Format.html, .rtf, .doc, .docx, .odt, .txt, .pdf])
    func `Markdown converts to every document format`(target: Format) async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write(Self.markdown, to: "note.md")
        let output = try #require(try await sandbox.convert(source, to: target).first)
        #expect(output.lastPathComponent == "note.\(target.id)")

        // Read it back through textutil or PDFKit to prove the words and accents survived.
        let text: String
        if target == .pdf {
            text = try #require(PDFDocument(url: output)?.string)
        } else if target == .txt || target == .html {
            text = try String(contentsOf: output, encoding: .utf8)
        } else {
            let back = try await sandbox.convert(output, to: .txt, destination: try sandboxSubfolder(sandbox))
            text = try String(contentsOf: try #require(back.first), encoding: .utf8)
        }
        #expect(text.contains("Café title"))
        #expect(text.contains("bold"))
    }

    @Test func `plain text with accents survives to PDF`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("Déjà vu: a naïve café façade.", to: "plain.txt")
        let output = try #require(try await sandbox.convert(source, to: .pdf).first)
        #expect(try #require(PDFDocument(url: output)?.string).contains("naïve café"))
    }

    @Test func `long text flows onto several PDF pages`() async throws {
        let sandbox = try Sandbox()
        let line = "This is a fairly long café test line, written to fill up the page.\n"
        let source = try sandbox.write(String(repeating: line, count: 400), to: "long.txt")
        let output = try #require(try await sandbox.convert(source, to: .pdf).first)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount > 1)
        // Nothing lost at page boundaries.
        let text = try #require(document.string)
        #expect(text.components(separatedBy: "This is a fairly long café").count == 401)
    }

    @Test func `text can be taken out of a PDF`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("Text inside the PDF, déjà vu.", to: "in.txt")
        let pdf = try #require(try await sandbox.convert(source, to: .pdf).first)
        let output = try #require(try await sandbox.convert(pdf, to: .txt, destination: try sandboxSubfolder(sandbox)).first)
        #expect(try String(contentsOf: output, encoding: .utf8).contains("déjà vu"))
    }

    @Test func `a scanned PDF explains why it has no text`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.imageOnlyPDF()
        await #expect(throws: ConversionError.noExtractableText) {
            try await sandbox.convert(source, to: .txt)
        }
    }

    private func sandboxSubfolder(_ sandbox: Sandbox) throws -> URL {
        let folder = sandbox.url("sub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

@Suite struct RunnerTests {
    @Test func `an existing file is never overwritten`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.png()
        let original = try sandbox.write("keep me", to: "image.jpg")

        let first = try await sandbox.convert(source, to: .jpg)
        let second = try await sandbox.convert(source, to: .jpg)

        #expect(first.first?.lastPathComponent == "image 2.jpg")
        #expect(second.first?.lastPathComponent == "image 3.jpg")
        #expect(try String(contentsOf: original, encoding: .utf8) == "keep me")
    }

    @Test func `parallel jobs wanting one name each get their own`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.png()
        let names = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let outputs = try await sandbox.convert(source, to: .jpg)
                    return try #require(outputs.first).lastPathComponent
                }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(names.count == 8)
    }

    @Test func `a failure leaves nothing behind`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("not an image", to: "broken.png")
        _ = try? await sandbox.convert(source, to: .jpg)
        #expect(try sandbox.files() == ["broken.png"])
    }

    @Test func `odd file names work`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.write("hello", to: "-odd name (1) é'\"$.txt")
        let output = try #require(try await sandbox.convert(source, to: .html).first)
        #expect(output.lastPathComponent == "-odd name (1) é'\"$.html")
    }
}

@Suite struct RoutingTests {
    private let plain = EngineRegistry(tools: [:])
    private let full = EngineRegistry(tools: [
        .ffmpeg: URL(filePath: "/fake/ffmpeg"),
        .pandoc: URL(filePath: "/fake/pandoc"),
        .libreOffice: URL(filePath: "/fake/soffice"),
        .imageMagick: URL(filePath: "/fake/magick"),
    ])

    @Test func `no target is offered equal to an audio or document source`() {
        for format in Format.all where format.category == .audio || format.category == .document {
            #expect(!plain.routes(from: format).contains(format))
            #expect(!full.routes(from: format).contains(format))
        }
    }

    @Test func `without tools, MKV points to FFmpeg`() {
        #expect(plain.routes(from: .mkv).isEmpty)
        #expect(plain.missingTool(for: .mkv) == .ffmpeg)
        #expect(plain.missingTool(for: .xlsx) == .libreOffice)
        #expect(plain.missingTool(for: .epub) == .pandoc)
        #expect(plain.missingTool(for: .svg) == .imageMagick)
    }

    @Test func `MP3 can only be written with FFmpeg`() {
        #expect(!plain.routes(from: .wav).contains(.mp3))
        #expect(full.routes(from: .wav).contains(.mp3))
    }

    @Test func `built-in engines win for media, tools win for office files`() {
        #expect(full.engine(from: .mp4, to: .mov) is VideoEngine)
        #expect(full.engine(from: .wav, to: .m4a) is AudioEngine)
        #expect(full.engine(from: .mkv, to: .mp4) is FFmpegEngine)
        #expect(full.engine(from: .png, to: .jpg) is ImageEngine)
        #expect(full.engine(from: .png, to: .webp) is ImageMagickEngine)
        #expect(full.engine(from: .docx, to: .pdf) is LibreOfficeEngine)
        #expect(full.engine(from: .md, to: .docx) is PandocEngine)
        #expect(full.engine(from: .md, to: .pdf) is TextEngine)
        #expect(plain.engine(from: .docx, to: .pdf) is TextEngine)
    }

    @Test func `FFmpeg arguments scale, encode and report progress`() {
        var options = ConversionOptions()
        options.videoPreset = .hdH264
        let arguments = FFmpegEngine.arguments(
            source: URL(filePath: "/a b/in.mkv"),
            target: .mp4,
            output: URL(filePath: "/out/in.mp4"),
            options: options
        )
        #expect(arguments.contains("/a b/in.mkv"))
        #expect(arguments.last == "/out/in.mp4")
        #expect(arguments.contains("libx264"))
        #expect(arguments.contains("scale=-2:'min(720,trunc(ih/2)*2)'"))
        #expect(arguments.contains("pipe:1"))
    }

    @Test func `extensions are recognised in any case and by alias`() {
        #expect(Format.detect(URL(filePath: "/x/A.JPEG")) == .jpg)
        #expect(Format.detect(URL(filePath: "/x/a.Mp4")) == .mp4)
        #expect(Format.detect(URL(filePath: "/x/a.htm")) == .html)
        #expect(Format.detect(URL(filePath: "/x/a.zzz")) == nil)
    }
}

extension MediaTests { @Suite @MainActor struct QueueTests {
    private func makeQueue() -> ConversionQueue {
        let name = "iConvertTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ConversionQueue(defaults: defaults)
    }

    @Test func `folders expand recursively, skipping hidden and unknown files`() async throws {
        let sandbox = try Sandbox()
        let nested = sandbox.url("album/inner")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try sandbox.png("album/a.png")
        _ = try sandbox.png("album/inner/b.png")
        _ = try sandbox.write("x", to: "album/.hidden.png")
        _ = try sandbox.write("x", to: "album/notes.zzz")

        let queue = makeQueue()
        await queue.addAndWait([sandbox.url("album")])
        #expect(queue.items.map(\.url.lastPathComponent) == ["a.png", "b.png"])
    }

    @Test func `the same file is not added twice`() async throws {
        let sandbox = try Sandbox()
        let source = try sandbox.png()
        let queue = makeQueue()
        await queue.addAndWait([source, source])
        await queue.addAndWait([source])
        #expect(queue.items.count == 1)
    }

    @Test func `an unknown file named directly stays, marked as unsupported`() async throws {
        let sandbox = try Sandbox()
        let queue = makeQueue()
        await queue.addAndWait([try sandbox.write("x", to: "data.zzz")])
        #expect(queue.items.first?.routes.isEmpty == true)
        #expect(queue.runnableCount == 0)
    }

    @Test func `a row's own choice beats its category's`() async throws {
        let sandbox = try Sandbox()
        let queue = makeQueue()
        await queue.addAndWait([try sandbox.png("a.png"), try sandbox.png("b.png")])
        let first = queue.items[0]
        let second = queue.items[1]

        queue.setTarget(.heic, for: first)
        queue.setSharedTarget(.tiff, for: .image)
        #expect(queue.target(for: second) == .tiff)
        #expect(queue.target(for: first) == .tiff, "Choosing for the whole category replaces earlier row choices")

        queue.setTarget(.heic, for: first)
        #expect(queue.target(for: first) == .heic)
        #expect(queue.target(for: second) == .tiff)
    }

    @Test func `a mixed batch converts end to end, each next to its original`() async throws {
        let sandbox = try Sandbox()
        let queue = makeQueue()
        let image = try sandbox.png()
        let tone = try sandbox.tone()
        let note = try sandbox.write("# Hello", to: "note.md")
        let movie = try await sandbox.movie()
        let broken = try sandbox.write("nope", to: "broken.jpg")
        await queue.addAndWait([image, tone, note, movie, broken])

        await queue.startAndWait()

        let done = queue.items.filter(\.isDone)
        #expect(done.count == 4)
        #expect(queue.items.first { $0.url.lastPathComponent == "broken.jpg" }.map { !$0.isDone } == true)
        #expect(FileManager.default.fileExists(atPath: sandbox.url("image.jpg").path))
        #expect(FileManager.default.fileExists(atPath: sandbox.url("tone.m4a").path))
        #expect(FileManager.default.fileExists(atPath: sandbox.url("note.pdf").path))
        #expect(FileManager.default.fileExists(atPath: sandbox.url("movie.mp4").path))
        #expect(queue.runnableCount == 1, "The failure stays available to retry")
    }

    @Test func `a chosen folder receives the output`() async throws {
        let sandbox = try Sandbox()
        let out = sandbox.url("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let queue = makeQueue()
        queue.destination = .folder(out)
        await queue.addAndWait([try sandbox.png()])
        await queue.startAndWait()
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "image.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.url("image.jpg").path))
    }

    @Test func `many media files through the real queue finish without stalling`() async throws {
        let sandbox = try Sandbox()
        let queue = makeQueue()
        var sources: [URL] = []
        for index in 0..<12 { sources.append(try sandbox.tone("t\(index).wav", seconds: 3)) }
        for index in 0..<6 { sources.append(try await sandbox.movie("m\(index).mov")) }
        await queue.addAndWait(sources)
        await queue.startAndWait()
        #expect(queue.items.filter(\.isDone).count == 18)
    }

    @Test func `every target of a mixed batch also runs when a video goes to audio`() async throws {
        let sandbox = try Sandbox()
        let queue = makeQueue()
        await queue.addAndWait([try await sandbox.movie()])
        queue.setTarget(.flac, for: queue.items[0])
        await queue.startAndWait()
        #expect(FileManager.default.fileExists(atPath: sandbox.url("movie.flac").path))
    }

    @Test func `cancelling leaves nothing behind and throws`() async throws {
        let sandbox = try Sandbox()
        let source = try await sandbox.movie()
        let before = try sandbox.files()
        let task = Task { try await sandbox.convert(source, to: .mp4) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try sandbox.files() == before)
    }

    @Test func `stopping returns unfinished files to pending`() async throws {
        let sandbox = try Sandbox()
        let queue = makeQueue()
        var sources: [URL] = []
        for index in 0..<6 { sources.append(try sandbox.tone("t\(index).wav", seconds: 20)) }
        await queue.addAndWait(sources)
        queue.start()
        queue.stop()
        while queue.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(queue.items.allSatisfy { !$0.isRunning })
        #expect(queue.items.contains { !$0.isDone })
        #expect(queue.items.allSatisfy { if case .failed = $0.status { false } else { true } })
    }
}
}
