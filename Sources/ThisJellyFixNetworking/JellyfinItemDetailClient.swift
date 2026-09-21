import Foundation
import ThisJellyFixCore

public protocol JellyfinItemDetailProviding: Sendable {
    func fetchItemDetail(userId: String, serverURL: URL, token: String, itemId: String) async throws -> JellyfinItemDetail
}

public struct JellyfinItemDetailClient: JellyfinItemDetailProviding {
    private let session: any JellyfinNetworkSession

    public init(session: any JellyfinNetworkSession = URLSession.shared) {
        self.session = session
    }

    public func fetchItemDetail(userId: String, serverURL: URL, token: String, itemId: String) async throws -> JellyfinItemDetail {
        let url = serverURL.appendingPathComponent("Users/\(userId)/Items/\(itemId)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(
            "MediaBrowser Client=\"thisjellyfix\", Device=\"\(deviceOS)\", DeviceId=\"\", Version=\"0.1\", Token=\"\(token)\"",
            forHTTPHeaderField: "X-Emby-Authorization"
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibraryError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw LibraryError.unauthorized
        default: throw LibraryError.serverError(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(JellyfinItemDetail.self, from: data)
    }

    private var deviceOS: String {
        #if os(macOS)
        "macOS"
        #elseif os(iOS)
        "iOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(visionOS)
        "visionOS"
        #else
        "unknown"
        #endif
    }
}
