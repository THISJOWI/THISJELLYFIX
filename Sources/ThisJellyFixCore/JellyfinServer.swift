import Foundation

public struct JellyfinServer: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let baseURL: URL
    public let name: String

    public init(id: UUID = UUID(), baseURL: URL, name: String) {
        self.id = id
        self.baseURL = baseURL
        self.name = name
    }
}

public enum ServerAddressError: LocalizedError, Equatable {
    case empty
    case invalid
    case unsupportedScheme

    public var errorDescription: String? {
        switch self {
        case .empty: "Introduce la dirección de tu servidor Jellyfin."
        case .invalid: "La dirección del servidor no es válida."
        case .unsupportedScheme: "Usa una dirección http o https."
        }
    }
}

public enum ServerAddress {
    public static func normalizedURL(from input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServerAddressError.empty }

        let address = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw ServerAddressError.invalid
        }

        components.scheme = scheme
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let normalized = components.url else { throw ServerAddressError.invalid }
        return normalized
    }
}
