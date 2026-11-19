import ExtensionFoundation
import Foundation
import os
import WallpaperExtensionKit
import WallpaperTypes

let extensionLog = Logger(subsystem: "com.mitocondria.LiveWallpaperEnabler.WallpaperExtension", category: "Extension")

/// The "Livid" entry in System Settings → Wallpaper.
///
/// It offers a single choice. The video it plays is whatever the Livid app last set as active
/// (see `ActiveWallpaper`); playback is done by Apple's VideoWallpaper engine inside this process.
@main
struct LividWallpaperExtension: WallpaperExtension, WallpaperExtensionSettingsProvider, WallpaperExtensionDownloadHandler {
    static let providerID = "com.mitocondria.LiveWallpaperEnabler.WallpaperExtension"

    init() {
        LiveWallpapers.shared.startObservingChanges()
    }

    // MARK: WallpaperExtension

    func makeWallpaper(request: WallpaperCreationRequest, host: any WallpaperHostProxy) async throws -> any Wallpaper {
        let url = Self.videoToPlay()
        extensionLog.notice("makeWallpaper video=\(url.lastPathComponent, privacy: .public)")
        let wallpaper = try await VideoWallpaper(
            request: request,
            host: host,
            configuration: VideoWallpaperConfiguration(videos: [Video(url: url)]),
            shouldLoop: true
        )
        await LiveWallpapers.shared.add(wallpaper, playing: url)
        return wallpaper
    }

    /// The app's active video, or the bundled placeholder when nothing is set yet.
    static func videoToPlay() -> URL {
        ActiveWallpaper.currentVideoURL()
            ?? Bundle.main.url(forResource: "placeholder", withExtension: "mov")!
    }

    // MARK: WallpaperExtensionSettingsProvider

    func settingsViewModel(for contentType: WallpaperSettingsViewModel.ContentType) async throws -> WallpaperSettingsViewModel {
        // Thumbnails are read by the system, which cannot see the App Group, so use a bundled image.
        let thumbnail = WallpaperThumbnail.image(url: Bundle.main.url(forResource: "thumbnail", withExtension: "png")!)
        let descriptor = WallpaperChoiceDescriptor(
            provider: WallpaperChoiceProviderID(rawValue: Self.providerID),
            files: [],
            configuration: Data("livid".utf8)
        )
        let choice = WallpaperChoice(
            id: WallpaperChoice.ID(descriptor: descriptor),
            localizedDescription: "Livid",
            thumbnail: thumbnail,
            isDownloaded: true
        )
        let item = WallpaperSettingsItem(id: WallpaperSettingsItem.ID("livid"), localizedName: "Livid", thumbnail: thumbnail, choice: choice)
        // Groups default to SortID.other (near the bottom). Sharing the "Your Photos" bucket places
        // Livid right below that section (checked in System Settings on macOS 27.2).
        let group = WallpaperSettingsGroup(id: WallpaperSettingsGroup.ID("livid"), localizedName: "Livid", systemImageName: nil, items: [item])
            .sortID(.yourPhotos)
        return WallpaperSettingsViewModel(groups: [group], refreshPolicy: .default)
    }

    // MARK: WallpaperExtensionDownloadHandler
    // Videos are produced locally by the app, so the single choice is always "downloaded".

    func isChoiceDownloaded(with choiceID: WallpaperChoice.ID) async throws -> Bool { true }
    func download(choiceID: WallpaperChoice.ID, progress: Progress) async throws { progress.completedUnitCount = progress.totalUnitCount }
    func cancelDownload(for choiceID: WallpaperChoice.ID) async throws {}
}

/// Tracks live VideoWallpaper instances (one per display / desktop / lock screen) so a change made
/// in the app can be applied to all of them without the system recreating the wallpaper.
actor LiveWallpapers {
    static let shared = LiveWallpapers()

    private struct Entry {
        weak var wallpaper: VideoWallpaper?
        var url: URL
    }
    private var entries: [Entry] = []

    func add(_ wallpaper: VideoWallpaper, playing url: URL) {
        entries.removeAll { $0.wallpaper == nil }
        entries.append(Entry(wallpaper: wallpaper, url: url))
    }

    func applyActiveVideo() async {
        let url = LividWallpaperExtension.videoToPlay()
        entries.removeAll { $0.wallpaper == nil }
        extensionLog.notice("active wallpaper changed -> \(url.lastPathComponent, privacy: .public), live=\(self.entries.count)")
        for index in entries.indices where entries[index].url != url {
            guard let wallpaper = entries[index].wallpaper else { continue }
            await wallpaper.setVideos([Video(url: url)])
            entries[index].url = url
        }
    }

    nonisolated func startObservingChanges() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in Task { await LiveWallpapers.shared.applyActiveVideo() } },
            ActiveWallpaper.didChangeNotification as CFString,
            nil,
            .deliverImmediately
        )
    }
}
