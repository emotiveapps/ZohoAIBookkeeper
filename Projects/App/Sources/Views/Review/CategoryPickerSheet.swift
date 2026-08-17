import SwiftUI
import BookkeeperCore

/// Searchable category picker. Shows the two-level hierarchy from config when
/// available, otherwise the flat Zoho expense-account list.
struct CategoryPickerSheet: View {
    let categoryConfigs: [CategoryConfig]
    let flatCategories: [String]
    let selection: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if categoryConfigs.isEmpty {
                    ForEach(filteredFlat, id: \.self) { category in
                        row(category)
                    }
                } else {
                    ForEach(filteredGroups, id: \.parent.name) { group in
                        Section {
                            row(group.parent.name)
                            ForEach(group.children, id: \.self) { child in
                                row(child, indented: true)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search categories")
            .navigationTitle("Category")
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

    private func row(_ name: String, indented: Bool = false) -> some View {
        Button {
            onSelect(name)
            dismiss()
        } label: {
            HStack {
                Text(name)
                    .padding(.leading, indented ? 16 : 0)
                Spacer()
                if name == selection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private var filteredFlat: [String] {
        guard !query.isEmpty else { return flatCategories }
        return flatCategories.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var filteredGroups: [(parent: CategoryConfig, children: [String])] {
        categoryConfigs.compactMap { config in
            let children = config.children ?? []
            guard !query.isEmpty else { return (config, children) }

            if config.name.localizedCaseInsensitiveContains(query) {
                return (config, children)
            }
            let matching = children.filter { $0.localizedCaseInsensitiveContains(query) }
            return matching.isEmpty ? nil : (config, matching)
        }
    }
}
