import Foundation
import BookkeeperCore

/// A reusable searchable picker for the terminal.
/// Supports both flat lists (vendors) and hierarchical lists (categories).
public final class SearchablePicker {

    /// A single row in the picker
    public struct Item {
        public let name: String
        public let isHeader: Bool
        public let indent: Int
        /// Which parent group this belongs to (for hierarchical filtering)
        public let group: String?

        public init(name: String, isHeader: Bool = false, indent: Int = 0, group: String? = nil) {
            self.name = name
            self.isHeader = isHeader
            self.indent = indent
            self.group = group
        }
    }

    private let terminal: Terminal
    private let title: String
    private let allItems: [Item]
    private let currentValue: String
    private let totalCount: Int

    private var searchBuffer: String = ""
    private var filteredItems: [Item] = []
    private var selectedIndex: Int = 0
    private var scrollOffset: Int = 0
    private let maxVisibleRows: Int

    private let startRow: Int
    private let startCol: Int
    private let pickerWidth = 50

    // MARK: - Factory methods

    /// Create a picker for a flat list of strings (e.g. vendors)
    public static func forFlatList(
        terminal: Terminal,
        title: String,
        items: [String],
        currentValue: String,
        startRow: Int = 2,
        startCol: Int = 3
    ) -> SearchablePicker {
        let pickerItems = items.sorted().map { Item(name: $0) }
        return SearchablePicker(
            terminal: terminal,
            title: title,
            items: pickerItems,
            currentValue: currentValue,
            startRow: startRow,
            startCol: startCol
        )
    }

    /// Create a picker for hierarchical categories
    public static func forCategories(
        terminal: Terminal,
        categoryConfigs: [CategoryConfig],
        currentValue: String,
        startRow: Int = 2,
        startCol: Int = 3
    ) -> SearchablePicker {
        var pickerItems: [Item] = []
        for config in categoryConfigs {
            let hasChildren = config.children != nil && !(config.children!.isEmpty)
            pickerItems.append(Item(name: config.name, isHeader: hasChildren, indent: 0, group: config.name))
            if let children = config.children {
                for child in children {
                    pickerItems.append(Item(name: child, isHeader: false, indent: 2, group: config.name))
                }
            }
        }
        return SearchablePicker(
            terminal: terminal,
            title: "Select Category",
            items: pickerItems,
            currentValue: currentValue,
            startRow: startRow,
            startCol: startCol
        )
    }

    // MARK: - Init

    public init(
        terminal: Terminal,
        title: String,
        items: [Item],
        currentValue: String,
        startRow: Int = 2,
        startCol: Int = 3
    ) {
        self.terminal = terminal
        self.title = title
        self.allItems = items
        self.currentValue = currentValue
        self.totalCount = items.filter { !$0.isHeader }.count
        self.startRow = startRow
        self.startCol = startCol

        let termSize = terminal.getSize()
        self.maxVisibleRows = min(termSize.rows - startRow - 6, 18)

        self.filteredItems = items

        // Select current value if present
        if let idx = filteredItems.firstIndex(where: { $0.name == currentValue }) {
            selectedIndex = idx
            scrollOffset = max(0, selectedIndex - maxVisibleRows / 2)
        }
    }

    // MARK: - Run

    /// Run the picker and return the selected name, or nil if cancelled
    public func run() -> String? {
        draw()

        while true {
            let key = terminal.readKey()

            switch key {
            case .up:
                moveSelection(forward: false)
                draw()

            case .down:
                moveSelection(forward: true)
                draw()

            case .enter, .tab:
                if !filteredItems.isEmpty {
                    return filteredItems[selectedIndex].name
                }

            case .escape, .ctrlQ:
                return nil

            case .backspace:
                if !searchBuffer.isEmpty {
                    searchBuffer.removeLast()
                    updateFilter()
                    draw()
                }

            case .char(let c):
                searchBuffer.append(c)
                updateFilter()
                draw()

            default:
                break
            }
        }
    }

    // MARK: - Navigation

    private func moveSelection(forward: Bool) {
        guard !filteredItems.isEmpty else { return }

        if forward {
            if selectedIndex < filteredItems.count - 1 {
                selectedIndex += 1
            }
        } else {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
        }
        ensureVisible()
    }

    // MARK: - Filtering

    private func updateFilter() {
        if searchBuffer.isEmpty {
            filteredItems = allItems
        } else {
            let query = searchBuffer.lowercased()
            // For hierarchical items, show parent headers when any child matches
            var matchingGroups: Set<String> = []
            var matchingNames: Set<String> = []

            for item in allItems {
                if item.name.lowercased().contains(query) {
                    matchingNames.insert(item.name)
                    if let group = item.group {
                        matchingGroups.insert(group)
                    }
                }
            }

            filteredItems = allItems.filter { item in
                // Include if the item itself matches
                if matchingNames.contains(item.name) { return true }
                // Include parent headers if any of their children match
                if item.isHeader, let group = item.group, matchingGroups.contains(group) { return true }
                return false
            }
        }

        selectedIndex = 0
        scrollOffset = 0
    }

    private func ensureVisible() {
        if selectedIndex < scrollOffset {
            scrollOffset = selectedIndex
        } else if selectedIndex >= scrollOffset + maxVisibleRows {
            scrollOffset = selectedIndex - maxVisibleRows + 1
        }
    }

    // MARK: - Drawing

    private func draw() {
        // Clear only the picker area
        let termSize = terminal.getSize()
        for r in startRow...(startRow + maxVisibleRows + 6) {
            if r <= termSize.rows {
                terminal.printAt(row: r, col: startCol, text: String(repeating: " ", count: pickerWidth + 30))
            }
        }

        // Title
        terminal.printAt(
            row: startRow,
            col: startCol,
            text: "\(Terminal.bold)\(title)\(Terminal.reset)  \(Terminal.dim)(type to filter, ↑↓ navigate, Enter select, Esc cancel)\(Terminal.reset)"
        )

        // Search field
        let searchDisplay = searchBuffer.isEmpty ? "\(Terminal.dim)type to search...\(Terminal.reset)" : searchBuffer
        terminal.printAt(
            row: startRow + 1,
            col: startCol,
            text: "\(Terminal.bgBlue)\(Terminal.esc)97m 🔍 \(searchDisplay) \(Terminal.reset)"
        )

        // Draw rows
        let visibleEnd = min(scrollOffset + maxVisibleRows, filteredItems.count)

        if filteredItems.isEmpty {
            terminal.printAt(
                row: startRow + 3,
                col: startCol,
                text: "\(Terminal.dim)  No matches\(Terminal.reset)"
            )
        } else {
            for i in scrollOffset..<visibleEnd {
                let item = filteredItems[i]
                let displayRow = startRow + 3 + (i - scrollOffset)
                let indent = String(repeating: " ", count: item.indent)
                let prefix: String
                let style: String

                if i == selectedIndex {
                    prefix = "▸ "
                    style = "\(Terminal.bgBlue)\(Terminal.esc)97m\(Terminal.bold)"
                } else if item.name == currentValue {
                    prefix = "  "
                    style = Terminal.brightCyan
                } else {
                    prefix = "  "
                    style = item.isHeader ? Terminal.white : Terminal.dim
                }

                let text = "\(indent)\(prefix)\(item.name)"
                let padded = text.padding(toLength: pickerWidth, withPad: " ", startingAt: 0)
                terminal.printAt(
                    row: displayRow,
                    col: startCol,
                    text: "\(style)\(padded)\(Terminal.reset)"
                )
            }
        }

        // Scroll indicators
        if scrollOffset > 0 {
            terminal.printAt(row: startRow + 2, col: startCol + pickerWidth - 3, text: "\(Terminal.dim)▲\(Terminal.reset)")
        }
        if visibleEnd < filteredItems.count {
            terminal.printAt(row: startRow + 3 + maxVisibleRows, col: startCol + pickerWidth - 3, text: "\(Terminal.dim)▼\(Terminal.reset)")
        }

        // Count indicator
        let filteredCount = filteredItems.filter { !$0.isHeader }.count
        terminal.printAt(
            row: startRow + 3 + min(maxVisibleRows, max(filteredItems.count, 1)) + 1,
            col: startCol,
            text: "\(Terminal.dim)\(filteredCount) of \(totalCount) items\(Terminal.reset)"
        )

        fflush(stdout)
    }
}
