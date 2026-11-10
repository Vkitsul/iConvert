import AppKit
import CoreText
import PDFKit

/// Documents through `textutil`, which ships with macOS. Markdown is rendered to HTML first,
/// and PDF is reduced to its text first, so both reuse the same conversions.
/// Images inside documents don't survive this route; LibreOffice keeps them when installed.
nonisolated struct TextEngine: ConversionEngine {
    private static let textutil = URL(filePath: "/usr/bin/textutil")
    private static let readable: Set<Format> = [.txt, .md, .html, .rtf, .doc, .docx, .odt, .pdf]
    private static let writable: Set<Format> = [.txt, .html, .rtf, .doc, .docx, .odt, .pdf]
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let pageMargin: CGFloat = 56

    func targets(from source: Format) -> Set<Format> {
        guard Self.readable.contains(source) else { return [] }
        return Self.writable.subtracting([source])
    }

    func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let input = try intermediateInput(for: job)
        progress(0.3)

        if job.target == .pdf {
            let rtf = job.workDirectory.appending(path: "intermediate-render.rtf")
            try await runTextutil(input: input, format: "rtf", output: rtf)
            progress(0.7)
            try writePDF(fromRTF: rtf, to: job.primaryOutput)
        } else if input.isGenerated, input.format == job.target {
            try FileManager.default.moveItem(at: input.url, to: job.primaryOutput)
        } else {
            try await runTextutil(input: input, format: job.target.id, output: job.primaryOutput)
        }
        progress(1)
        return [job.primaryOutput]
    }

    private struct Input {
        let url: URL
        let format: Format
        var isGenerated = false
    }

    private func intermediateInput(for job: ConversionJob) throws -> Input {
        switch job.sourceFormat {
        case .md:
            let markdown = try Self.readText(job.source)
            let html = try MarkdownRenderer.html(from: markdown, title: job.baseName)
            let url = job.workDirectory.appending(path: "intermediate-source.html")
            try html.write(to: url, atomically: true, encoding: .utf8)
            return Input(url: url, format: .html, isGenerated: true)
        case .pdf:
            let url = job.workDirectory.appending(path: "intermediate-source.txt")
            try Self.extractText(fromPDF: job.source).write(to: url, atomically: true, encoding: .utf8)
            return Input(url: url, format: .txt, isGenerated: true)
        default:
            return Input(url: job.source, format: job.sourceFormat)
        }
    }

    private func runTextutil(input: Input, format: String, output: URL) async throws {
        var arguments = ["-convert", format, "-noload", "-output", output.path]
        if input.format == .txt, input.isGenerated || (try? String(contentsOf: input.url, encoding: .utf8)) != nil {
            arguments += ["-inputencoding", "UTF-8"]
        }
        if format == "txt" || format == "html" {
            arguments += ["-encoding", "UTF-8"]
        }
        arguments.append(input.url.path)
        try await ProcessRunner.run(Self.textutil, arguments, toolName: "textutil")
    }

    private static func readText(_ url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    private static func extractText(fromPDF url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else { throw ConversionError.unreadableFile }
        guard !document.isLocked else { throw ConversionError.passwordProtected }
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.noExtractableText
        }
        return text
    }

    /// Lays styled text out on A4 pages.
    private func writePDF(fromRTF rtf: URL, to output: URL) throws {
        let loaded = try NSMutableAttributedString(
            url: rtf,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        // Core Text reads its own colour attribute and ignores AppKit's.
        let whole = NSRange(location: 0, length: loaded.length)
        loaded.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if let color = (value as? NSColor)?.usingColorSpace(.sRGB)?.cgColor {
                loaded.addAttribute(kCTForegroundColorAttributeName as NSAttributedString.Key, value: color, range: range)
            }
        }

        var pageBounds = CGRect(origin: .zero, size: Self.pageSize)
        guard let context = CGContext(output as CFURL, mediaBox: &pageBounds, nil) else {
            throw ConversionError.emptyOutput
        }
        let framesetter = CTFramesetterCreateWithAttributedString(loaded)
        let path = CGPath(rect: pageBounds.insetBy(dx: Self.pageMargin, dy: Self.pageMargin), transform: nil)

        var position = 0
        repeat {
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame).length
            guard visible > 0 else { break }
            position += visible
        } while position < loaded.length
        context.closePDF()
    }
}
