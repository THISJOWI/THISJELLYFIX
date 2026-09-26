import Foundation
import ThisJellyFixCore
import ThisJellyFixNetworking

final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = NSLock()

    func save(key: String, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        store[key] = value
    }

    func read(key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    func delete(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        store[key] = nil
    }

    func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
    }
}

/// Replayable network spy shared by the Discovery test suite.
final class SpySession: JellyfinNetworkSession, @unchecked Sendable {
    let mockData: Data
    let mockStatusCode: Int
    let mockError: Error?
    private(set) var capturedRequest: URLRequest?

    /// Requests in order, for assertions across multiple calls.
    private(set) var capturedRequests: [URLRequest] = []

    init(json: String, statusCode: Int = 200, error: Error? = nil) {
        self.mockData = Data(json.utf8)
        self.mockStatusCode = statusCode
        self.mockError = error
    }

    init(data: Data, statusCode: Int = 200, error: Error? = nil) {
        self.mockData = data
        self.mockStatusCode = statusCode
        self.mockError = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequest = request
        capturedRequests.append(request)
        if let mockError { throw mockError }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: mockStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (mockData, response)
    }
}

extension URL {
    var queryParameters: [String: String] {
        guard let items = URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        return items.reduce(into: [:]) { $0[$1.name] = $1.value }
    }
}
