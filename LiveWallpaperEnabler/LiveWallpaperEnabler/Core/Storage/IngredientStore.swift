import AppKit
import Foundation
import Observation
import os

/// Source media (local imports and YouTube entries) shown in the Prepare tab.
///
/// Persisted to `AppPaths.database/ingredients.json` through `PersistentStore`. Every source file
/// lives in its own folder under `AppPaths.sources`, so removing an ingredient removes its files.
@Observable
final class IngredientStore {
    static let shared = IngredientStore()

    static let schemaVersion = 1

    var ingredients: [MediaIngredient] = [] {
        didSet {
            guard !suppressSave else { return }
            persistence.scheduleSave(ingredients)
        }
    }

    /// Set when the stored library could not be read cleanly (shown to the user).
    private(set) var loadIssue: String?

    @ObservationIgnored
    private let persistence = PersistentStore<MediaIngredient>(fileName: "ingredients.json", schemaVersion: IngredientStore.schemaVersion)
    @ObservationIgnored
    private var suppressSave = false
    @ObservationIgnored
    private var availability: [UUID: Bool] = [:]
    @ObservationIgnored
    private var activationObserver: NSObjectProtocol?
    @ObservationIgnored
    private let logger = Logger(subsystem: "com.mitocondria.LiveWallpaperEnabler", category: "IngredientStore")

    init() {
        load()
        availability = currentAvailability()

        // Files can disappear while the app is in the background (Finder, cleanup tools).
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAvailability() }
        }

        Task { await relocateExternalSources() }
    }

    // MARK: - CRUD Operations

    func add(_ ingredient: MediaIngredient) {
        if !ingredients.contains(where: { $0.id == ingredient.id }) {
            ingredients.append(ingredient)
            availability[ingredient.id] = !ingredient.isOffline && !ingredient.isRemoteYouTube
        }
    }

    /// Removes the ingredient together with the files Livid owns for it
    /// (its source folder and thumbnail). Files outside the container are never deleted.
    func remove(id: UUID) {
        guard let ingredient = ingredients.first(where: { $0.id == id }) else { return }
        ingredients.removeAll { $0.id == id }
        availability.removeValue(forKey: id)
        deleteOwnedFiles(of: ingredient)
    }

    func update(_ ingredient: MediaIngredient) {
        if let index = ingredients.firstIndex(where: { $0.id == ingredient.id }) {
            ingredients[index] = ingredient
        }
    }

    // MARK: - Availability

    func checkAvailability(for ingredient: MediaIngredient) -> Bool {
        !ingredient.isOffline
    }

    /// Re-checks which source files exist and, if anything changed, nudges observers without
    /// writing the database (availability is derived, not stored).
    func refreshAvailability() {
        let now = currentAvailability()
        guard now != availability else { return }
        availability = now
        suppressSave = true
        ingredients = ingredients
        suppressSave = false
    }

    private func currentAvailability() -> [UUID: Bool] {
        Dictionary(uniqueKeysWithValues: ingredients.map { ($0.id, !$0.isOffline && !$0.isRemoteYouTube) })
    }

    // MARK: - Persistence

    private func load() {
        switch persistence.load() {
        case .loaded(let items):
            suppressSave = true
            ingredients = items
            suppressSave = false
            loadIssue = persistence.loadIssue
        case .missing:
            // First launch on the file-based store: import the UserDefaults library once.
            let legacy = LegacyMigrator.legacyIngredients()
            suppressSave = true
            ingredients = legacy
            suppressSave = false
            do {
                try persistence.write(legacy)
                LegacyMigrator.markIngredientsMigrated()
            } catch {
                logger.error("Writing migrated ingredients failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        removeOrphanedSourceFolders()
    }

    // MARK: - File ownership

    private func deleteOwnedFiles(of ingredient: MediaIngredient) {
        let fm = FileManager.default
        for youtube in [false, true] {
            let folder = (youtube ? AppPaths.youTubeSources : AppPaths.localSources)
                .appendingPathComponent(ingredient.id.uuidString, isDirectory: true)
            try? fm.removeItem(at: folder)
        }
        if let name = ingredient.thumbnailName {
            try? fm.removeItem(at: AppPaths.thumbnails.appendingPathComponent(name))
        }
    }

    /// Source folders whose ingredient no longer exists (e.g. an import that crashed halfway).
    private func removeOrphanedSourceFolders() {
        guard !persistence.isReadOnly else { return }
        let fm = FileManager.default
        let known = Set(ingredients.map(\.id.uuidString))
        for parent in [AppPaths.localSources, AppPaths.youTubeSources] {
            guard let folders = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for folder in folders where !known.contains(folder.lastPathComponent) {
                // Skip folders touched in the last hour: an import may be writing into it right now.
                let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard modified < Date().addingTimeInterval(-3600) else { continue }
                try? fm.removeItem(at: folder)
            }
        }
    }

    /// Copies (or, for files Livid itself downloaded, moves) any source that still lives outside
    /// the container into the ingredient's source folder, and points the ingredient at the copy.
    private func relocateExternalSources() async {
        for ingredient in ingredients {
            guard let url = ingredient.source.localURL,
                  AppPaths.relativePath(for: url) == nil,
                  FileManager.default.fileExists(atPath: url.path) else { continue }

            let youtube = ingredient.source.isYouTube
            let folder = AppPaths.sourceFolder(for: ingredient.id, youtube: youtube)
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
            let destination = folder.appendingPathComponent(youtube ? "preview.\(ext)" : "original.\(ext)")
            let ownedByLivid = url.path.contains("/LiveWallpaperDownloads/")

            do {
                try await Task.detached(priority: .utility) {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    if ownedByLivid {
                        try fm.moveItem(at: url, to: destination)
                    } else {
                        try fm.copyItem(at: url, to: destination)
                    }
                }.value
            } catch {
                logger.error("Relocating \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                continue
            }

            guard var current = ingredients.first(where: { $0.id == ingredient.id }) else {
                // Removed while we were copying.
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            current.source = current.source.withLocalURL(destination)
            update(current)
            logger.info("Moved source \(url.lastPathComponent, privacy: .public) into the library")
        }
    }
}
