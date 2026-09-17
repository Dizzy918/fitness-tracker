import Foundation
import SwiftData
import OSLog

/// A folder the app re-checks for new `.fit` files.
///
/// Watch apps export to a directory. Dragging it in works, but doing that every
/// week is the kind of chore that ends with three months of unimported files —
/// so the app remembers one folder and looks again on its own.
///
/// **It scans when the app becomes active, not continuously.** A live
/// filesystem watcher means an FSEvents stream to start, restart and tear down,
/// plus sandbox lifetime questions, in exchange for noticing a file while you
/// aren't looking at the app. Scanning on activation covers the real case at a
/// fraction of the moving parts.
///
/// Re-importing is free: FIT files dedupe on a content hash, so a scan that sees
/// the same hundred files again does a hundred cheap decodes and adds nothing.
enum WatchedFolder {

    private static let log = Logger(subsystem: "com.slavov.fitnesstracker", category: "watchfolder")

    static let bookmarkKey = "watchedFolderBookmark"
    static let enabledKey = "watchedFolderEnabled"

    /// Whether the athlete wants the folder checked. Separate from whether one
    /// is set, so turning it off doesn't lose the choice of folder.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    // MARK: - Remembering the folder

    /// Security-scoped on macOS, where the sandbox otherwise forgets the grant
    /// the moment the app quits. iOS bookmarks don't take the option at all, and
    /// passing it there throws.
    private static var bookmarkOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private static var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    static func remember(_ url: URL, _ defaults: UserDefaults = .standard) throws {
        // The picker's grant has to be active while the bookmark is minted.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let bookmark = try url.bookmarkData(options: bookmarkOptions,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
        defaults.set(bookmark, forKey: bookmarkKey)
    }

    static func forget(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: bookmarkKey)
    }

    static func hasFolder(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.data(forKey: bookmarkKey) != nil
    }

    /// Resolve the stored bookmark, or nil when there isn't one or it's dead.
    ///
    /// A folder can be renamed, moved or deleted between launches. A stale
    /// bookmark resolves with `isStale` and is refreshed in place; one that
    /// can't resolve at all is reported rather than silently doing nothing, so
    /// "auto-import stopped working" has a visible cause.
    static func resolve(_ defaults: UserDefaults = .standard) -> URL? {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: resolutionOptions,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale)
        else {
            log.notice("watched folder bookmark could not be resolved")
            return nil
        }
        if isStale { try? remember(url, defaults) }
        return url
    }

    /// The path to show in Settings. Nil when no folder is set.
    static func displayPath(_ defaults: UserDefaults = .standard) -> String? {
        resolve(defaults)?.path(percentEncoded: false)
    }

    // MARK: - Scanning

    struct Report: Sendable, Equatable {
        var imported = 0
        var alreadyHad = 0
        var failed = 0
        /// Set when the folder itself couldn't be read.
        var unavailable = false

        var foundAnything: Bool { imported > 0 }

        var summary: String {
            if unavailable {
                return "The watched folder couldn't be opened. It may have been moved, renamed or deleted — pick it again in Settings."
            }
            guard imported > 0 || failed > 0 else {
                return alreadyHad > 0
                    ? "Nothing new — all \(alreadyHad) files are already imported."
                    : "No .fit files in the watched folder."
            }
            var parts = ["Imported \(imported)"]
            if alreadyHad > 0 { parts.append("skipped \(alreadyHad) already there") }
            if failed > 0 { parts.append("\(failed) failed") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Import anything in the folder that isn't already in the store.
    ///
    /// Decoding runs off the main actor — a folder of five-hour rides is a lot
    /// of parsing — while the SwiftData writes stay on it.
    @MainActor
    @discardableResult
    static func scan(into context: ModelContext,
                     defaults: UserDefaults = .standard) async -> Report {
        var report = Report()
        guard isEnabled(defaults) else { return report }
        guard let folder = resolve(defaults) else {
            // Only "unavailable" if a folder was supposed to be there.
            report.unavailable = hasFolder(defaults)
            return report
        }

        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let files = FITImporter.fitFiles(in: [folder])
        guard !files.isEmpty else { return report }

        let importer = FITImporter()
        for file in files {
            do {
                let decoded = try await Task.detached(priority: .utility) {
                    try importer.decode(url: file)
                }.value
                try importer.persist(decoded, in: context)
                report.imported += 1
            } catch FITPersistError.duplicate {
                // The common case on every scan after the first, and the reason
                // re-scanning the same folder forever is safe.
                report.alreadyHad += 1
            } catch {
                log.notice("watched folder skipped \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                report.failed += 1
            }
        }

        if report.imported > 0 {
            log.info("watched folder imported \(report.imported, privacy: .public) workouts")
        }
        return report
    }
}
