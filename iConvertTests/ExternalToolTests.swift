import AVFoundation
import PDFKit
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import iConvert

private let tools = ExternalTool.locateAll()
private let registry = EngineRegistry(tools: tools)

extension Sandbox {
    /// Runs through the same routing the app uses with every tool installed.
    func convertWithTools(
        _ source: URL,
        to target: Format,
        options: ConversionOptions = ConversionOptions(),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard let format = Format.detect(source),
              let engine = registry.engine(from: format, to: target)
        else { throw ConversionError.noRoute }
        let outputs = try await ConversionRunner.run(
            source: source, sourceFormat: format, target: target, options: options,
            engine: engine, destination: nil, progress: progress
        )
        return try #require(outputs.first)
    }

    /// Builds a source file in a format the app can't write without the tool under test.
    func ffmpegFile(_ name: String, arguments: [String]) async throws -> URL {
        let url = url(name)
        try await ProcessRunner.run(
            try #require(tools[.ffmpeg]),
            ["-hide_banner", "-loglevel", "error", "-y"] + arguments + [url.path],
            toolName: "FFmpeg fixture"
        )
        return url
    }

    func testVideo(_ name: String, size: String = "640x360", extra: [String] = []) async throws -> URL {
        try await ffmpegFile(name, arguments: [
            "-f", "lavfi", "-i", "testsrc=size=\(size):rate=15:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
        ] + extra)
    }
}

/// Stream facts as ffprobe sees them, an independent check that the output is what it claims.
private func probe(_ url: URL, stream: String) async throws -> [String: String] {
    let ffprobe = try #require(tools[.ffmpeg]).deletingLastPathComponent().appending(path: "ffprobe")
    let output = try await ProcessRunner.run(ffprobe, [
        "-v", "error", "-select_streams", stream,
        "-show_entries", "stream=codec_name,width,height", "-of", "default=noprint_wrappers=1", url.path,
    ], toolName: "ffprobe")
    return output.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
        let parts = line.split(separator: "=", maxSplits: 1)
        if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
    }
}

private func pdfText(_ url: URL) throws -> String {
    try #require(PDFDocument(url: url)?.string)
}

private func text(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

extension MediaTests {
    @Suite(.enabled(if: tools[.ffmpeg] != nil)) struct FFmpegTests {
        @Test(arguments: [
            (Format.mp3, "mp3"), (.aac, "aac"), (.ogg, "opus"), (.opus, "opus"),
        ])
        func `audio reaches the formats macOS can't write`(target: Format, codec: String) async throws {
            let sandbox = try Sandbox()
            let output = try await sandbox.convertWithTools(try sandbox.tone(), to: target)
            #expect(output.pathExtension == target.id)
            #expect(try await probe(output, stream: "a:0")["codec_name"] == codec)
        }

        @Test(arguments: ConversionOptions.audioBitrates)
        func `the chosen MP3 bitrate is honoured`(kbps: Int) async throws {
            let sandbox = try Sandbox()
            var options = ConversionOptions()
            options.audioBitrate = kbps
            let output = try await sandbox.convertWithTools(try sandbox.tone(seconds: 4), to: .mp3, options: options)
            let bytes = try #require(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            let measured = Double(bytes) * 8 / 4 / 1000
            #expect(abs(measured - Double(kbps)) < Double(kbps) * 0.2)
        }

        @Test func `a mono voice memo becomes an MP3 at any setting`() async throws {
            let sandbox = try Sandbox()
            var options = ConversionOptions()
            options.audioBitrate = 320
            let source = try sandbox.tone(sampleRate: 22_050, channels: 1)
            let output = try await sandbox.convertWithTools(source, to: .mp3, options: options)
            #expect(try await probe(output, stream: "a:0")["codec_name"] == "mp3")
        }

        @Test func `audio is taken out of a video as MP3`() async throws {
            let sandbox = try Sandbox()
            let output = try await sandbox.convertWithTools(try await sandbox.movie(), to: .mp3)
            #expect(try await probe(output, stream: "a:0")["codec_name"] == "mp3")
            #expect(try await probe(output, stream: "v").isEmpty)
        }

        @Test(arguments: [
            (Format.mkv, "h264", "aac"), (.webm, "vp9", "opus"), (.avi, "mpeg4", "mp3"),
        ])
        func `video reaches the containers macOS can't write`(target: Format, video: String, audio: String) async throws {
            let sandbox = try Sandbox()
            let output = try await sandbox.convertWithTools(try await sandbox.movie(), to: target)
            #expect(try await probe(output, stream: "v:0")["codec_name"] == video)
            #expect(try await probe(output, stream: "a:0")["codec_name"] == audio)
        }

        @Test(arguments: ["in.mkv", "in.webm", "in.avi", "in.flv", "in.wmv", "in.mpg"])
        func `formats macOS can't read become a playable MP4`(name: String) async throws {
            let sandbox = try Sandbox()
            // MPEG only allows standard frame rates.
            let source = try await sandbox.testVideo(name, extra: name.hasSuffix("mpg") ? ["-r", "25"] : [])
            let output = try await sandbox.convertWithTools(source, to: .mp4)
            let asset = AVURLAsset(url: output)
            #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)
            #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
        }

        @Test func `an MKV can give up just its audio`() async throws {
            let sandbox = try Sandbox()
            let output = try await sandbox.convertWithTools(try await sandbox.testVideo("in.mkv"), to: .wav)
            #expect(try await probe(output, stream: "a:0")["codec_name"] == "pcm_s16le")
        }

        @Test func `an odd sized video still encodes`() async throws {
            let sandbox = try Sandbox()
            let source = try await sandbox.testVideo("odd.mkv", size: "641x361", extra: ["-c:v", "ffv1"])
            let facts = try await probe(try await sandbox.convertWithTools(source, to: .mp4), stream: "v:0")
            #expect(facts["width"] == "640")
            #expect(facts["height"] == "360")
        }

        @Test func `the size presets shrink and never enlarge`() async throws {
            let sandbox = try Sandbox()
            var options = ConversionOptions()
            options.videoPreset = .hdH264
            let small = try await sandbox.testVideo("small.mkv", size: "640x360")
            let large = try await sandbox.testVideo("large.mkv", size: "1920x1080")
            let smallOut = try await probe(try await sandbox.convertWithTools(small, to: .webm, options: options), stream: "v:0")
            let largeOut = try await probe(try await sandbox.convertWithTools(large, to: .webm, options: options), stream: "v:0")
            #expect(smallOut["height"] == "360")
            #expect(largeOut["height"] == "720")
        }

        @Test func `HEVC is written when chosen`() async throws {
            let sandbox = try Sandbox()
            var options = ConversionOptions()
            options.videoPreset = .originalHEVC
            let source = try await sandbox.testVideo("in.mkv")
            let output = try await sandbox.convertWithTools(source, to: .mkv, options: options)
            #expect(try await probe(output, stream: "v:0")["codec_name"] == "hevc")
        }

        @Test func `an animated GIF becomes a video`() async throws {
            let sandbox = try Sandbox()
            let output = try await sandbox.convertWithTools(try sandbox.animatedGIF(), to: .mp4)
            #expect(try await probe(output, stream: "v:0")["codec_name"] == "h264")
        }

        @Test func `an MKV becomes a GIF`() async throws {
            let sandbox = try Sandbox()
            let output = try await sandbox.convertWithTools(try await sandbox.testVideo("in.mkv"), to: .gif)
            #expect(CGImageSourceGetCount(try #require(imageSource(output))) > 5)
        }

        @Test func `progress is reported as it runs`() async throws {
            let sandbox = try Sandbox()
            let seen = Mutex<[Double]>([])
            let source = try await sandbox.testVideo("in.mkv", size: "1280x720")
            _ = try await sandbox.convertWithTools(source, to: .webm) { value in
                seen.withLock { $0.append(value) }
            }
            let values = seen.withLock { $0 }
            #expect(!values.isEmpty)
            #expect(values.allSatisfy { (0...1).contains($0) })
            #expect((values.last ?? 0) > 0.5)
        }

        @Test func `cancelling stops FFmpeg and leaves nothing behind`() async throws {
            let sandbox = try Sandbox()
            let source = try await sandbox.ffmpegFile("long.mkv", arguments: [
                "-f", "lavfi", "-i", "testsrc=size=1920x1080:rate=30:duration=30", "-c:v", "libx264", "-preset", "ultrafast",
            ])
            let before = try sandbox.files()
            let task = Task { try await sandbox.convertWithTools(source, to: .webm) }
            try await Task.sleep(for: .seconds(1))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try sandbox.files() == before)
            let running = try await ProcessRunner.run(URL(filePath: "/bin/sh"), ["-c", "pgrep -f '\(source.path)' || true"], toolName: "pgrep")
            #expect(running.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        @Test func `a corrupt file gives a readable error`() async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.write("non è un video", to: "broken.mkv")
            do {
                _ = try await sandbox.convertWithTools(source, to: .mp4)
                Issue.record("Expected a failure")
            } catch let ConversionError.toolFailed(tool, detail) {
                #expect(tool == "FFmpeg")
                #expect(!detail.isEmpty)
            }
            #expect(try sandbox.files() == ["broken.mkv"])
        }

        @Test func `a video without audio can't become an MP3`() async throws {
            let sandbox = try Sandbox()
            let source = try await sandbox.ffmpegFile("mute.mkv", arguments: ["-f", "lavfi", "-i", "testsrc=duration=1"])
            await #expect(throws: ConversionError.self) {
                _ = try await sandbox.convertWithTools(source, to: .mp3)
            }
        }

        @Test(arguments: ["sp azi è'\"$ (1).mkv", "-trattino.mkv", "cento%d [1].mkv"])
        func `odd file names reach FFmpeg intact`(name: String) async throws {
            let sandbox = try Sandbox()
            let source = try await sandbox.testVideo("plain.mkv")
            let renamed = sandbox.url(name)
            try FileManager.default.moveItem(at: source, to: renamed)
            let output = try await sandbox.convertWithTools(renamed, to: .mp3)
            #expect(output.deletingPathExtension().lastPathComponent == renamed.deletingPathExtension().lastPathComponent)
        }
    }

    @Suite(.enabled(if: tools[.pandoc] != nil)) struct PandocTests {
        private static let markdown = "# Titolo perché\n\nUn **paragrafo** con accenti.\n\n- primo\n- secondo\n"

        @Test(arguments: [Format.docx, .html, .epub, .tex, .odt, .rtf, .txt])
        func `Markdown converts and the words survive`(target: Format) async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.write(Self.markdown, to: "note.md")
            let output = try await sandbox.convertWithTools(source, to: target)
            #expect(output.lastPathComponent == "note.\(target.id)")
            let back = try await sandbox.convertWithTools(output, to: target == .md ? .html : .md)
            #expect(try text(back).contains("paragrafo"))
        }

        @Test(arguments: [Format.docx, .html, .epub, .odt, .tex])
        func `other formats convert back to Markdown`(via: Format) async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.write(Self.markdown, to: "note.md")
            let middle = try await sandbox.convertWithTools(source, to: via)
            let output = try await sandbox.convertWithTools(middle, to: .md)
            let result = try text(output)
            #expect(result.contains("perché"))
            #expect(result.contains("**paragrafo**") || result.contains("__paragrafo__"))
        }

        @Test func `an image beside the Markdown file lands inside the DOCX`() async throws {
            let sandbox = try Sandbox()
            _ = try sandbox.png("foto.png")
            let source = try sandbox.write("# Con foto\n\n![una foto](foto.png)\n", to: "note.md")
            let plain = try await sandbox.convertWithTools(try sandbox.write("# Senza foto\n", to: "bare.md"), to: .docx)
            let output = try await sandbox.convertWithTools(source, to: .docx)
            let withImage = try #require(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            let without = try #require(try plain.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(withImage > without + 500)
        }

        @Test func `a corrupt DOCX gives a readable error`() async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.write("non è un docx", to: "broken.docx")
            await #expect(throws: ConversionError.self) {
                _ = try await sandbox.convertWithTools(source, to: .md)
            }
        }

        @Test func `odd file names reach Pandoc intact`() async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.write(Self.markdown, to: "-sp azi è'\"$ %d [1].md")
            let output = try await sandbox.convertWithTools(source, to: .docx)
            #expect(output.lastPathComponent == "-sp azi è'\"$ %d [1].docx")
        }
    }

    @Suite(.enabled(if: tools[.libreOffice] != nil)) struct LibreOfficeTests {
        private static let csv = "Nome,Città\nAndrea,Forlì\nNicolò,Cantù\n"

        @Test(arguments: [Format.xlsx, .xls, .ods])
        func `a spreadsheet converts and comes back with accents intact`(target: Format) async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.write(Self.csv, to: "dati.csv")
            let sheet = try await sandbox.convertWithTools(source, to: target)
            let backFolder = sandbox.url("back")
            try FileManager.default.createDirectory(at: backFolder, withIntermediateDirectories: true)
            let copy = backFolder.appending(path: sheet.lastPathComponent)
            try FileManager.default.moveItem(at: sheet, to: copy)
            let back = try await Sandbox.convertInPlace(copy, to: .csv)
            let result = try text(back)
            #expect(result.contains("Forlì"))
            #expect(result.contains("Nicolò"))
        }

        @Test func `an Excel file becomes a PDF`() async throws {
            let sandbox = try Sandbox()
            let xlsx = try await sandbox.convertWithTools(try sandbox.write(Self.csv, to: "dati.csv"), to: .xlsx)
            let pdf = try await sandbox.convertWithTools(xlsx, to: .pdf)
            #expect(try pdfText(pdf).contains("Cantù"))
        }

        @Test func `an Italian CSV separated by semicolons splits into columns`() async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.write("Nome;Città\nAndrea;Forlì\n", to: "dati.csv")
            let ods = try await sandbox.convertWithTools(source, to: .ods)
            let folder = sandbox.url("back")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: ods.lastPathComponent)
            try FileManager.default.moveItem(at: ods, to: copy)
            let back = try await Sandbox.convertInPlace(copy, to: .csv)
            #expect(try text(back).contains("Andrea,Forlì"))
        }

        @Test func `a DOCX with a picture keeps it in the PDF`() async throws {
            let sandbox = try Sandbox()
            _ = try sandbox.png("foto.png", width: 800, height: 400)
            let md = try sandbox.write("# Relazione perché\n\n![foto](foto.png)\n", to: "doc.md")
            let docx = try await sandbox.convertWithTools(md, to: .docx)
            let pdf = try await sandbox.convertWithTools(docx, to: .pdf)
            #expect(try pdfText(pdf).contains("Relazione perché"))
            let withPicture = try #require(try pdf.resourceValues(forKeys: [.fileSizeKey]).fileSize)

            let bareDocx = try await sandbox.convertWithTools(try sandbox.write("# Relazione perché\n", to: "bare.md"), to: .docx)
            let barePDF = try await sandbox.convertWithTools(bareDocx, to: .pdf)
            let bare = try #require(try barePDF.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(withPicture > bare)
        }

        @Test(arguments: [Format.odt, .doc, .rtf])
        func `Word converts to the other word processor formats`(target: Format) async throws {
            let sandbox = try Sandbox()
            let docx = try await sandbox.convertWithTools(try sandbox.write("# Ciao perché\n", to: "doc.md"), to: .docx)
            let output = try await sandbox.convertWithTools(docx, to: target)
            #expect(output.pathExtension == target.id)
        }

        @Test(arguments: [Format.pptx, .ppt, .odp, .pdf])
        func `a presentation converts`(target: Format) async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.flatPresentation()
            let tool = try #require(tools[.libreOffice])
            let profile = sandbox.url("profile")
            try await ProcessRunner.run(tool, [
                "-env:UserInstallation=\(profile.absoluteString)", "--headless", "--convert-to", "pptx",
                "--outdir", sandbox.folder.path, source.path,
            ], toolName: "LibreOffice fixture")
            let pptx = sandbox.url("slides.pptx")

            let folder = sandbox.url("out")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: target == .pptx ? "copia.pptx" : "slides.pptx")
            try FileManager.default.copyItem(at: pptx, to: copy)

            if target == .pptx {
                let odp = try await Sandbox.convertInPlace(copy, to: .odp)
                let output = try await Sandbox.convertInPlace(odp, to: .pptx)
                #expect(output.lastPathComponent.hasSuffix(".pptx"))
            } else {
                let output = try await Sandbox.convertInPlace(copy, to: target)
                #expect(output.pathExtension == target.id)
                if target == .pdf { #expect(try pdfText(output).contains("Diapositiva perché")) }
            }
        }

        @Test func `paths with spaces and accents work, and two can run at once`() async throws {
            let sandbox = try Sandbox()
            let folder = sandbox.url("Cartella con spazi è")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let first = folder.appending(path: "dati uno.csv")
            let second = folder.appending(path: "dati due.csv")
            try Self.csv.write(to: first, atomically: true, encoding: .utf8)
            try Self.csv.write(to: second, atomically: true, encoding: .utf8)
            async let one = Sandbox.convertInPlace(first, to: .pdf)
            async let two = Sandbox.convertInPlace(second, to: .pdf)
            let results = try await [one, two]
            for result in results { #expect(try pdfText(result).contains("Forlì")) }
        }

        @Test func `a corrupt spreadsheet fails instead of hanging`() async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.write("non è un excel", to: "broken.xlsx")
            do {
                let output = try await sandbox.convertWithTools(source, to: .pdf)
                // LibreOffice may read garbage as text, which still has to produce a real PDF.
                #expect(PDFDocument(url: output) != nil)
            } catch {
                #expect(error is ConversionError)
            }
        }
    }

    @Suite(.enabled(if: tools[.imageMagick] != nil)) struct ImageMagickTests {
        private static let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="300" height="150">
        <rect x="150" width="150" height="150" fill="red"/></svg>
        """

        @Test func `a PNG becomes a WebP that macOS can read back`() async throws {
            let sandbox = try Sandbox()
            let output = try await sandbox.convertWithTools(try sandbox.png(), to: .webp)
            #expect(pixelSize(output)?.width == 400)
            #expect(output.pathExtension == "webp")
        }

        @Test func `WebP quality changes the file size`() async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.tiledPNG()
            var low = ConversionOptions()
            low.imageQuality = 0.4
            var high = ConversionOptions()
            high.imageQuality = 1
            let small = try await sandbox.convertWithTools(source, to: .webp, options: low)
            let large = try await sandbox.convertWithTools(source, to: .webp, options: high)
            let smallSize = try #require(try small.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            let largeSize = try #require(try large.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(largeSize > smallSize)
        }

        @Test(arguments: [Format.png, .jpg, .webp, .tiff, .gif, .bmp])
        func `an SVG renders to bitmap formats`(target: Format) async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.write(Self.svg, to: "disegno.svg")
            let output = try await sandbox.convertWithTools(source, to: target)
            #expect(pixelSize(output)?.width == 300)
        }

        @Test func `an SVG's empty background is white in a JPEG`() async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.write(Self.svg, to: "disegno.svg")
            let output = try await sandbox.convertWithTools(source, to: .jpg)
            let cgSource = try #require(imageSource(output))
            let image = try #require(CGImageSourceCreateImageAtIndex(cgSource, 0, nil))
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try #require(CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * 2, height: image.height))
            #expect(pixel[1] > 200, "The left half has no shape, so it must not be black")
        }

        @Test func `the maximum size applies`() async throws {
            let sandbox = try Sandbox()
            var options = ConversionOptions()
            options.imageMaxDimension = 100
            let output = try await sandbox.convertWithTools(try sandbox.png(), to: .webp, options: options)
            #expect(pixelSize(output)?.width == 100)
        }

        @Test(arguments: ["cento%d.png", "foto [1].png", "-sp azi è'\"$.png"])
        func `file names that look like ImageMagick commands stay literal`(name: String) async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.png(name)
            let output = try await sandbox.convertWithTools(source, to: .webp)
            #expect(output.deletingPathExtension().lastPathComponent == source.deletingPathExtension().lastPathComponent)
            #expect(pixelSize(output)?.width == 400)
        }

        @Test func `a corrupt SVG gives a readable error and no file`() async throws {
            let sandbox = try Sandbox()
            let source = try sandbox.write("<svg><non chiuso", to: "broken.svg")
            do {
                _ = try await sandbox.convertWithTools(source, to: .png)
            } catch {
                #expect(error is ConversionError)
            }
            #expect(try sandbox.files().filter { $0.hasPrefix("input") || $0.hasPrefix("output") }.isEmpty)
        }
    }

    @Suite(.enabled(if: tools.count == ExternalTool.allCases.count)) @MainActor struct FullQueueTests {
        @Test func `the queue finds the tools and runs one conversion through each`() async throws {
            let sandbox = try Sandbox()
            let name = "iConvertTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            let queue = ConversionQueue(defaults: defaults)

            let wav = try sandbox.tone()
            let mkv = try await sandbox.testVideo("film.mkv")
            let md = try sandbox.write("# Ciao\n", to: "note.md")
            let csv = try sandbox.write("a,b\n1,2\n", to: "dati.csv")
            let svg = try sandbox.write(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>"#, to: "d.svg")
            await queue.addAndWait([wav, mkv, md, csv, svg])

            func item(_ url: URL) throws -> QueueItem {
                try #require(queue.items.first { $0.url == url.standardizedFileURL })
            }
            queue.setTarget(.mp3, for: try item(wav))
            queue.setTarget(.webm, for: try item(mkv))
            queue.setTarget(.epub, for: try item(md))
            queue.setTarget(.xlsx, for: try item(csv))
            queue.setTarget(.webp, for: try item(svg))

            await queue.startAndWait()

            let failures = queue.items.compactMap { item -> String? in
                if case let .failed(message) = item.status { return "\(item.url.lastPathComponent): \(message)" }
                return nil
            }
            #expect(failures.isEmpty, "\(failures)")
            for file in ["tone.mp3", "film.webm", "note.epub", "dati.xlsx", "d.webp"] {
                #expect(FileManager.default.fileExists(atPath: sandbox.url(file).path), "\(file)")
            }
        }
    }
}

extension Sandbox {
    static func convertInPlace(_ source: URL, to target: Format) async throws -> URL {
        guard let format = Format.detect(source),
              let engine = registry.engine(from: format, to: target)
        else { throw ConversionError.noRoute }
        let outputs = try await ConversionRunner.run(
            source: source, sourceFormat: format, target: target, options: ConversionOptions(),
            engine: engine, destination: nil, progress: { _ in }
        )
        return try #require(outputs.first)
    }

    /// A presentation as Flat ODF, the one Office format simple enough to write by hand.
    func flatPresentation() throws -> URL {
        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
          xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
          xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0"
          office:version="1.2" office:mimetype="application/vnd.oasis.opendocument.presentation">
        <office:body><office:presentation>
        <draw:page draw:name="uno">
        <draw:frame svg:x="2cm" svg:y="2cm" svg:width="20cm" svg:height="5cm">
        <draw:text-box><text:p>Diapositiva perché</text:p></draw:text-box>
        </draw:frame></draw:page>
        </office:presentation></office:body></office:document>
        """, to: "slides.fodp")
    }

    /// Detailed pixels, so lossy quality makes a measurable difference.
    func tiledPNG() throws -> URL {
        let size = 256
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        var generator = SystemRandomNumberGenerator()
        for x in 0..<size {
            for y in 0..<size {
                context.setFillColor(CGColor(
                    srgbRed: .random(in: 0...1, using: &generator),
                    green: .random(in: 0...1, using: &generator),
                    blue: .random(in: 0...1, using: &generator),
                    alpha: 1
                ))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let output = url("tiled.png")
        let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return output
    }
}
