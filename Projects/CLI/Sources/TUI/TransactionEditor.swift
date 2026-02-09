import Foundation
import ZohoBooksClient
import BookkeeperCore

/// Editable field types in the transaction editor
public enum EditableField: Int, CaseIterable {
    case transactionType = 0
    case vendor = 1
    case category = 2
    case description = 3
    case saveButton = 4
    case skipButton = 5

    public var label: String {
        switch self {
        case .transactionType: return "Type"
        case .vendor: return "Vendor"
        case .category: return "Category"
        case .description: return "Description"
        case .saveButton: return "SAVE"
        case .skipButton: return "SKIP"
        }
    }

    public var next: EditableField {
        EditableField(rawValue: (self.rawValue + 1) % EditableField.allCases.count) ?? .transactionType
    }

    public var previous: EditableField {
        EditableField(rawValue: (self.rawValue - 1 + EditableField.allCases.count) % EditableField.allCases.count) ?? .skipButton
    }
}

/// Result of editing a transaction
public enum EditorResult {
    case save(CategorizedTransaction)
    case skip
    case quit
}

/// Interactive transaction editor
public final class TransactionEditor {
    private let terminal: Terminal
    private var transaction: CategorizedTransaction
    private var currentField: EditableField = .transactionType
    private var isEditing: Bool = false
    private var editBuffer: String = ""

    private let transactionTypes: [TransactionType]
    private let categories: [String]
    private let vendors: [String]
    private let bankAccounts: [ZBBankAccount]
    private let accountType: String

    private let debugLines: [String]

    private let boxWidth = 70
    private let boxHeight = 16
    private let startRow = 2
    private let startCol = 3

    public init(
        terminal: Terminal,
        transaction: CategorizedTransaction,
        categories: [String],
        vendors: [String],
        bankAccounts: [ZBBankAccount],
        accountType: String = "bank",
        debugLines: [String] = []
    ) {
        self.terminal = terminal
        self.transaction = transaction
        self.categories = categories
        self.vendors = vendors
        self.bankAccounts = bankAccounts
        self.accountType = accountType
        self.debugLines = debugLines

        // Filter transaction types based on debit/credit and account type
        self.transactionTypes = TransactionType.availableTypes(
            isDebit: transaction.transaction.isDebit,
            accountType: accountType
        )
    }

    /// Run the editor and return the result
    public func run() -> EditorResult {
        draw()

        while true {
            let key = terminal.readKey()

            switch key {
            case .ctrlC, .ctrlQ:
                return .quit

            case .escape:
                if isEditing {
                    isEditing = false
                    draw()
                }

            case .tab:
                currentField = currentField.next
                draw()

            case .shiftTab:
                currentField = currentField.previous
                draw()

            case .down:
                if !isEditing {
                    currentField = currentField.next
                    draw()
                } else {
                    cycleFieldValue(forward: true)
                    draw()
                }

            case .up:
                if !isEditing {
                    currentField = currentField.previous
                    draw()
                } else {
                    cycleFieldValue(forward: false)
                    draw()
                }

            case .left:
                if currentField == .skipButton {
                    currentField = .saveButton
                    draw()
                } else if isEditing {
                    cycleFieldValue(forward: false)
                    draw()
                }

            case .right:
                if currentField == .saveButton {
                    currentField = .skipButton
                    draw()
                } else if isEditing {
                    cycleFieldValue(forward: true)
                    draw()
                } else if currentField == .skipButton {
                    return .skip
                }

            case .enter:
                switch currentField {
                case .saveButton:
                    return .save(transaction)
                case .skipButton:
                    return .skip
                default:
                    if isEditing {
                        commitEdit()
                    } else {
                        startEditing()
                    }
                    draw()
                }

            case .backspace:
                if isEditing && !editBuffer.isEmpty {
                    editBuffer.removeLast()
                    draw()
                }

            case .char(let c):
                if isEditing {
                    editBuffer.append(c)
                    draw()
                }

            default:
                break
            }
        }
    }

    private func draw() {
        terminal.clearScreen()

        // Draw main box
        terminal.drawBox(
            row: startRow,
            col: startCol,
            width: boxWidth,
            height: boxHeight,
            title: "Transaction \(transaction.transaction.transactionId.prefix(8))..."
        )

        // Transaction details header
        let amount = transaction.transaction.displayAmount
        let desc = String(transaction.transaction.displayDescription.prefix(40))
        let date = transaction.transaction.date

        let isExpense = TransactionType.isUserExpense(isDebit: transaction.transaction.isDebit, accountType: accountType)
        let amountColor = isExpense ? Terminal.brightRed : Terminal.brightGreen
        terminal.printAt(
            row: startRow + 1,
            col: startCol + 2,
            text: "\(amountColor)\(amount)\(Terminal.reset)  \(Terminal.dim)\(date)\(Terminal.reset)"
        )
        terminal.printAt(
            row: startRow + 2,
            col: startCol + 2,
            text: "\(Terminal.white)\(desc)\(Terminal.reset)"
        )

        // Separator
        terminal.drawSeparator(row: startRow + 3, col: startCol, width: boxWidth)

        // Confidence indicator
        let confidence = transaction.suggestion.confidence
        let confidenceColor = confidence >= 80 ? Terminal.brightGreen :
                              confidence >= 50 ? Terminal.brightYellow : Terminal.brightRed
        terminal.printAt(
            row: startRow + 4,
            col: startCol + 2,
            text: "AI Confidence: \(confidenceColor)\(confidence)%\(Terminal.reset)"
        )

        // Editable fields
        let fieldStartRow = startRow + 5
        let fieldCol = startCol + 2
        let fieldWidth = boxWidth - 6

        // Transaction Type
        terminal.printField(
            row: fieldStartRow,
            col: fieldCol,
            label: "Type",
            value: transaction.selectedType.displayName,
            selected: currentField == .transactionType,
            width: fieldWidth
        )

        // Vendor (only for expenses)
        if transaction.selectedType == .expense {
            let vendorValue = isEditing && currentField == .vendor ? editBuffer : transaction.vendorName
            terminal.printField(
                row: fieldStartRow + 1,
                col: fieldCol,
                label: "Vendor",
                value: vendorValue.isEmpty ? "(none)" : vendorValue,
                selected: currentField == .vendor,
                width: fieldWidth
            )
        } else {
            terminal.printAt(
                row: fieldStartRow + 1,
                col: fieldCol,
                text: "\(Terminal.dim)Vendor: N/A for this type\(Terminal.reset)"
            )
        }

        // Category
        terminal.printField(
            row: fieldStartRow + 2,
            col: fieldCol,
            label: "Category",
            value: transaction.category,
            selected: currentField == .category,
            width: fieldWidth
        )

        // Description
        let descValue = isEditing && currentField == .description ? editBuffer : transaction.description
        terminal.printField(
            row: fieldStartRow + 3,
            col: fieldCol,
            label: "Desc",
            value: descValue,
            selected: currentField == .description,
            width: fieldWidth
        )

        // Separator before buttons
        terminal.drawSeparator(row: startRow + 10, col: startCol, width: boxWidth)

        // Buttons
        let buttonRow = startRow + 11
        terminal.printButton(
            row: buttonRow,
            col: startCol + 15,
            label: "SAVE",
            selected: currentField == .saveButton,
            color: Terminal.brightGreen
        )
        terminal.printButton(
            row: buttonRow,
            col: startCol + 30,
            label: "SKIP",
            selected: currentField == .skipButton,
            color: Terminal.brightYellow
        )

        // URL
        terminal.printAt(
            row: startRow + 13,
            col: startCol + 2,
            text: "\(Terminal.dim)URL: \(Terminal.brightBlue)\(transaction.transaction.zohoURL)\(Terminal.reset)"
        )

        // Help text
        terminal.printAt(
            row: startRow + boxHeight + 1,
            col: startCol,
            text: "\(Terminal.dim)Tab/↑↓: Navigate | Enter: Select/Edit | ←→: Change value | Ctrl+Q: Quit\(Terminal.reset)"
        )

        // Reasoning (if space allows)
        var debugRow = startRow + boxHeight + 2
        if !transaction.suggestion.reasoning.isEmpty {
            let reasoning = String(transaction.suggestion.reasoning.prefix(boxWidth - 4))
            terminal.printAt(
                row: debugRow,
                col: startCol,
                text: "\(Terminal.dim)AI: \(reasoning)\(Terminal.reset)"
            )
            debugRow += 1
        }

        // History debug info
        for line in debugLines {
            terminal.printAt(
                row: debugRow,
                col: startCol,
                text: "\(Terminal.dim)\(line)\(Terminal.reset)"
            )
            debugRow += 1
        }

        fflush(stdout)
    }

    private func startEditing() {
        switch currentField {
        case .transactionType, .category:
            // These use cycling, not text editing
            cycleFieldValue(forward: true)
        case .vendor:
            isEditing = true
            editBuffer = transaction.vendorName
        case .description:
            isEditing = true
            editBuffer = transaction.description
        default:
            break
        }
    }

    private func commitEdit() {
        switch currentField {
        case .vendor:
            transaction.vendorName = editBuffer
        case .description:
            transaction.description = editBuffer
        default:
            break
        }
        isEditing = false
        editBuffer = ""
    }

    private func cycleFieldValue(forward: Bool) {
        switch currentField {
        case .transactionType:
            if let currentIndex = transactionTypes.firstIndex(of: transaction.selectedType) {
                let nextIndex = forward ?
                    (currentIndex + 1) % transactionTypes.count :
                    (currentIndex - 1 + transactionTypes.count) % transactionTypes.count
                transaction.selectedType = transactionTypes[nextIndex]
            }

        case .category:
            if let currentIndex = categories.firstIndex(of: transaction.category) {
                let nextIndex = forward ?
                    (currentIndex + 1) % categories.count :
                    (currentIndex - 1 + categories.count) % categories.count
                transaction.category = categories[nextIndex]
            } else if !categories.isEmpty {
                transaction.category = categories[0]
            }

        case .vendor:
            // Cycle through known vendors
            if let currentIndex = vendors.firstIndex(of: transaction.vendorName) {
                let nextIndex = forward ?
                    (currentIndex + 1) % vendors.count :
                    (currentIndex - 1 + vendors.count) % vendors.count
                transaction.vendorName = vendors[nextIndex]
                editBuffer = transaction.vendorName
            } else if !vendors.isEmpty {
                transaction.vendorName = vendors[0]
                editBuffer = transaction.vendorName
            }

        default:
            break
        }
    }
}
