import AppKit
import Foundation
import os

/// Versioned, crash-safe JSON file for one collection of records.
///
/// File format:
/// ```json
/// { "schemaVersion": 1, "items": [ ... ], "quarantine": [ ... ] }
/// ```
///
/// Guarantees:
/// - Writes are atomic (`.atomic`) and debounced; pending writes are flushed on app termination.
/// - A file that cannot be parsed is copied to `<name>.corrupt-<timestamp>.json` before anything
///   is written, so a decoding bug never destroys data.
/// - Records that fail to decode individually are kept in `quarantine` and written back as-is.
/// - A file written by a newer schema is never overwritten (the store becomes read-only).
@MainActor
final class PersistentStore<Item: Codable> {
    enum LoadResult {
        /// No file yet (first launch, or before migration).
        case missing
        case loaded([Item])
    }

    let fileURL: URL
    let schemaVersion: Int

    /// True when writing would lose data (file from a newer app version).
    private(set) var isReadOnly = false
    /// Human readable description of the last load problem, if any.
    private(set) var loadIssue: String?

    private var quarantine: [JSONValue] = []
    private var pendingItems: [Item]?
    private var saveTask: Task<Void, Never>?
    private var didBackUpThisLaunch = false
    private var terminationObserver: NSObjectProtocol?

    private let debounce: Duration
    private let logger = Logger(subsystem: "com.mitocondria.LiveWallpaperEnabler", category: "PersistentStore")

    /// Upgrades older envelopes: `(fromVersion, rawItems) -> rawItems at schemaVersion`.
    typealias Migration = (_ fromVersion: Int, _ items: [JSONValue]) throws -> [JSONValue]
    private let migrate: Migration?

    init(fileName: String,
         schemaVersion: Int,
         directory: URL = AppPaths.database,
         debounce: Duration = .milliseconds(500),
         migrate: Migration? = nil) {
        self.fileURL = directory.appendingPathComponent(fileName)
        self.schemaVersion = schemaVersion
        self.debounce = debounce
        self.migrate = migrate

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - Load

    func load() -> LoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return .missing }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Unreadable (permissions, I/O). Don't overwrite what we could not read.
            isReadOnly = true
            report("Could not read \(fileURL.lastPathComponent): \(error.localizedDescription)")
            return .loaded([])
        }

        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            backUpCorruptFile(data: data)
            report("\(fileURL.lastPathComponent) is not valid; the original was backed up and a new library was started.")
            return .loaded([])
        }

        if header.schemaVersion > schemaVersion {
            isReadOnly = true
            report("\(fileURL.lastPathComponent) was written by a newer version of Livid (schema \(header.schemaVersion)); changes will not be saved.")
            return .loaded(decodeItems(header.items))
        }

        var rawItems = header.items
        if header.schemaVersion < schemaVersion {
            do {
                writeBackup(data: data, suffix: "v\(header.schemaVersion)")
                rawItems = try migrate?(header.schemaVersion, rawItems) ?? rawItems
            } catch {
                isReadOnly = true
                report("Migrating \(fileURL.lastPathComponent) from schema \(header.schemaVersion) failed: \(error)")
                return .loaded([])
            }
        }

        quarantine = header.quarantine ?? []
        let items = decodeItems(rawItems)
        return .loaded(items)
    }

    private func decodeItems(_ raw: [JSONValue]) -> [Item] {
        do {
            let data = try JSONEncoder().encode(raw)
            let lossy = try JSONDecoder().decode(LossyArray<Item>.self, from: data)
            if !lossy.quarantined.isEmpty {
                quarantine.append(contentsOf: lossy.quarantined)
                report("\(lossy.quarantined.count) record(s) in \(fileURL.lastPathComponent) could not be read and were set aside.")
                for error in lossy.errors {
                    logger.error("Quarantined record: \(error, privacy: .public)")
                }
            }
            return lossy.elements
        } catch {
            report("Decoding \(fileURL.lastPathComponent) failed: \(error)")
            return []
        }
    }

    // MARK: - Save

    /// Schedules a debounced write of `items`.
    func scheduleSave(_ items: [Item]) {
        guard !isReadOnly else { return }
        pendingItems = items
        saveTask?.cancel()
        saveTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes any pending items immediately.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let items = pendingItems else { return }
        pendingItems = nil
        do {
            try write(items)
        } catch {
            logger.error("Saving \(self.fileURL.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes `items` now, bypassing the debounce. Used by migrations that must land before the
    /// legacy source is touched.
    func write(_ items: [Item]) throws {
        guard !isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // One rolling backup of the previous good file per launch.
        if !didBackUpThisLaunch, fm.fileExists(atPath: fileURL.path) {
            let backup = fileURL.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: fileURL, to: backup)
            didBackUpThisLaunch = true
        }

        let envelope = Envelope(schemaVersion: schemaVersion, items: items, quarantine: quarantine.isEmpty ? nil : quarantine)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Helpers

    private func backUpCorruptFile(data: Data) {
        writeBackup(data: data, suffix: "corrupt")
    }

    private func writeBackup(data: Data, suffix: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = fileURL.deletingPathExtension().lastPathComponent + ".\(suffix)-\(stamp).json"
        let url = fileURL.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Could not write backup \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func report(_ message: String) {
        loadIssue = message
        logger.error("\(message, privacy: .public)")
    }

    private struct Header: Decodable {
        let schemaVersion: Int
        let items: [JSONValue]
        let quarantine: [JSONValue]?
    }

    private struct Envelope: Encodable {
        let schemaVersion: Int
        let items: [Item]
        let quarantine: [JSONValue]?
    }
}
