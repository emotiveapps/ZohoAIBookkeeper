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
    case viewOnWebButton = 6

    public var label: String {
        switch self {
        case .transactionType: return "Type"
        case .vendor: return "Vendor"
        case .category: return "Category"
        case .description: return "Description"
        case .saveButton: return "SAVE"
        case .skipButton: return "SKIP"
        case .viewOnWebButton: return "VIEW ON WEB"
        }
    }

    public var next: EditableField {
        EditableField(rawValue: (self.rawValue + 1) % EditableField.allCases.count) ?? .transactionType
    }

    public var previous: EditableField {
        EditableField(rawValue: (self.rawValue - 1 + EditableField.allCases.count) % EditableField.allCases.count) ?? .viewOnWebButton
    }
}
