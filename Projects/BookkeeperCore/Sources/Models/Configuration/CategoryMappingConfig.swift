import Foundation

public struct CategoryMappingConfig: Codable, Sendable {
    public let categories: [CategoryConfig]

    public init(categories: [CategoryConfig]) {
        self.categories = categories
    }

    public var allCategoryNames: [String] {
        categories.flatMap { category -> [String] in
            var names = [category.name]
            if let children = category.children {
                names.append(contentsOf: children)
            }
            return names
        }
    }
}
