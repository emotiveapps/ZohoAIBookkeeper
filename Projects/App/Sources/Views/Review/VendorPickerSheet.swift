import SwiftUI
import BookkeeperCore

/// Searchable vendor picker with free-text creation.
struct VendorPickerSheet: View {
    let vendors: [String]
    let selection: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if !selection.isEmpty {
                    Button("Remove vendor", role: .destructive) {
                        onSelect("")
                        dismiss()
                    }
                }

                if showCreateRow {
                    Button {
                        onSelect(trimmedQuery)
                        dismiss()
                    } label: {
                        Label("Use \"\(trimmedQuery)\"", systemImage: "plus.circle")
                    }
                }

                ForEach(filtered, id: \.self) { vendor in
                    Button {
                        onSelect(vendor)
                        dismiss()
                    } label: {
                        HStack {
                            Text(vendor)
                            Spacer()
                            if vendor == selection {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .searchable(text: $query, prompt: "Search or type a new vendor")
            .navigationTitle("Vendor")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var filtered: [String] {
        guard !query.isEmpty else { return vendors }
        return vendors.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var showCreateRow: Bool {
        !trimmedQuery.isEmpty && !vendors.contains { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }
    }
}
