import Foundation
import CoreMedia

/// Where an ingredient's media comes from.
///
/// In memory this keeps the full yt-dlp metadata and stream list. On disk (see `Codable` below)
/// it stores only a small, stable subset, and file locations relative to `AppPaths.root`, so
/// yt-dlp model changes or a moved container never make the library undecodable.
nonisolated enum MediaSource: Sendable {
    case local(url: URL)
    case youtube(metadata: YTDLPMetadata, localURL: URL?, streams: [YouTubeStreamOption])
    
    var localURL: URL? {
        switch self {
        case .local(let url): return url
        case .youtube(_, let url, _): return url
        }
    }

    /// Same source, pointing at a different local file.
    func withLocalURL(_ url: URL) -> MediaSource {
        switch self {
        case .local: return .local(url: url)
        case .youtube(let metadata, _, let streams): return .youtube(metadata: metadata, localURL: url, streams: streams)
        }
    }
}

extension MediaSource: Codable {
    // Current format:
    //   { "kind": "local",   "file": StoredFileReference }
    //   { "kind": "youtube", "file": StoredFileReference?, "youtube": StoredYouTubeSource, "streams": [...] }
    // Legacy (synthesized enum Codable, read only):
    //   { "local":   { "url": "file:///..." } }
    //   { "youtube": { "metadata": YTDLPMetadata, "localURL": "file:///..."?, "streams": [...] } }
    private enum CodingKeys: String, CodingKey {
        case kind, file, youtube, streams
        case local // legacy
    }

    private enum LegacyLocalKeys: String, CodingKey { case url }
    private enum LegacyYouTubeKeys: String, CodingKey { case metadata, localURL, streams }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let kind = try container.decodeIfPresent(String.self, forKey: .kind) {
            let file = try container.decodeIfPresent(StoredFileReference.self, forKey: .file)
            switch kind {
            case "local":
                guard let file else {
                    throw DecodingError.dataCorruptedError(forKey: .file, in: container, debugDescription: "local source without file")
                }
                self = .local(url: file.url)
            case "youtube":
                let stored = try container.decode(StoredYouTubeSource.self, forKey: .youtube)
                let streams = (try? container.decodeIfPresent(LossyArray<YouTubeStreamOption>.self, forKey: .streams))??.elements ?? []
                self = .youtube(metadata: stored.metadata, localURL: file?.url, streams: streams)
            default:
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown source kind \(kind)")
            }
            return
        }

        // Legacy layout
        if container.contains(.local) {
            let local = try container.nestedContainer(keyedBy: LegacyLocalKeys.self, forKey: .local)
            self = .local(url: try local.decode(URL.self, forKey: .url))
        } else if container.contains(.youtube) {
            let yt = try container.nestedContainer(keyedBy: LegacyYouTubeKeys.self, forKey: .youtube)
            let stored = try yt.decode(StoredYouTubeSource.self, forKey: .metadata)
            let localURL = try? yt.decodeIfPresent(URL.self, forKey: .localURL)
            let streams = (try? yt.decodeIfPresent(LossyArray<YouTubeStreamOption>.self, forKey: .streams))??.elements ?? []
            self = .youtube(metadata: stored.metadata, localURL: localURL ?? nil, streams: streams)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unrecognised media source"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let url):
            try container.encode("local", forKey: .kind)
            try container.encode(StoredFileReference(url: url), forKey: .file)
        case .youtube(let metadata, let localURL, let streams):
            try container.encode("youtube", forKey: .kind)
            try container.encodeIfPresent(localURL.map(StoredFileReference.init(url:)), forKey: .file)
            try container.encode(StoredYouTubeSource(metadata: metadata), forKey: .youtube)
            try container.encode(streams, forKey: .streams)
        }
    }
}

nonisolated struct MediaIngredient: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var source: MediaSource
    var addedDate: Date
    var thumbnailName: String?
    var originalMetadata: MediaMetadata?  // Original source specs before preview conversion

    init(id: UUID, name: String, source: MediaSource, addedDate: Date, thumbnailName: String? = nil, originalMetadata: MediaMetadata? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.addedDate = addedDate
        self.thumbnailName = thumbnailName
        self.originalMetadata = originalMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, source, addedDate, thumbnailName, originalMetadata
    }

    /// Identity fields are required; optional/derived ones are decoded leniently so a change in
    /// `MediaMetadata` drops only that field, never the whole ingredient.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        source = try c.decode(MediaSource.self, forKey: .source)
        addedDate = (try? c.decode(Date.self, forKey: .addedDate)) ?? Date()
        thumbnailName = try? c.decodeIfPresent(String.self, forKey: .thumbnailName)
        originalMetadata = try? c.decodeIfPresent(MediaMetadata.self, forKey: .originalMetadata)
    }
    
    static func == (lhs: MediaIngredient, rhs: MediaIngredient) -> Bool {
        lhs.id == rhs.id
    }
}

nonisolated struct MediaMetadata: Codable, Equatable {
    let codec: String
    let profile: String?
    let width: Int
    let height: Int
    let fps: Double
    let bitrateMbps: Double
    let colorSpace: String
    let bitDepth: Int
    let chromaSubsampling: String
    let hasAudio: Bool
    let audioFormat: String?
    let duration: Double
    
    // Quality labeling
    var resolutionLabel: String {
        if width >= 3840 { return "4K" }
        if width >= 2560 { return "QHD" }
        if width >= 1920 { return "FHD" }
        return "\(height)p"
    }
    
    // Smart Strategy Detection - Holistic Analysis
    var transcodeStrategy: TranscodeStrategy {
        let isHDR = colorSpace.contains("HDR") || colorSpace.contains("HLG") || colorSpace.contains("Rec.2020")
        let isWideColorSDR = colorSpace.contains("P3")
        let isHighChroma = !chromaSubsampling.contains("4:2:0")
        let is8Bit = bitDepth < 10
        
        // Priority 1: High Dynamic Range or Wide Color
        if isHDR || isWideColorSDR {
            if isHighChroma {
                return .advancedColorAndChroma // HDR/P3 + 422/444 (The most complex)
            } else {
                return .hdrTonemap10Bit // HDR/P3 + 420
            }
        }
        
        // Priority 2: High Chroma SDR (e.g., ProRes 422 SDR)
        if isHighChroma {
            return .chromaDownsample10Bit
        }
        
        // Priority 3: Standard SDR with low bit depth
        if is8Bit {
            return .upconvert10Bit
        }
        
        // Baseline: Native 10-bit SDR 4:2:0
        return .standard10Bit
    }
}

nonisolated enum TranscodeStrategy: String, Codable, Sendable {
    case advancedColorAndChroma = "Advanced (HDR/P3 + High Chroma)"
    case hdrTonemap10Bit = "HDR/WideColor to SDR 10-bit"
    case chromaDownsample10Bit = "Professional SDR 4:2:2/4:4:4"
    case upconvert10Bit = "SDR Precision Upgrade (8 to 10-bit)"
    case standard10Bit = "Standard 10-bit SDR"
    
    var description: String {
        switch self {
        case .advancedColorAndChroma:
            return "Extreme high-fidelity processing. Simultaneous HDR/Wide-Color mapping and 4:2:2/4:4:4 chroma downsampling using libplacebo to ensure the most professional 10-bit SDR result."
        case .hdrTonemap10Bit:
            return "Intelligent color mapping (Rec.2020/P3 to Rec.709) with 10-bit precision, preserving highlight detail that would otherwise be lost."
        case .chromaDownsample10Bit:
            return "Professional SDR source detected with high chroma detail. Precision downsampling to 4:2:0 while expanding to 10-bit to maintain color smoothness."
        case .upconvert10Bit:
            return "Expanding 8-bit source to a 10-bit pipeline to prevent compression artifacts and banding in consistent areas like the sky."
        case .standard10Bit:
            return "Native compatibility mode. Optimized encoding for sources already matching the 10-bit SDR 4:2:0 standard."
        }
    }
}

nonisolated struct ImportState {
    var isImporting: Bool = false
    var progress: Double = 0.0
    var status: String = ""
    var error: String? = nil
}

nonisolated struct ExportState {
    var isActive: Bool = false
    var progress: Double = 0.0
    var status: String = "Idle"
    var isFinished: Bool = false
    
    // New Metrics
    var currentFrame: Int = 0
    var speed: Double = 0.0
    var fps: Double = 0.0
    var timeRemaining: TimeInterval? = nil
}

// MARK: - FFmpeg Metrics Protocol
nonisolated struct FFmpegMediaMetrics: Sendable {
    let progress: Double
    let currentFrame: Int
    let speed: Double     // e.g., 1.5 (means 1.5x real-time)
    let fps: Double       // current encoding FPS
    let bitrate: Double   // in kbps
    let totalFrames: Int
}

protocol FFmpegProgressDelegate: Sendable {
    func ffmpegDidUpdateMetrics(_ metrics: FFmpegMediaMetrics)
}

// MARK: - YouTube Download State
nonisolated struct DownloadState: Sendable {
    var progress: Double = 0.0
    var status: String = ""
    var phase: String = "idle"
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speedBytesPerSecond: Double = 0.0
    var etaSeconds: Double? = nil
    var isDownloading: Bool = false
    var error: String? = nil
}

// MARK: - Extensions
extension MediaSource {
    var youtubeMetadata: YTDLPMetadata? {
        if case .youtube(let metadata, _, _) = self {
            return metadata
        }
        return nil
    }
    
    var isYouTube: Bool {
        if case .youtube = self { return true }
        return false
    }
}

extension MediaIngredient {
    var isRemoteYouTube: Bool {
        if case .youtube(_, let localURL, _) = source {
            guard let url = localURL else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }
        return false
    }
    
    /// Returns true if the associated local file is missing from disk.
    var isOffline: Bool {
        if source.isYouTube { return false }
        guard let url = source.localURL else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }
}
