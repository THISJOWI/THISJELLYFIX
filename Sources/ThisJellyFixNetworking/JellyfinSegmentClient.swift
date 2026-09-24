import Foundation
import ThisJellyFixCore

// MARK: - Protocol

public protocol JellyfinSegmentProviding: Sendable {
    /// Fetches skippable segments for an item.
    /// Primary: native Media Segments API (Jellyfin 10.10+, includes
    /// IntroSkipper and Chapter Segments Provider output).
    /// Fallback: item chapters classified by name.
    /// Returns `[]` when neither source yields usable segments.
    func fetchSegments(
        serverURL: URL,
        token: String,
        userId: String,
        itemId: String
    ) async throws -> [SegmentMarker]
}

// MARK: - Client

public struct JellyfinSegmentClient: JellyfinSegmentProviding {
    private let session: any JellyfinNetworkSession

    public init(session: any JellyfinNetworkSession = URLSession.shared) {
        self.session = session
    }

    public func fetchSegments(
        serverURL: URL,
        token: String,
        userId: String,
        itemId: String
    ) async throws -> [SegmentMarker] {
        // 1) Native Media Segments API
        do {
            let markers = try await fetchMediaSegments(serverURL: serverURL, token: token, itemId: itemId)
            if !markers.isEmpty {
                TJFLog("segments: mediaSegments count=\(markers.count)")
                return markers
            }
        } catch {
            // Auth problems must surface; anything else falls through to chapters.
            if let libError = error as? LibraryError, libError == .unauthorized { throw error }
            TJFLog("segments: mediaSegments failed: \(error)")
        }

        // 2) Fallback: chapters classified by name
        do {
            let markers = try await fetchChapterMarkers(serverURL: serverURL, token: token, userId: userId, itemId: itemId)
            if !markers.isEmpty {
                TJFLog("segments: chapters fallback count=\(markers.count)")
                return markers
            }
        } catch {
            if let libError = error as? LibraryError, libError == .unauthorized { throw error }
            TJFLog("segments: chapters failed: \(error)")
        }

        TJFLog("segments: none found")
        return []
    }

    // MARK: Media Segments

    private func fetchMediaSegments(serverURL: URL, token: String, itemId: String) async throws -> [SegmentMarker] {
        let url = serverURL.appendingPathComponent("MediaSegments/\(itemId)")
        let data = try await fetchData(from: url, token: token, allowNotFound: true)
        guard let data else { return [] } // endpoint not available (server < 10.10)

        let response = try JSONDecoder().decode(MediaSegmentsResponse.self, from: data)
        return response.items.compactMap { $0.marker }.filter(\.isValid)
    }

    // MARK: Chapters fallback

    private func fetchChapterMarkers(serverURL: URL, token: String, userId: String, itemId: String) async throws -> [SegmentMarker] {
        var components = URLComponents(
            url: serverURL.appendingPathComponent("Users/\(userId)/Items/\(itemId)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "fields", value: "Chapters")]

        let data = try await fetchData(from: components.url!, token: token, allowNotFound: false)
        guard let data else { return [] }

        let detail = try JSONDecoder().decode(ChapterItemDetail.self, from: data)
        let chapters = (detail.chapters ?? []).map {
            (start: Double($0.startPositionTicks) / 10_000_000.0, name: $0.name)
        }
        return ChapterClassifier.markers(from: chapters)
    }

    // MARK: - Networking

    /// Returns `nil` for 404 when `allowNotFound` (probe-style calls).
    private func fetchData(from url: URL, token: String, allowNotFound: Bool) async throws -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(
            "MediaBrowser Client=\"thisjellyfix\", Device=\"\(deviceOS)\", DeviceId=\"\(DeviceIdentifier().current())\", Version=\"0.1\", Token=\"\(token)\"",
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibraryError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200: return data
        case 404 where allowNotFound: return nil
        case 401: throw LibraryError.unauthorized
        default:
            TJFLog("GET \(url.absoluteString) status=\(httpResponse.statusCode)")
            throw LibraryError.serverError(httpResponse.statusCode)
        }
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

// MARK: - DTOs

private struct MediaSegmentsResponse: Decodable {
    let items: [MediaSegmentDTO]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

private struct MediaSegmentDTO: Decodable {
    let rawType: String?
    let startTicks: Int64?
    let endTicks: Int64?

    enum CodingKeys: String, CodingKey {
        case rawType = "Type"
        case startTicks = "StartTicks"
        case endTicks = "EndTicks"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Type may arrive as string enum ("Intro") or int enum (5) — accept both.
        if let string = try? container.decode(String.self, forKey: .rawType) {
            rawType = string
        } else if let int = try? container.decode(Int.self, forKey: .rawType) {
            rawType = String(int)
        } else {
            rawType = nil
        }
        startTicks = try? container.decode(Int64.self, forKey: .startTicks)
        endTicks = try? container.decode(Int64.self, forKey: .endTicks)
    }

    /// Maps a Jellyfin `MediaSegmentType` (string or int enum) to `SegmentMarker`.
    /// Only intro / recap / outro(→credits) are skippable in this app.
    var marker: SegmentMarker? {
        guard let startTicks, let endTicks else { return nil }

        let type: SegmentType?
        switch rawType?.lowercased() {
        case "intro": type = .intro
        case "recap": type = .recap
        case "outro", "credits": type = .credits
        // Jellyfin MediaSegmentType raw values: Recap=3, Outro=4, Intro=5
        case "3": type = .recap
        case "4": type = .credits
        case "5": type = .intro
        default: type = nil // unknown/preview/commercial types are not skippable here
        }

        guard let type else { return nil }
        return SegmentMarker(
            type: type,
            start: Double(startTicks) / 10_000_000.0,
            end: Double(endTicks) / 10_000_000.0
        )
    }
}

private struct ChapterItemDetail: Decodable {
    let chapters: [ChapterDTO]?

    enum CodingKeys: String, CodingKey {
        case chapters = "Chapters"
    }
}

private struct ChapterDTO: Decodable {
    let startPositionTicks: Int64
    let name: String?

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks"
        case name = "Name"
    }
}
