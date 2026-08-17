import Foundation


public struct CategoryConfig: Codable, Sendable {
    public let name: String
    public let children: [String]?

    public init(name: String, children: [String]? = nil) {
        self.name = name
        self.children = children
    }
}

