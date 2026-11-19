import Foundation
import os

/// One-time import of the pre-file-store library (UserDefaults blobs + files outside the container).
///
/// Runs only when the new database file does not exist yet. The legacy UserDefaults values are
/// backed up verbatim to `Database/legacy-*.json` and are **not** deleted, only marked as
/// migrated, so a downgrade or a migration bug can still recover them.
enum LegacyMigrator {
    private static let logger = Logger(subsystem: "com.mitocondria.LiveWallpaperEnabler", category: "LegacyMigrator")

    private static let wallpaperKey = "wallpaper_library_v2"
    private static let ingredientKey = "media_ingredients_v3"
    private static let wallpapersMigratedKey = "storage_v1_migrated_wallpapers_at"
    private static let ingredientsMigratedKey = "storage_v1_migrated_ingredients_at"

    private static var suiteDefaults: UserDefaults? { UserDefaults(suiteName: AppPaths.appGroupID) }

    // MARK: - Wallpapers

    /// Library records from `wallpaper_library_v2`. Items that referenced files outside the
    /// library folder (`absolutePath`) are copied in.
    static func legacyWallpapers() -> [LiveWallpaperItem] {
        // The library was written to the App Group suite, falling back to standard defaults.
        guard let data = legacyData(forKey: wallpaperKey, preferSuite: true) else { return [] }
        backUp(data, name: "legacy-\(wallpaperKey).json")

        guard let lossy = try? JSONDecoder().decode(LossyArray<LiveWallpaperItem>.self, from: data) else {
            logger.error("Legacy wallpaper library is unreadable; it was backed up and skipped.")
            return []
        }
        if !lossy.quarantined.isEmpty {
            logger.error("\(lossy.quarantined.count) legacy wallpaper record(s) could not be decoded (kept in the backup).")
        }

        // Copy files that lived outside the library folders.
        let overrides = (try? JSONDecoder().decode(LossyArray<LegacyPathOverrides>.self, from: data))?.elements ?? []
        let fm = FileManager.default
        for override in overrides {
            guard let item = lossy.elements.first(where: { $0.id == override.id }) else { continue }
            if let path = override.absolutePath, fm.fileExists(atPath: path), !fm.fileExists(atPath: item.fileURL.path) {
                copy(from: URL(fileURLWithPath: path), to: item.fileURL)
            }
            if let path = override.absoluteThumbnailPath, fm.fileExists(atPath: path), !fm.fileExists(atPath: item.thumbnailURL.path) {
                copy(from: URL(fileURLWithPath: path), to: item.thumbnailURL)
            }
        }
        logger.info("Imported \(lossy.elements.count) wallpaper(s) from UserDefaults")
        return lossy.elements
    }

    static func markWallpapersMigrated() {
        mark(wallpapersMigratedKey)
    }

    /// Moves videos/thumbnails from the pre-App-Group folder
    /// `~/Library/Application Support/LiveWallpaperEnabler` (only reachable in the direct build;
    /// in the sandbox that path resolves inside the app's own container and is simply absent).
    static func migrateLegacyWallpaperFolder() async {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let legacyBase = appSupport.appendingPathComponent("LiveWallpaperEnabler", isDirectory: true)
        // When AppPaths had to fall back to this very folder there is nothing to migrate.
        guard legacyBase.standardizedFileURL.path != AppPaths.root.standardizedFileURL.path else { return }

        let legacyWallpapers = legacyBase.appendingPathComponent("Wallpapers")
        guard let oldFiles = try? fm.contentsOfDirectory(at: legacyWallpapers, includingPropertiesForKeys: nil) else { return }

        for file in oldFiles where file.pathExtension.lowercased() == "mov" {
            let destination = AppPaths.wallpapers.appendingPathComponent(file.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.moveItem(at: file, to: destination)
                let thumbName = file.deletingPathExtension().appendingPathExtension("png").lastPathComponent
                let oldThumb = legacyBase.appendingPathComponent("Thumbnails").appendingPathComponent(thumbName)
                let newThumb = AppPaths.thumbnails.appendingPathComponent(thumbName)
                if fm.fileExists(atPath: oldThumb.path) && !fm.fileExists(atPath: newThumb.path) {
                    try? fm.moveItem(at: oldThumb, to: newThumb)
                }
                logger.info("Migrated legacy wallpaper \(file.lastPathComponent, privacy: .public) into the App Group")
            } catch {
                logger.error("Migrating \(file.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Ingredients

    /// Ingredients from `media_ingredients_v3`. Their files are moved into the container
    /// afterwards by `IngredientStore` (see `relocateExternalSources`).
    static func legacyIngredients() -> [MediaIngredient] {
        // Ingredients were written to standard defaults.
        guard let data = legacyData(forKey: ingredientKey, preferSuite: false) else { return [] }
        backUp(data, name: "legacy-\(ingredientKey).json")

        guard let lossy = try? JSONDecoder().decode(LossyArray<MediaIngredient>.self, from: data) else {
            logger.error("Legacy ingredient list is unreadable; it was backed up and skipped.")
            return []
        }
        if !lossy.quarantined.isEmpty {
            logger.error("\(lossy.quarantined.count) legacy ingredient record(s) could not be decoded (kept in the backup).")
        }
        logger.info("Imported \(lossy.elements.count) ingredient(s) from UserDefaults")
        return lossy.elements
    }

    static func markIngredientsMigrated() {
        mark(ingredientsMigratedKey)
    }

    // MARK: - Helpers

    private static func legacyData(forKey key: String, preferSuite: Bool) -> Data? {
        let stores = preferSuite ? [suiteDefaults, .standard] : [.standard, suiteDefaults]
        for defaults in stores.compactMap({ $0 }) {
            if let data = defaults.data(forKey: key) { return data }
        }
        return nil
    }

    private static func mark(_ key: String) {
        let date = Date()
        UserDefaults.standard.set(date, forKey: key)
        suiteDefaults?.set(date, forKey: key)
    }

    private static func backUp(_ data: Data, name: String) {
        let url = AppPaths.database.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Backing up \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func copy(from source: URL, to destination: URL) {
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            logger.error("Copying \(source.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The removed `absolutePath` / `absoluteThumbnailPath` fields of `LiveWallpaperItem`.
    private struct LegacyPathOverrides: Decodable {
        let id: UUID
        let absolutePath: String?
        let absoluteThumbnailPath: String?
    }
}
