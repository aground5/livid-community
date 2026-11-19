import Foundation
import Observation
import AppKit
import AVFoundation
import os

struct LiveWallpaperItem: Identifiable, Codable, Equatable {
    let id: UUID
    let filename: String        // The actual file on disk (UUID.mov) inside AppPaths.wallpapers
    var displayName: String     // User visible name
    let creationDate: Date
    let duration: Double

    var fileURL: URL {
        AppPaths.wallpapers.appendingPathComponent(filename)
    }

    /// Thumbnail is tied to the item's UUID.
    var thumbnailURL: URL {
        AppPaths.thumbnails.appendingPathComponent("\(id.uuidString).png")
    }

    /// The video file is gone (deleted outside Livid). The record is kept so the user decides.
    var isMissing: Bool {
        !FileManager.default.fileExists(atPath: fileURL.path)
    }
}

enum WallpaperStoreError: LocalizedError {
    case sourceMissing(URL)

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let url): return "Rendered file not found: \(url.lastPathComponent)"
        }
    }
}
    
/// Rendered wallpapers (the Library tab).
///
/// Persisted to `AppPaths.database/library.json`; videos live in `AppPaths.wallpapers`.
@Observable
final class WallpaperStore {
    static let shared = WallpaperStore()

    static let schemaVersion = 1

    var wallpapers: [LiveWallpaperItem] = [] {
        didSet {
            guard !suppressSave else { return }
            persistence.scheduleSave(wallpapers)
        }
    }

    /// Set when the stored library could not be read cleanly (shown to the user).
    private(set) var loadIssue: String?

    @ObservationIgnored
    private let persistence = PersistentStore<LiveWallpaperItem>(fileName: "library.json", schemaVersion: WallpaperStore.schemaVersion)
    @ObservationIgnored
    private var suppressSave = false
    @ObservationIgnored
    private var isReconciling = false
    @ObservationIgnored
    private let logger = Logger(subsystem: "com.mitocondria.LiveWallpaperEnabler", category: "WallpaperStore")

    init() {
        loadDB()
        Task {
            await LegacyMigrator.migrateLegacyWallpaperFolder()
            await performFileSystemReconciliation()
        }
    }

    // MARK: - API

    /// Moves/copies a rendered file into the library under a UUID name and records it.
    /// The record is only created once the file is in place.
    @discardableResult
    func add(fileURL: URL, originalName: String? = nil, duration: Double) throws -> LiveWallpaperItem {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            throw WallpaperStoreError.sourceMissing(fileURL)
        }

        let id = UUID()
        let newFilename = "\(id.uuidString).mov"
        let destinationURL = AppPaths.wallpapers.appendingPathComponent(newFilename)

        // 1. Move (already in the library folder) or copy (imported from elsewhere)
        if fileURL.deletingLastPathComponent().standardizedFileURL.path == AppPaths.wallpapers.standardizedFileURL.path {
            try fm.moveItem(at: fileURL, to: destinationURL)
        } else {
            try fm.copyItem(at: fileURL, to: destinationURL)
        }

        // 2. Generate Thumbnail Async (First frame)
        let thumbDest = AppPaths.thumbnails.appendingPathComponent("\(id.uuidString).png")
        Task {
            await self.generateThumbnail(source: destinationURL, dest: thumbDest)
        }

        // 3. Update DB
        let nameToUse = originalName ?? fileURL.deletingPathExtension().lastPathComponent
        let finalName = nameToUse
            .replacingOccurrences(of: "_live_wallpaper", with: "")
            .replacingOccurrences(of: "_", with: " ")

        let newItem = LiveWallpaperItem(
            id: id,
            filename: newFilename,
            displayName: finalName,
            creationDate: Date(),
            duration: duration
        )
        wallpapers.insert(newItem, at: 0)
        return newItem
    }

    func updateName(id: UUID, newName: String) {
        if let index = wallpapers.firstIndex(where: { $0.id == id }) {
            wallpapers[index].displayName = newName
        }
    }

    func remove(id: UUID) {
        guard let item = wallpapers.first(where: { $0.id == id }) else { return }

        // 1. Remove from DB first so a failed file delete never leaves a ghost record
        wallpapers.removeAll { $0.id == id }

        // 2. Remove Files
        try? FileManager.default.removeItem(at: item.fileURL)
        try? FileManager.default.removeItem(at: item.thumbnailURL)
    }

    func contains(id: UUID) -> Bool {
        wallpapers.contains { $0.id == id }
    }

    // MARK: - Persistence

    private func loadDB() {
        switch persistence.load() {
        case .loaded(let items):
            suppressSave = true
            wallpapers = items
            suppressSave = false
            loadIssue = persistence.loadIssue
        case .missing:
            let legacy = LegacyMigrator.legacyWallpapers()
            suppressSave = true
            wallpapers = legacy
            suppressSave = false
            do {
                try persistence.write(legacy)
                LegacyMigrator.markWallpapersMigrated()
            } catch {
                logger.error("Writing migrated library failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Reconciliation

    /// Registers library videos that exist on disk but not in the database
    /// (a crash between rendering and saving, or a restored backup).
    /// Records whose video is missing are kept and shown as missing (`isMissing`).
    private func performFileSystemReconciliation() async {
        guard !isReconciling, !persistence.isReadOnly else { return }
        isReconciling = true
        defer { isReconciling = false }

        let fm = FileManager.default
        let dir = AppPaths.wallpapers
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }

        let knownFilenames = Set(wallpapers.map(\.filename))
        let movFiles = files.filter { $0.pathExtension.lowercased() == "mov" && !knownFilenames.contains($0.lastPathComponent) }
        var newItems: [LiveWallpaperItem] = []

        for file in movFiles {
            let filename = file.lastPathComponent
            let baseName = file.deletingPathExtension().lastPathComponent

            if let id = UUID(uuidString: baseName) {
                // Case A: UUID-named file without a record
                let duration = await Self.duration(of: file)
                newItems.append(LiveWallpaperItem(
                    id: id,
                    filename: filename,
                    displayName: "Restored Wallpaper",
                    creationDate: (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(),
                    duration: duration
                ))
            } else {
                // Case B: non-UUID name (a render that finished but was never registered) -> rename to UUID
                let newID = UUID()
                let newFilename = "\(newID.uuidString).mov"
                let destURL = dir.appendingPathComponent(newFilename)

                do {
                    try fm.moveItem(at: file, to: destURL)
                } catch {
                    logger.error("Failed to adopt \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }

                let newThumb = AppPaths.thumbnails.appendingPathComponent("\(newID.uuidString).png")
                for oldThumbName in ["thumb_\(baseName).png", "\(baseName).png"] {
                    let oldThumbURL = AppPaths.thumbnails.appendingPathComponent(oldThumbName)
                    if fm.fileExists(atPath: oldThumbURL.path) {
                        try? fm.moveItem(at: oldThumbURL, to: newThumb)
                        break
                    }
                }
                if !fm.fileExists(atPath: newThumb.path) {
                    await generateThumbnail(source: destURL, dest: newThumb)
                }

                let duration = await Self.duration(of: destURL)
                newItems.append(LiveWallpaperItem(
                    id: newID,
                    filename: newFilename,
                    displayName: baseName.replacingOccurrences(of: "_", with: " "),
                    creationDate: Date(),
                    duration: duration
                ))
            }
        }

        // The awaits above may have let `add` run; re-check against the current list.
        let currentIDs = Set(wallpapers.map(\.id))
        let currentFilenames = Set(wallpapers.map(\.filename))
        let fresh = newItems.filter { !currentIDs.contains($0.id) && !currentFilenames.contains($0.filename) }
        guard !fresh.isEmpty else { return }

        var merged = wallpapers + fresh
        merged.sort { $0.creationDate > $1.creationDate }
        wallpapers = merged
    }

    private static func duration(of url: URL) async -> Double {
        let seconds = (try? await AVURLAsset(url: url).load(.duration))?.seconds ?? 0
        return seconds.isNaN ? 0 : seconds
    }

    private func generateThumbnail(source: URL, dest: URL) async {
        let asset = AVURLAsset(url: source)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 360)
        
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        
        do {
            let image = try await gen.image(at: time).image
            let nsImage = NSImage(cgImage: image, size: .zero)
            if let tiff = nsImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: dest)
                }
            }
        } catch {
            print("Failed to generate thumbnail for \(source.lastPathComponent): \(error)")
        }
    }
}
