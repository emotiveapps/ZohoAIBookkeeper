import Foundation

/// A searchable vendor picker for the terminal
public final class VendorPicker {
    private let terminal: Terminal
    private let vendors: [String]
    private let currentVendor: String

    private var searchBuffer: String = ""
    private var filteredVendors: [String] = []
    private var selectedIndex: Int = 0
    private var scrollOffset: Int = 0
    private let maxVisibleRows: Int

    private let startRow: Int
    private let startCol: Int
    private let pickerWidth = 50

    public init(terminal: Terminal, vendors: [String], currentVendor: String, startRow: Int = 2, startCol: Int = 3) {
        self.terminal = terminal
        self.vendors = vendors.sorted()
        self.currentVendor = currentVendor
        self.startRow = startRow
        self.startCol = startCol

        let termSize = terminal.getSize()
        self.maxVisibleRows = min(termSize.rows - startRow - 6, 18)

        // Start with all vendors visible
        self.filteredVendors = self.vendors

        // Select current vendor if present
        if let idx = filteredVendors.firstIndex(of: currentVendor) {
            selectedIndex = idx
            scrollOffset = max(0, selectedIndex - maxVisibleRows / 2)
        }
    }

    /// Run the picker and return the selected vendor name, or nil if cancelled
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
                if selectedIndex < filteredVendors.count - 1 {
                    selectedIndex += 1
                    ensureVisible()
                    draw()
                }

            case .enter:
                if !filteredVendors.isEmpty {
                    return filteredVendors[selectedIndex]
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

            case .tab:
                // Tab to autocomplete with the selected item
                if !filteredVendors.isEmpty {
                    return filteredVendors[selectedIndex]
                }

            default:
                break
            }
        }
    }

    private func updateFilter() {
        if searchBuffer.isEmpty {
            filteredVendors = vendors
        } else {
            let query = searchBuffer.lowercased()
            filteredVendors = vendors.filter { $0.lowercased().contains(query) }
        }
        // Reset selection to top (or to first match)
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

    private func draw() {
        // Clear only the picker area
        let termSize = terminal.getSize()
        for r in startRow...(startRow + maxVisibleRows + 6) {
            if r <= termSize.rows {
                terminal.printAt(row: r, col: startCol, text: String(repeating: " ", count: pickerWidth + 4))
            }
        }

        // Title
        terminal.printAt(
            row: startRow,
            col: startCol,
            text: "\(Terminal.bold)Select Vendor\(Terminal.reset)  \(Terminal.dim)(type to filter, ↑↓ navigate, Enter select, Esc cancel)\(Terminal.reset)"
        )

        // Search field
        let searchDisplay = searchBuffer.isEmpty ? "\(Terminal.dim)type to search...\(Terminal.reset)" : searchBuffer
        terminal.printAt(
            row: startRow + 1,
            col: startCol,
            text: "\(Terminal.bgBlue)\(Terminal.esc)97m 🔍 \(searchDisplay) \(Terminal.reset)"
        )

        // Draw filtered vendor rows
        let visibleEnd = min(scrollOffset + maxVisibleRows, filteredVendors.count)

        if filteredVendors.isEmpty {
            terminal.printAt(
                row: startRow + 3,
                col: startCol,
                text: "\(Terminal.dim)  No matching vendors\(Terminal.reset)"
            )
        } else {
            for i in scrollOffset..<visibleEnd {
                let vendor = filteredVendors[i]
                let displayRow = startRow + 3 + (i - scrollOffset)
                let prefix: String
                let style: String

                if i == selectedIndex {
                    prefix = "▸ "
                    style = "\(Terminal.bgBlue)\(Terminal.esc)97m\(Terminal.bold)"
                } else if vendor == currentVendor {
                    prefix = "  "
                    style = Terminal.brightCyan
                } else {
                    prefix = "  "
                    style = Terminal.white
                }

                let text = "\(prefix)\(vendor)"
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
        if visibleEnd < filteredVendors.count {
            terminal.printAt(row: startRow + 3 + maxVisibleRows, col: startCol + pickerWidth - 3, text: "\(Terminal.dim)▼\(Terminal.reset)")
        }

        // Count indicator
        terminal.printAt(
            row: startRow + 3 + min(maxVisibleRows, max(filteredVendors.count, 1)) + 1,
            col: startCol,
            text: "\(Terminal.dim)\(filteredVendors.count) of \(vendors.count) vendors\(Terminal.reset)"
        )

        fflush(stdout)
    }
}
