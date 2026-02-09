import Foundation
import BookkeeperCore

/// A hierarchical category picker for the terminal
public final class CategoryPicker {
    private let terminal: Terminal
    private let categoryConfigs: [CategoryConfig]
    private let currentCategory: String

    /// Flattened list of display rows
    private struct PickerRow {
        let name: String
        let isParent: Bool
        let indent: Int
    }

    private var rows: [PickerRow] = []
    private var selectedIndex: Int = 0
    private var scrollOffset: Int = 0
    private let maxVisibleRows: Int

    private let startRow: Int
    private let startCol: Int
    private let pickerWidth = 50

    public init(terminal: Terminal, categoryConfigs: [CategoryConfig], currentCategory: String, startRow: Int = 2, startCol: Int = 3) {
        self.terminal = terminal
        self.categoryConfigs = categoryConfigs
        self.currentCategory = currentCategory
        self.startRow = startRow
        self.startCol = startCol

        let termSize = terminal.getSize()
        // Limit visible rows to available space below startRow
        self.maxVisibleRows = min(termSize.rows - startRow - 4, 20)

        // Build flattened rows
        for config in categoryConfigs {
            rows.append(PickerRow(name: config.name, isParent: config.children != nil && !(config.children!.isEmpty), indent: 0))
            if let children = config.children {
                for child in children {
                    rows.append(PickerRow(name: child, isParent: false, indent: 2))
                }
            }
        }

        // Select current category
        if let idx = rows.firstIndex(where: { $0.name == currentCategory }) {
            selectedIndex = idx
            // Center the selection in view
            scrollOffset = max(0, selectedIndex - maxVisibleRows / 2)
        }
    }

    /// Run the picker and return the selected category name, or nil if cancelled
    public func run() -> String? {
        draw()

        while true {
            let key = terminal.readKey()

            switch key {
            case .up:
                if selectedIndex > 0 {
                    selectedIndex -= 1
                    ensureVisible()
                    draw()
                }

            case .down:
                if selectedIndex < rows.count - 1 {
                    selectedIndex += 1
                    ensureVisible()
                    draw()
                }

            case .enter:
                return rows[selectedIndex].name

            case .escape, .ctrlQ:
                return nil

            default:
                break
            }
        }
    }

    private func ensureVisible() {
        if selectedIndex < scrollOffset {
            scrollOffset = selectedIndex
        } else if selectedIndex >= scrollOffset + maxVisibleRows {
            scrollOffset = selectedIndex - maxVisibleRows + 1
        }
    }

    private func draw() {
        // Clear only the picker area (from startRow downward)
        let termSize = terminal.getSize()
        for r in startRow...(startRow + maxVisibleRows + 4) {
            if r <= termSize.rows {
                terminal.printAt(row: r, col: startCol, text: String(repeating: " ", count: pickerWidth + 4))
            }
        }

        // Title
        terminal.printAt(
            row: startRow,
            col: startCol,
            text: "\(Terminal.bold)Select Category\(Terminal.reset)  \(Terminal.dim)(↑↓ navigate, Enter select, Esc cancel)\(Terminal.reset)"
        )

        // Draw rows
        let visibleEnd = min(scrollOffset + maxVisibleRows, rows.count)
        for i in scrollOffset..<visibleEnd {
            let row = rows[i]
            let displayRow = startRow + 2 + (i - scrollOffset)
            let indent = String(repeating: " ", count: row.indent)
            let prefix: String
            let style: String

            if i == selectedIndex {
                prefix = "▸ "
                style = "\(Terminal.bgBlue)\(Terminal.esc)97m\(Terminal.bold)"
            } else if row.name == currentCategory {
                prefix = "  "
                style = Terminal.brightCyan
            } else {
                prefix = "  "
                style = row.isParent ? Terminal.white : Terminal.dim
            }

            let text = "\(indent)\(prefix)\(row.name)"
            let padded = text.padding(toLength: pickerWidth, withPad: " ", startingAt: 0)
            terminal.printAt(
                row: displayRow,
                col: startCol,
                text: "\(style)\(padded)\(Terminal.reset)"
            )
        }

        // Scroll indicators
        if scrollOffset > 0 {
            terminal.printAt(row: startRow + 1, col: startCol + pickerWidth - 3, text: "\(Terminal.dim)▲\(Terminal.reset)")
        }
        if visibleEnd < rows.count {
            terminal.printAt(row: startRow + 2 + maxVisibleRows, col: startCol + pickerWidth - 3, text: "\(Terminal.dim)▼\(Terminal.reset)")
        }

        fflush(stdout)
    }
}
