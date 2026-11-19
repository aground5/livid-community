import Foundation
import Observation
import AVFoundation
import AppKit

@Observable
class AssetImportService {
    static let shared = AssetImportService()
    
    var state = ImportState()
    
    @ObservationIgnored
    private let store = IngredientStore.shared
    @ObservationIgnored
    private let thumbnailManager = ThumbnailManager.shared
    
    /// Main entry point for importing a file. Handles validation, conversion, and metadata.
    func importFile(at url: URL) async {
        await MainActor.run {
            self.state.isImporting = true
            self.state.progress = 0.0
            self.state.status = "Starting import..."
            self.state.error = nil
        }
        
        let id = UUID()
        let folder = AppPaths.sourceFolder(for: id, youtube: false)

        do {
            // 1. Copy the picked file into the container. Nothing outside the container is
            //    referenced after this point, so the ingredient survives relaunches (and the
            //    sandbox, where access to the picked file ends with this session).
            await MainActor.run { self.state.status = "Copying into library..." }
            let localOriginal = try await copyIntoLibrary(url, folder: folder)

            // 2. Analyze ORIGINAL file metadata BEFORE any conversion
            let originalMeta = try? await VideoMetadataAnalyzer.analyze(url: localOriginal)
            
            // 3. Determine if conversion is needed
            let processedURL = try await ensureNativelyPlayable(localOriginal, folder: folder)
            
            // 4. Create Ingredient
            let name = url.lastPathComponent
            var ingredient = MediaIngredient(
                id: id,
                name: name,
                source: .local(url: processedURL),
                addedDate: Date(),
                originalMetadata: originalMeta
            )
            
            // 5. Generate Initial Thumbnail
            await MainActor.run { self.state.status = "Generating preview..." }
            try await generateAndSaveThumbnail(for: id, url: processedURL, ingredient: &ingredient)
            
            // 6. Finalize in Store
            await MainActor.run {
                self.store.add(ingredient)
                self.state.isImporting = false
                self.state.status = "Finished"
            }
            
        } catch {
            try? FileManager.default.removeItem(at: folder)
            await MainActor.run {
                self.state.error = error.localizedDescription
                self.state.isImporting = false
            }
        }
    }

    /// Copies `url` to `<folder>/original.<ext>` off the main thread.
    private func copyIntoLibrary(_ url: URL, folder: URL) async throws -> URL {
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let destination = folder.appendingPathComponent("original.\(ext)")
        try await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: url, to: destination)
        }.value
        return destination
    }
    
    /// Decides if the file needs conversion and executes it if necessary.
    /// The converted preview is written next to the library copy, never next to the user's file.
    private func ensureNativelyPlayable(_ url: URL, folder: URL) async throws -> URL {
        if url.pathExtension.lowercased() == "webm" {
            await MainActor.run { 
                self.state.status = "Converting WebM for preview..."
            }
            
            let convertedURL = folder.appendingPathComponent("preview.mov")
            
            // Fast preview conversion
            try await VideoConverterService.shared.convertToNativelyPlayable(
                inputURL: url, 
                outputURL: convertedURL,
                progressHandler: { progress in
                    Task { @MainActor in
                        self.state.progress = progress
                    }
                }
            )
            return convertedURL
        }
        
        // As-is if natively supported
        return url
    }
    
    private func generateAndSaveThumbnail(for id: UUID, url: URL, ingredient: inout MediaIngredient) async throws {
        let image = try await FilmstripGenerator.shared.generateThumbnail(for: url)
        let filename = "\(id.uuidString).png"
        let fileURL = AppConfig.shared.thumbnailsDirectory.appendingPathComponent(filename)
        
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
            let pngData = bitmap.representation(using: .png, properties: [:])
            try pngData?.write(to: fileURL)
        }
        
        ingredient.thumbnailName = filename
        // Also cache it in the manager immediately
        await MainActor.run {
            self.thumbnailManager.ingredientThumbnails[id] = image
        }
    }
}
