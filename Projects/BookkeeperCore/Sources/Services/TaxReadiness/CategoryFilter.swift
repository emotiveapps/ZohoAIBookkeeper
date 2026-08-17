import Foundation
import ZohoBooksClient


/// Which chart-of-accounts entries a spend can be categorized against.
/// Period expenses plus inventory/COGS accounts (inventory purchases are
/// recorded as assets at purchase time; see CLAUDE.md on LEGO/COGS handling).
public enum CategoryFilter {
    public static func spendingCategories(from accounts: [ZBAccount]) -> [String] {
        accounts
            .filter { account in
                let type = (account.accountType ?? "").lowercased()
                if ["expense", "cost_of_goods_sold", "stock"].contains(type) { return true }
                return (account.accountName ?? "").lowercased().contains("inventory")
            }
            .compactMap { $0.accountName }
            .sorted()
    }
}

