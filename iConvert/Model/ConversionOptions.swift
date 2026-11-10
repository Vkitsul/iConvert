import AVFoundation

/// One choice for size and codec together. macOS has no native HEVC export below 1080p,
/// so a single list leaves no way to pick a combination that can't be produced.
nonisolated enum VideoPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case originalH264, originalHEVC, uhdH264, uhdHEVC, fullHDH264, fullHDHEVC, hdH264, qhdH264, sdH264

    var id: String { rawValue }

    var title: String {
        switch self {
        case .originalH264: "Originale · H.264"
        case .originalHEVC: "Originale · HEVC"
        case .uhdH264: "4K · H.264"
        case .uhdHEVC: "4K · HEVC"
        case .fullHDH264: "1080p · H.264"
        case .fullHDHEVC: "1080p · HEVC"
        case .hdH264: "720p · H.264"
        case .qhdH264: "540p · H.264"
        case .sdH264: "480p · H.264"
        }
    }

    var exportPreset: String {
        switch self {
        case .originalH264: AVAssetExportPresetHighestQuality
        case .originalHEVC: AVAssetExportPresetHEVCHighestQuality
        case .uhdH264: AVAssetExportPreset3840x2160
        case .uhdHEVC: AVAssetExportPresetHEVC3840x2160
        case .fullHDH264: AVAssetExportPreset1920x1080
        case .fullHDHEVC: AVAssetExportPresetHEVC1920x1080
        case .hdH264: AVAssetExportPreset1280x720
        case .qhdH264: AVAssetExportPreset960x540
        case .sdH264: AVAssetExportPreset640x480
        }
    }

    /// `nil` keeps the source size.
    var maxHeight: Int? {
        switch self {
        case .originalH264, .originalHEVC: nil
        case .uhdH264, .uhdHEVC: 2160
        case .fullHDH264, .fullHDHEVC: 1080
        case .hdH264: 720
        case .qhdH264: 540
        case .sdH264: 480
        }
    }

    var usesHEVC: Bool {
        switch self {
        case .originalHEVC, .uhdHEVC, .fullHDHEVC: true
        default: false
        }
    }
}

nonisolated struct ConversionOptions: Codable, Sendable, Equatable {
    var videoPreset: VideoPreset = .originalH264
    /// Kilobits per second, for lossy audio targets.
    var audioBitrate: Int = 256
    /// 0...1, for lossy image targets.
    var imageQuality: Double = 0.85
    /// Longest edge in pixels. `nil` keeps the source size.
    var imageMaxDimension: Int?

    static let audioBitrates = [128, 192, 256, 320]
    static let imageDimensions = [4096, 2560, 1920, 1280, 640]
}

nonisolated enum ConversionError: LocalizedError, Equatable {
    case noRoute
    case noVideoTrack
    case noAudioTrack
    case unreadableFile
    case passwordProtected
    case noExtractableText
    case incompatiblePreset
    case emptyOutput
    case encoderRejected
    case toolFailed(tool: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .noRoute: "Questa conversione non è disponibile."
        case .noVideoTrack: "Il file non contiene video."
        case .noAudioTrack: "Il file non contiene audio."
        case .unreadableFile: "Il file è danneggiato o non si può leggere."
        case .passwordProtected: "Il PDF è protetto da password."
        case .noExtractableText: "Il PDF non contiene testo: probabilmente è una scansione."
        case .incompatiblePreset: "Questa qualità non è compatibile con il formato scelto."
        case .emptyOutput: "La conversione non ha prodotto alcun file."
        case .encoderRejected: "macOS non riesce a creare questo formato partendo da questo audio."
        case let .toolFailed(tool, detail):
            detail.isEmpty ? "\(tool) ha restituito un errore." : "\(tool): \(detail)"
        }
    }
}
