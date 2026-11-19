import Foundation
import os

/// Single source of truth for every location Livid reads or writes.
///
/// Everything lives under the App Group container so the app, the XPC helper and the wallpaper
/// extension share one tree, and so the sandboxed (App Store) build never needs access outside it:
///
/// ```
/// <root>/
///   Database/              library.json, ingredients.json
///   Sources/Local/<id>/    imported originals + previews
///   Sources/YouTube/<id>/  downloaded previews
///   Staging/<task>/        in-flight downloads / conversions (cleared on launch)
///   Wallpapers/            rendered library videos
///   Thumbnails/
///   ActiveWallpaper/       active.json + patched video (read by the extension)
///   Caches/yt-dlp/
///   Logs/
/// ```
///
/// Compiled into the app, the helper and the extension, so it must stay free of app-only types.
nonisolated enum AppPaths {
    static let appGroupID = "group.com.mitocondria.LiveWallpaperEnabler"

    private static let logger = Logger(subsystem: "com.mitocondria.LiveWallpaperEnabler", category: "AppPaths")

    /// `<group container>/Library/Application Support/LiveWallpaperEnabler`.
    ///
    /// If the App Group container is unavailable (misconfigured signing) we keep the same
    /// sub-layout under the process' own Application Support folder instead of scattering files,
    /// and log loudly. Debug builds assert so the misconfiguration is noticed immediately.
    static let root: URL = {
        let fm = FileManager.default
        let base: URL
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            base = container.appendingPathComponent("Library/Application Support/LiveWallpaperEnabler", isDirectory: true)
        } else {
            logger.fault("App Group container \(appGroupID, privacy: .public) is unavailable; falling back to the process Application Support folder.")
            assertionFailure("App Group container unavailable – check the application-groups entitlement.")
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            base = appSupport.appendingPathComponent("LiveWallpaperEnabler", isDirectory: true)
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // MARK: - Directories

    static var database: URL { directory("Database") }
    static var sources: URL { directory("Sources") }
    static var localSources: URL { directory("Sources/Local") }
    static var youTubeSources: URL { directory("Sources/YouTube") }
    static var staging: URL { directory("Staging") }
    static var wallpapers: URL { directory("Wallpapers") }
    static var thumbnails: URL { directory("Thumbnails") }
    static var activeWallpaper: URL { directory("ActiveWallpaper") }
    static var ytDLPCache: URL { directory("Caches/yt-dlp") }
    static var logs: URL { directory("Logs") }

    /// Per-ingredient source folder (`Sources/Local/<id>` or `Sources/YouTube/<id>`).
    static func sourceFolder(for id: UUID, youtube: Bool) -> URL {
        let parent = youtube ? youTubeSources : localSources
        let url = parent.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fresh, empty staging folder for one task.
    static func stagingFolder(named name: String) -> URL {
        let url = staging.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Removes leftovers of interrupted downloads/conversions. Call once at app launch.
    static func clearStaging() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }

    // MARK: - Relative paths

    /// Path of `url` relative to `root`, or nil when it lives outside the container.
    static func relativePath(for url: URL) -> String? {
        // `resolvingSymlinksInPath` only resolves components that exist (and strips `/private`
        // for existing paths), so a not-yet-created file and the root can resolve differently.
        // Compare every spelling of both.
        func spellings(_ url: URL) -> Set<String> {
            let standardized = url.standardizedFileURL
            let raw = [url.path, standardized.path, standardized.resolvingSymlinksInPath().path]
            // `/private/var` ⇄ `/var`, `/private/tmp` ⇄ `/tmp`
            return Set(raw.map { $0.hasPrefix("/private/") ? String($0.dropFirst("/private".count)) : $0 })
        }
        let paths = spellings(url)
        for rootPath in spellings(root) {
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            for path in paths where path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
        }
        return nil
    }

    static func url(forRelativePath relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    // MARK: - Helpers

    private static func directory(_ relative: String) -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
