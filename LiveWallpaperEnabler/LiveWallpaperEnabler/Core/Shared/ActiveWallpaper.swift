import Foundation

/// Contract shared by the Livid app and the Livid wallpaper extension.
///
/// The app writes the patched video for the current wallpaper into the App Group container,
/// records it in `active.json`, and posts a Darwin notification. The extension (which runs
/// Apple's VideoWallpaper engine in its own sandboxed process) reads the same file and switches
/// the video on every live wallpaper. Nothing here touches the system wallpaper store.
///
/// This file is compiled into both targets, so it must stay free of app-only types and actor isolation.
nonisolated enum ActiveWallpaper {
    static let appGroupID = AppPaths.appGroupID

    /// Posted (Darwin notify) by the app after `active.json` changes.
    static let didChangeNotification = "com.mitocondria.LiveWallpaperEnabler.activeWallpaperDidChange"

    struct Selection: Codable, Equatable, Sendable {
        /// File name of the patched video inside `directory`.
        var videoFileName: String
        /// Library item this video came from, for display in the app.
        var sourceItemID: UUID?
        var title: String
        var updatedAt: Date
    }

    static var directory: URL? {
        AppPaths.activeWallpaper
    }

    private static var selectionURL: URL? {
        directory?.appendingPathComponent("active.json")
    }

    static func readSelection() -> Selection? {
        guard let url = selectionURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Selection.self, from: data)
    }

    /// URL of the current video, or nil when nothing is selected or the file is missing.
    static func currentVideoURL() -> URL? {
        guard let selection = readSelection(), let dir = directory else { return nil }
        let url = dir.appendingPathComponent(selection.videoFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func writeSelection(_ selection: Selection) throws {
        guard let url = selectionURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(selection)
        try data.write(to: url, options: .atomic)
    }

    static func postDidChange() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(didChangeNotification as CFString),
            nil, nil, true
        )
    }
}
