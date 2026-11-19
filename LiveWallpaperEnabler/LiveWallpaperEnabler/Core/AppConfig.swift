import Foundation

struct AppConfig {
    static let shared = AppConfig()
    
    /// Root of all app data (App Group container). See `AppPaths` for the full layout.
    var appSupportDirectory: URL { AppPaths.root }

    var thumbnailsDirectory: URL { AppPaths.thumbnails }

    var wallpapersDirectory: URL { AppPaths.wallpapers }
}
