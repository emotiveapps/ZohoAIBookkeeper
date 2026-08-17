import Foundation

/// Syncs one OneDrive folder against a local cache via Microsoft Graph.
///
/// Design (docs/ARCHIVE_SYNC_DESIGN.md): the cloud folder is canonical; the
/// local cache is purgeable and rebuilt on demand; new/changed files are
/// written to a non-purgeable staging directory first and only move into the
/// cache once Graph confirms the upload, so a cache purge can never lose data.
/// Incremental pulls use the drive delta API with a persisted token
/// (OneDrive for Business only supports delta on the drive root, so results
/// are filtered by path prefix); bootstrap and token expiry fall back to a
/// full folder listing plus a fresh baseline token.
///
/// Deliberately generic — no knowledge of receipts — so it can be reused for
/// any folder-shaped dataset in other apps. Files with an extension in
/// `eagerExtensions` (metadata, e.g. ".json" sidecars) download eagerly on
/// pull; everything else downloads lazily on first read.
public actor GraphDriveSyncEngine {
    public struct IndexEntry: Codable, Sendable, Equatable {
        public var id: String
        public var eTag: String?
        public var size: Int
        public var contentCached: Bool
        public var lastModified: Date?
    }

    public struct SyncReport: Sendable {
        public var downloaded = 0
        public var uploaded = 0
        public var warnings: [String] = []
    }

    private let graph: GraphMailClient
    /// Drive-root-relative path of the synced folder, e.g.
    /// "03_Finance/ZohoAIBookkeeper/Receipts Archive".
    private let folderPath: String
    public nonisolated let cacheRoot: URL
    public nonisolated let stagingRoot: URL
    private let syncState: any SyncStateStore
    private let eagerExtensions: Set<String>

    /// Keyed by path relative to `folderPath`.
    private var index: [String: IndexEntry] = [:]
    private var indexLoaded = false

    private var deltaTokenKey: String { "driveDelta|\(folderPath)" }
    private var indexURL: URL { cacheRoot.appendingPathComponent("index.json") }

    public init(
        graph: GraphMailClient,
        folderPath: String,
        cacheRoot: URL,
        stagingRoot: URL,
        syncState: any SyncStateStore,
        eagerExtensions: Set<String> = ["json"]
    ) throws {
        self.graph = graph
        self.folderPath = folderPath
        self.cacheRoot = cacheRoot
        self.stagingRoot = stagingRoot
        self.syncState = syncState
        self.eagerExtensions = eagerExtensions
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    }

    // MARK: - Local file access

    /// Write a new or updated file. It lands in staging (non-purgeable) and is
    /// visible to reads immediately; `push()` uploads it and moves it to cache.
    public func stage(relativePath: String, data: Data) throws {
        let url = stagingRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    /// Read a file: staging overlays cache; anything indexed but not cached
    /// downloads on demand (and is cached for next time).
    public func fileData(at relativePath: String) async throws -> Data {
        let staged = stagingRoot.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: staged.path) {
            return try Data(contentsOf: staged)
        }
        let cached = cacheRoot.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: cached.path) {
            return try Data(contentsOf: cached)
        }
        loadIndexIfNeeded()
        guard var entry = index[relativePath] else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: relativePath])
        }
        let data = try await graph.downloadDriveItem(id: entry.id)
        try writeCacheFile(relativePath: relativePath, data: data)
        entry.contentCached = true
        index[relativePath] = entry
        saveIndex()
        return data
    }

    /// All locally visible files with the given suffix (staging overlays
    /// cache), as relativePath → readable URL. The engine's own index.json is
    /// excluded.
    public func localFiles(withSuffix suffix: String) -> [String: URL] {
        var result: [String: URL] = [:]
        for root in [cacheRoot, stagingRoot] {
            // Staging enumerated second → overlays cache.
            for (relative, url) in Self.regularFiles(under: root)
                where url.lastPathComponent != "index.json" && relative.hasSuffix(suffix) {
                result[relative] = url
            }
        }
        return result
    }

    /// Synchronous helper: FileManager enumeration is unavailable directly in
    /// async contexts under strict concurrency.
    private static func regularFiles(under root: URL) -> [String: URL] {
        // Resolve symlinks on both sides ("/var" vs "/private/var") so the
        // relative-path computation can't misalign.
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: resolvedRoot, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        var result: [String: URL] = [:]
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let resolved = url.resolvingSymlinksInPath()
            result[String(resolved.path.dropFirst(resolvedRoot.path.count + 1))] = resolved
        }
        return result
    }

    // MARK: - Pull (cloud → cache)

    public func pull() async throws -> SyncReport {
        loadIndexIfNeeded()
        var report = SyncReport()

        // A purged cache with a surviving delta token would silently skip
        // re-downloading everything — detect and re-bootstrap.
        if !FileManager.default.fileExists(atPath: indexURL.path), !index.isEmpty {
            index = [:]
        }
        if index.isEmpty, syncState.value(forKey: deltaTokenKey) != nil,
           !FileManager.default.fileExists(atPath: indexURL.path) {
            syncState.setValue(nil, forKey: deltaTokenKey)
        }

        var changes: [(relativePath: String, id: String, eTag: String?, size: Int, lastModified: Date?)] = []
        var deletions: [String] = []

        if let token = syncState.value(forKey: deltaTokenKey) {
            do {
                let page = try await graph.driveDelta(token: token)
                for item in page.items where !item.isFolder {
                    guard let relative = Self.relativePath(
                        parentPath: item.parentPath, name: item.name, under: folderPath
                    ) else { continue }
                    if item.isDeleted {
                        deletions.append(relative)
                    } else {
                        changes.append((relative, item.id, item.eTag, item.size, item.lastModified))
                    }
                }
                if let next = page.nextToken {
                    syncState.setValue(next, forKey: deltaTokenKey)
                }
            } catch GraphError.requestFailed(let status, _) where status == 410 {
                // Token expired: full re-list below, then a fresh baseline.
                syncState.setValue(nil, forKey: deltaTokenKey)
            }
        }

        if syncState.value(forKey: deltaTokenKey) == nil {
            let items = try await graph.listDriveFiles(
                folderPath: folderPath, excludingTopLevelFolders: []
            )
            changes = items.map { ($0.relativePath, $0.id, $0.eTag, $0.size, $0.lastModified) }
            if let baseline = try await graph.driveDeltaBaseline() {
                syncState.setValue(baseline, forKey: deltaTokenKey)
            }
        }

        for change in changes {
            let existing = index[change.relativePath]
            if let existing, existing.eTag == change.eTag, change.eTag != nil { continue }

            var entry = IndexEntry(
                id: change.id, eTag: change.eTag, size: change.size,
                contentCached: false, lastModified: change.lastModified
            )
            let ext = (change.relativePath as NSString).pathExtension.lowercased()
            if eagerExtensions.contains(ext) {
                do {
                    let data = try await graph.downloadDriveItem(id: change.id)
                    try writeCacheFile(relativePath: change.relativePath, data: data)
                    entry.contentCached = true
                    report.downloaded += 1
                } catch {
                    report.warnings.append("download failed: \(change.relativePath) — \(error.localizedDescription)")
                    continue
                }
            } else if existing?.contentCached == true {
                // Content changed remotely: drop the stale copy, re-fetch lazily.
                try? FileManager.default.removeItem(
                    at: cacheRoot.appendingPathComponent(change.relativePath)
                )
            }
            index[change.relativePath] = entry
        }

        // Audit-archive policy: remote deletions are surfaced, never mirrored.
        for deletion in deletions where index[deletion] != nil {
            report.warnings.append("deleted in OneDrive but kept locally: \(deletion)")
        }

        saveIndex()
        return report
    }

    /// Download every indexed file whose content isn't cached yet (full
    /// offline mirror). Returns the number downloaded.
    public func hydrate() async throws -> Int {
        loadIndexIfNeeded()
        var downloaded = 0
        for (relativePath, entry) in index where !entry.contentCached {
            let data = try await graph.downloadDriveItem(id: entry.id)
            try writeCacheFile(relativePath: relativePath, data: data)
            var updated = entry
            updated.contentCached = true
            index[relativePath] = updated
            downloaded += 1
        }
        saveIndex()
        return downloaded
    }

    // MARK: - Push (staging → cloud)

    public func push() async throws -> SyncReport {
        loadIndexIfNeeded()
        var report = SyncReport()

        for (relativePath, url) in stagedFiles() {
            do {
                let data = try Data(contentsOf: url)
                let remotePath = "\(folderPath)/\(relativePath)"
                let existing = index[relativePath]

                let uploaded: GraphMailClient.UploadedItem
                if let eTag = existing?.eTag {
                    do {
                        uploaded = try await graph.uploadDriveItem(
                            path: remotePath, data: data, conflictBehavior: .replace, ifMatch: eTag
                        )
                    } catch GraphError.requestFailed(let status, _) where status == 412 {
                        // Remote changed since we cached it: last writer wins.
                        uploaded = try await graph.uploadDriveItem(
                            path: remotePath, data: data, conflictBehavior: .replace
                        )
                    }
                } else {
                    do {
                        uploaded = try await graph.uploadDriveItem(
                            path: remotePath, data: data, conflictBehavior: .fail
                        )
                    } catch GraphError.requestFailed(let status, _) where status == 409 {
                        // Already exists (e.g. duplicate ingest replay): overwrite —
                        // pushes are idempotent by content for write-once files.
                        uploaded = try await graph.uploadDriveItem(
                            path: remotePath, data: data, conflictBehavior: .replace
                        )
                    }
                }

                try writeCacheFile(relativePath: relativePath, data: data)
                try? FileManager.default.removeItem(at: url)
                index[relativePath] = IndexEntry(
                    id: uploaded.id, eTag: uploaded.eTag, size: data.count,
                    contentCached: true, lastModified: Date()
                )
                report.uploaded += 1
            } catch {
                // Stays in staging; retried on the next push.
                report.warnings.append("upload failed: \(relativePath) — \(error.localizedDescription)")
            }
        }

        saveIndex()
        return report
    }

    /// Relative paths of files waiting in staging (pending upload).
    public func pendingUploads() -> [String] {
        stagedFiles().map(\.key).sorted()
    }

    // MARK: - Internals

    /// Maps a Graph parentReference path + item name to a path relative to the
    /// synced folder; nil when the item lives outside it. Handles both
    /// "/drive/root:/…" and "/drives/{id}/root:/…" forms.
    static func relativePath(parentPath: String?, name: String, under folder: String) -> String? {
        guard let parentPath, !name.isEmpty,
              let range = parentPath.range(of: "root:") else { return nil }
        var sub = String(parentPath[range.upperBound...])
        if let decoded = sub.removingPercentEncoding {
            sub = decoded
        }
        let prefix = "/" + folder
        if sub == prefix { return name }
        guard sub.hasPrefix(prefix + "/") else { return nil }
        let directory = String(sub.dropFirst(prefix.count + 1))
        return directory.isEmpty ? name : "\(directory)/\(name)"
    }

    private func stagedFiles() -> [String: URL] {
        Self.regularFiles(under: stagingRoot)
    }

    private func writeCacheFile(relativePath: String, data: Data) throws {
        let url = cacheRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func loadIndexIfNeeded() {
        guard !indexLoaded else { return }
        indexLoaded = true
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        index = (try? decoder.decode([String: IndexEntry].self, from: data)) ?? [:]
    }

    private func saveIndex() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(index) {
            try? data.write(to: indexURL)
        }
    }
}
