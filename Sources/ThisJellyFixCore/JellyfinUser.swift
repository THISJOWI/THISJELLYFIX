import Foundation

public struct JellyfinUser: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let primaryImageTag: String?

    public init(id: String, name: String, primaryImageTag: String? = nil) {
        self.id = id
        self.name = name
        self.primaryImageTag = primaryImageTag
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case primaryImageTag = "PrimaryImageTag"
    }
}
