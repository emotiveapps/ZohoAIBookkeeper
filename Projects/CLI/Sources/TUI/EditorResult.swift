import Foundation
import ZohoBooksClient
import BookkeeperCore

/// Result of editing a transaction
public enum EditorResult {
    case save(CategorizedTransaction)
    case skip
    case quit
}
