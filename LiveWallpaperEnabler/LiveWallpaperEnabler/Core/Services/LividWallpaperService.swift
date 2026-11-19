import AppKit
import Foundation
import Observation

/// Sets which library video the "Livid" wallpaper plays.
///
/// The video is MOV-patched (WallpaperInjector) into the App Group's ActiveWallpaper folder,
/// recorded in `active.json`, and announced to the Livid wallpaper extension via a Darwin
/// notification. The extension then switches every live wallpaper to it. The system wallpaper
/// store (entries.json / Index.plist / aerials folders) is never touched.
@Observable
final class LividWallpaperService {
    static let shared = LividWallpaperService()

    private(set) var activeSelection: ActiveWallpaper.Selection? = ActiveWallpaper.readSelection()
    private(set) var isApplying = false
    private(set) var lastError: String?

    /// Library item the active video came from; nil once that item was removed from the library
    /// (the patched copy keeps playing, but nothing in the library is "active" anymore).
    var activeItemID: UUID? {
        guard let id = activeSelection?.sourceItemID, WallpaperStore.shared.contains(id: id) else { return nil }
        return id
    }

    func setActive(_ item: LiveWallpaperItem) {
        guard !isApplying else { return }
        isApplying = true
        lastError = nil
        defer { isApplying = false }

        do {
            guard let dir = ActiveWallpaper.directory else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "App Group container is unavailable."])
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // A new file name per change: the extension may still be reading the previous file.
            let fileName = "\(UUID().uuidString).mov"
            let outputURL = dir.appendingPathComponent(fileName)
            let patcher = try AtomPatcher(fileURL: item.fileURL)
            try WallpaperInjector.patch(patcher: patcher)
            try patcher.save(outputURL: outputURL)

            let selection = ActiveWallpaper.Selection(
                videoFileName: fileName,
                sourceItemID: item.id,
                title: item.displayName,
                updatedAt: Date()
            )
            let previous = activeSelection
            try ActiveWallpaper.writeSelection(selection)
            activeSelection = selection
            ActiveWallpaper.postDidChange()
            removeStaleVideos(keeping: [selection.videoFileName, previous?.videoFileName].compactMap { $0 })
        } catch {
            lastError = error.localizedDescription
            NSLog("❌ [LividWallpaper] Failed to set active wallpaper: \(error)")
        }
    }

    /// Keeps the current and previous patched videos; older ones are no longer referenced.
    private func removeStaleVideos(keeping names: [String]) {
        guard let dir = ActiveWallpaper.directory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files where file.hasSuffix(".mov") && !names.contains(file) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
    }

    /// Opens System Settings → Wallpaper, where the user picks "Livid" once.
    func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
