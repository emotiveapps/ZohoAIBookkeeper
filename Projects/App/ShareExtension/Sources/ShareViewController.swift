import UIKit
import UniformTypeIdentifiers

/// Share-sheet entry point: saves shared PDFs/images into the app-group ingest
/// queue and finishes. The main app parses, archives, and matches them the
/// next time it's opened (see ShareInbox + ReceiptsView).
///
/// Deliberately self-contained (no BookkeeperCore import): a share extension
/// should stay tiny and finish fast.
final class ShareViewController: UIViewController {
    private static let appGroup = "group.com.emotiveapps.ZohoBookkeeper"
    private static let queueDirectory = "IngestQueue"

    private let checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        checkmark.tintColor = .systemGreen
        checkmark.contentMode = .scaleAspectFit
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Saving to Bookkeeper…"
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        checkmark.isHidden = true

        view.addSubview(checkmark)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            checkmark.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            checkmark.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            checkmark.widthAnchor.constraint(equalToConstant: 56),
            checkmark.heightAnchor.constraint(equalToConstant: 56),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: checkmark.bottomAnchor, constant: 12),
        ])

        Task { await saveSharedItems() }
    }

    private func saveSharedItems() async {
        var savedCount = 0

        if let queue = Self.queueURL() {
            let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
                .compactMap(\.attachments)
                .flatMap { $0 } ?? []

            for provider in providers {
                if let saved = await save(provider: provider, into: queue) {
                    savedCount += saved
                }
            }
        }

        label.text = savedCount > 0
            ? "Saved \(savedCount) receipt\(savedCount == 1 ? "" : "s") — open Bookkeeper to file"
            : "Nothing sharable found"
        checkmark.isHidden = savedCount == 0

        try? await Task.sleep(nanoseconds: 900_000_000)
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func save(provider: NSItemProvider, into queue: URL) async -> Int? {
        let supported: [UTType] = [.pdf, .image]
        guard let type = supported.first(where: {
            provider.hasItemConformingToTypeIdentifier($0.identifier)
        }) else { return nil }

        // Resolve the most specific registered type for a better extension/MIME.
        let specific = provider.registeredTypeIdentifiers
            .compactMap { UTType($0) }
            .first { $0.conforms(to: type) } ?? type

        var loaded = await loadData(provider: provider, typeIdentifier: specific.identifier)
        if loaded == nil && specific != type {
            loaded = await loadData(provider: provider, typeIdentifier: type.identifier)
        }
        guard let data = loaded else { return nil }

        let id = UUID().uuidString
        let ext = specific.preferredFilenameExtension ?? (type == .pdf ? "pdf" : "jpg")
        let fileURL = queue.appendingPathComponent("\(id).\(ext)")

        let metadata: [String: Any] = [
            "originalName": provider.suggestedName ?? "shared.\(ext)",
            "contentType": specific.preferredMIMEType ?? (type == .pdf ? "application/pdf" : "image/jpeg"),
            "sharedAt": ISO8601DateFormatter().string(from: Date()),
        ]

        do {
            try data.write(to: fileURL)
            let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            try metadataData.write(to: queue.appendingPathComponent("\(id).metadata.json"))
            return 1
        } catch {
            return nil
        }
    }

    private func loadData(provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func queueURL() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let queue = container.appendingPathComponent(queueDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        return queue
    }
}
