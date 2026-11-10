import Foundation
import UniformTypeIdentifiers

nonisolated enum FormatCategory: String, CaseIterable, Identifiable, Sendable, Codable {
    case video, audio, image, document

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Images"
        case .document: "Documents"
        }
    }
}

/// A file format the app knows by name. `id` is the extension written on output.
nonisolated struct Format: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let category: FormatCategory
    var aliases: [String] = []

    var utType: UTType? { UTType(filenameExtension: id) }

    /// Formats that throw away detail on encode, so a bitrate or quality setting means something.
    var isLossy: Bool {
        [Format.mp3, .m4a, .aac, .ogg, .opus, .jpg, .heic, .avif, .jp2, .webp].contains(self)
    }
}

nonisolated extension Format {
    // Video
    static let mp4 = Format(id: "mp4", name: "MP4", category: .video)
    static let mov = Format(id: "mov", name: "MOV", category: .video, aliases: ["qt"])
    static let m4v = Format(id: "m4v", name: "M4V", category: .video)
    static let mkv = Format(id: "mkv", name: "MKV", category: .video)
    static let webm = Format(id: "webm", name: "WebM", category: .video)
    static let avi = Format(id: "avi", name: "AVI", category: .video)
    static let mpg = Format(id: "mpg", name: "MPEG", category: .video, aliases: ["mpeg"])
    static let wmv = Format(id: "wmv", name: "WMV", category: .video)
    static let flv = Format(id: "flv", name: "FLV", category: .video)
    static let threeGP = Format(id: "3gp", name: "3GP", category: .video)

    // Audio
    static let mp3 = Format(id: "mp3", name: "MP3", category: .audio)
    static let m4a = Format(id: "m4a", name: "M4A (AAC)", category: .audio)
    static let aac = Format(id: "aac", name: "AAC", category: .audio)
    static let wav = Format(id: "wav", name: "WAV", category: .audio)
    static let aiff = Format(id: "aiff", name: "AIFF", category: .audio, aliases: ["aif"])
    static let flac = Format(id: "flac", name: "FLAC", category: .audio)
    static let caf = Format(id: "caf", name: "CAF (Apple Lossless)", category: .audio)
    static let ogg = Format(id: "ogg", name: "OGG", category: .audio, aliases: ["oga"])
    static let opus = Format(id: "opus", name: "Opus", category: .audio)
    static let wma = Format(id: "wma", name: "WMA", category: .audio)

    // Images
    static let jpg = Format(id: "jpg", name: "JPEG", category: .image, aliases: ["jpeg", "jpe"])
    static let png = Format(id: "png", name: "PNG", category: .image)
    static let heic = Format(id: "heic", name: "HEIC", category: .image, aliases: ["heif"])
    static let tiff = Format(id: "tiff", name: "TIFF", category: .image, aliases: ["tif"])
    static let gif = Format(id: "gif", name: "GIF", category: .image)
    static let bmp = Format(id: "bmp", name: "BMP", category: .image)
    static let webp = Format(id: "webp", name: "WebP", category: .image)
    static let avif = Format(id: "avif", name: "AVIF", category: .image)
    static let jp2 = Format(id: "jp2", name: "JPEG 2000", category: .image)
    static let ico = Format(id: "ico", name: "ICO", category: .image)
    static let tga = Format(id: "tga", name: "TGA", category: .image)
    static let psd = Format(id: "psd", name: "PSD", category: .image)
    static let jxl = Format(id: "jxl", name: "JPEG XL", category: .image)
    static let svg = Format(id: "svg", name: "SVG", category: .image)
    static let dng = Format(id: "dng", name: "RAW DNG", category: .image)
    static let cr2 = Format(id: "cr2", name: "RAW Canon CR2", category: .image)
    static let cr3 = Format(id: "cr3", name: "RAW Canon CR3", category: .image)
    static let nef = Format(id: "nef", name: "RAW Nikon NEF", category: .image)
    static let arw = Format(id: "arw", name: "RAW Sony ARW", category: .image)

    // Documents
    static let pdf = Format(id: "pdf", name: "PDF", category: .document)
    static let docx = Format(id: "docx", name: "Word (DOCX)", category: .document)
    static let doc = Format(id: "doc", name: "Word 97 (DOC)", category: .document)
    static let odt = Format(id: "odt", name: "OpenDocument (ODT)", category: .document)
    static let rtf = Format(id: "rtf", name: "RTF", category: .document)
    static let html = Format(id: "html", name: "HTML", category: .document, aliases: ["htm"])
    static let txt = Format(id: "txt", name: "Plain Text (TXT)", category: .document, aliases: ["text"])
    static let md = Format(id: "md", name: "Markdown", category: .document, aliases: ["markdown", "mdown"])
    static let epub = Format(id: "epub", name: "EPUB", category: .document)
    static let tex = Format(id: "tex", name: "LaTeX", category: .document)
    static let xlsx = Format(id: "xlsx", name: "Excel (XLSX)", category: .document)
    static let xls = Format(id: "xls", name: "Excel 97 (XLS)", category: .document)
    static let ods = Format(id: "ods", name: "OpenDocument (ODS)", category: .document)
    static let csv = Format(id: "csv", name: "CSV", category: .document)
    static let pptx = Format(id: "pptx", name: "PowerPoint (PPTX)", category: .document)
    static let ppt = Format(id: "ppt", name: "PowerPoint 97 (PPT)", category: .document)
    static let odp = Format(id: "odp", name: "OpenDocument (ODP)", category: .document)

    /// Every known format, in the order menus present them.
    static let all: [Format] = [
        .mp4, .mov, .m4v, .mkv, .webm, .avi, .mpg, .wmv, .flv, .threeGP,
        .mp3, .m4a, .aac, .wav, .aiff, .flac, .caf, .ogg, .opus, .wma,
        .jpg, .png, .heic, .tiff, .gif, .bmp, .webp, .avif, .jp2, .ico, .tga, .psd,
        .jxl, .svg, .dng, .cr2, .cr3, .nef, .arw,
        .pdf, .docx, .doc, .odt, .rtf, .html, .txt, .md, .epub, .tex,
        .xlsx, .xls, .ods, .csv, .pptx, .ppt, .odp,
    ]

    private static let byExtension: [String: Format] = {
        var table: [String: Format] = [:]
        for format in all {
            table[format.id] = format
            for alias in format.aliases { table[alias] = format }
        }
        return table
    }()

    static func detect(_ url: URL) -> Format? {
        byExtension[url.pathExtension.lowercased()]
    }

    static func withID(_ id: String) -> Format? {
        byExtension[id]
    }
}
