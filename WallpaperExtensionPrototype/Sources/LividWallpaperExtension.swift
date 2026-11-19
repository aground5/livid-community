import ExtensionFoundation
import Foundation
import os
import WallpaperExtensionKit
import WallpaperTypes

private let log = Logger(subsystem: "com.mitocondria.LividWallpaperPrototype.WallpaperExtension", category: "Livid")

/// Minimal prototype: shows one "Livid" item in System Settings → Wallpaper and plays a bundled video
/// through Apple's own VideoWallpaper engine.
@main
struct LividWallpaperExtension: WallpaperExtension, WallpaperExtensionSettingsProvider {
    static let providerID = "com.mitocondria.LividWallpaperPrototype.WallpaperExtension"

    init() {
        log.notice("init")
    }

    private var videoURL: URL {
        Bundle.main.url(forResource: "livid-test", withExtension: "mov")!
    }

    private var thumbnailURL: URL {
        Bundle.main.url(forResource: "livid-thumb", withExtension: "png")!
    }

    func settingsViewModel(for contentType: WallpaperSettingsViewModel.ContentType) async throws -> WallpaperSettingsViewModel {
        log.notice("settingsViewModel(for: \(contentType.rawValue))")
        let descriptor = WallpaperChoiceDescriptor(
            provider: WallpaperChoiceProviderID(rawValue: Self.providerID),
            files: [],
            configuration: Data("livid".utf8)
        )
        let choice = WallpaperChoice(
            id: WallpaperChoice.ID(descriptor: descriptor),
            localizedDescription: "Livid",
            thumbnail: .image(url: thumbnailURL),
            isDownloaded: true
        )
        let item = WallpaperSettingsItem(
            id: WallpaperSettingsItem.ID("livid"),
            localizedName: "Livid",
            thumbnail: .image(url: thumbnailURL),
            choice: choice
        )
        let group = WallpaperSettingsGroup(
            id: WallpaperSettingsGroup.ID("livid"),
            localizedName: "Livid",
            systemImageName: nil,
            items: [item]
        )
        return WallpaperSettingsViewModel(groups: [group], refreshPolicy: .default)
    }

    func makeWallpaper(request: WallpaperCreationRequest, host: any WallpaperHostProxy) async throws -> any Wallpaper {
        log.notice("makeWallpaper video=\(videoURL.path, privacy: .public)")
        do {
            let configuration = VideoWallpaperConfiguration(videos: [Video(url: videoURL)])
            let wallpaper = try await VideoWallpaper(request: request, host: host, configuration: configuration, shouldLoop: true)
            log.notice("VideoWallpaper created")
            return wallpaper
        } catch {
            log.error("VideoWallpaper failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
