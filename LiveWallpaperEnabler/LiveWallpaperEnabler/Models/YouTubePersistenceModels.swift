import Foundation

/// A file location as stored in the database: relative to `AppPaths.root` when the file is in the
/// container (the normal case), absolute only for legacy records that still point outside it.
nonisolated struct StoredFileReference: Codable, Equatable, Sendable {
    var relativePath: String?
    var absolutePath: String?

    init(url: URL) {
        if let relative = AppPaths.relativePath(for: url) {
            relativePath = relative
        } else {
            absolutePath = url.path
        }
    }

    var url: URL {
        if let relativePath { return AppPaths.url(forRelativePath: relativePath) }
        return URL(fileURLWithPath: absolutePath ?? "")
    }
}

/// The persisted subset of `YTDLPMetadata`.
///
/// Keys deliberately match `YTDLPMetadata`'s JSON keys so the legacy (full metadata) records decode
/// into this type directly. `formats` is intentionally not stored: it is only needed while
/// choosing a stream and is re-fetched when missing.
nonisolated struct StoredYouTubeSource: Codable, Sendable {
    let id: String
    let title: String
    let webpage_url: String
    let description: String?
    let thumbnail: String?
    let uploader: String?
    let duration: Double?

    init(metadata: YTDLPMetadata) {
        id = metadata.id
        title = metadata.title
        webpage_url = metadata.webpage_url
        description = metadata.description
        thumbnail = metadata.thumbnail
        uploader = metadata.uploader
        duration = metadata.duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? id
        webpage_url = try c.decode(String.self, forKey: .webpage_url)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        thumbnail = try? c.decodeIfPresent(String.self, forKey: .thumbnail)
        uploader = try? c.decodeIfPresent(String.self, forKey: .uploader)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
    }

    var metadata: YTDLPMetadata {
        YTDLPMetadata(id: id, title: title, description: description, webpage_url: webpage_url,
                      thumbnail: thumbnail, uploader: uploader, duration: duration)
    }
}
