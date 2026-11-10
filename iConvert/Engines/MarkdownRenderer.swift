import Foundation

/// Markdown to HTML, using Foundation's parser so no dependency is needed.
nonisolated enum MarkdownRenderer {
    static func html(from markdown: String, title: String) throws -> String {
        let parsed = try AttributedString(
            markdown: markdown,
            options: .init(allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        )
        var body = ""
        // Blocks currently open, outermost first.
        var open: [PresentationIntent.IntentType] = []

        for run in parsed.runs {
            let blocks = Array((run.presentationIntent?.components ?? []).reversed())
            let shared = zip(open, blocks).prefix { $0.identity == $1.identity }.count

            for block in open[shared...].reversed() { body += closingTag(block.kind) }
            for block in blocks[shared...] { body += openingTag(block.kind) }
            open = blocks

            body += inlineHTML(for: run, text: String(parsed[run.range].characters))
        }
        for block in open.reversed() { body += closingTag(block.kind) }

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title></head>
        <body>
        \(body)
        </body></html>
        """
    }

    private static func openingTag(_ kind: PresentationIntent.Kind) -> String {
        switch kind {
        case .paragraph: "<p>"
        case let .header(level): "<h\(level)>"
        case .orderedList: "<ol>\n"
        case .unorderedList: "<ul>\n"
        case .listItem: "<li>"
        case .codeBlock: "<pre><code>"
        case .blockQuote: "<blockquote>\n"
        case .thematicBreak: "<hr>"
        case .table: "<table>\n"
        case .tableHeaderRow, .tableRow: "<tr>"
        case .tableCell: "<td>"
        @unknown default: ""
        }
    }

    private static func closingTag(_ kind: PresentationIntent.Kind) -> String {
        switch kind {
        case .paragraph: "</p>\n"
        case let .header(level): "</h\(level)>\n"
        case .orderedList: "</ol>\n"
        case .unorderedList: "</ul>\n"
        case .listItem: "</li>\n"
        case .codeBlock: "</code></pre>\n"
        case .blockQuote: "</blockquote>\n"
        case .thematicBreak: "\n"
        case .table: "</table>\n"
        case .tableHeaderRow, .tableRow: "</tr>\n"
        case .tableCell: "</td>"
        @unknown default: ""
        }
    }

    private static func inlineHTML(for run: AttributedString.Runs.Run, text: String) -> String {
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.softBreak) { return "\n" }
        if intent.contains(.lineBreak) { return "<br>\n" }

        var html = escape(text)
        if intent.contains(.code) { html = "<code>\(html)</code>" }
        if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
        if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
        if intent.contains(.strikethrough) { html = "<s>\(html)</s>" }
        if let link = run.link { html = "<a href=\"\(escape(link.absoluteString))\">\(html)</a>" }
        return html
    }

    private static func escape(_ text: String) -> String {
        text.replacing("&", with: "&amp;")
            .replacing("<", with: "&lt;")
            .replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;")
    }
}
