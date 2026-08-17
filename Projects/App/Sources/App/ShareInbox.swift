import Foundation

/// Reads the app-group ingest queue written by the share extension.
/// Contract (see ShareExtension/Sources/ShareViewController.swift):
/// `IngestQueue/<id>.<ext>` plus `<id>.metadata.json` with
/// originalName / contentType / sharedAt.
enum ShareInbox {
    static let appGroup = "group.com.emotiveapps.ZohoBookkeeper"

    struct Item: Identifiable, Sendable {
        let id: String
        let fileURL: URL
        let metadataURL: URL
        let originalName: String
        let contentType: String
        let sharedAt: Date?
    }

    static func queueURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("IngestQueue", isDirectory: true)
    }

    static func pendingItems() -> [Item] {
        guard let queue = queueURL(),
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: queue, includingPropertiesForKeys: nil
              ) else { return [] }

        return contents
            .filter { $0.pathExtension != "json" }
            .compactMap { fileURL in
                let id = fileURL.deletingPathExtension().lastPathComponent
                let metadataURL = queue.appendingPathComponent("\(id).metadata.json")

                var originalName = fileURL.lastPathComponent
                var contentType = fileURL.pathExtension.lowercased() == "pdf"
                    ? "application/pdf" : "image/jpeg"
                var sharedAt: Date?

                if let data = try? Data(contentsOf: metadataURL),
                   let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    originalName = metadata["originalName"] as? String ?? originalName
                    contentType = metadata["contentType"] as? String ?? contentType
                    sharedAt = (metadata["sharedAt"] as? String)
                        .flatMap { ISO8601DateFormatter().date(from: $0) }
                }

                return Item(
                    id: id,
                    fileURL: fileURL,
                    metadataURL: metadataURL,
                    originalName: originalName,
                    contentType: contentType,
                    sharedAt: sharedAt
                )
            }
            .sorted { ($0.sharedAt ?? .distantPast) < ($1.sharedAt ?? .distantPast) }
    }

    /// Remove a queue item after it's been archived (the ReceiptStore copy is
    /// canonical — this is a transfer queue, not the archive).
    static func remove(_ item: Item) {
        try? FileManager.default.removeItem(at: item.fileURL)
        try? FileManager.default.removeItem(at: item.metadataURL)
    }
}
