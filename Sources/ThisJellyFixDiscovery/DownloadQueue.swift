import Foundation
import ThisJellyFixCore

// MARK: - State

/// Lifecycle of a single download, as reported by the *arr queue.
/// Codable: the panel history is persisted across launches.
public enum DownloadState: Equatable, Sendable, Codable {
    /// Order sent, waiting for the service to accept it into its queue.
    case submitting
    case queued
    case downloading(progress: Double)
    case paused(progress: Double)
    case completed
    /// Finished and already present in the Jellyfin library (playable now).
    case available
    case failed(String)

    /// Map a raw *arr queue status into a displayable state.
    /// Unknown statuses surface as failed with the raw text so nothing
    /// silently disappears from the downloads panel.
    public init(status: String, progress: Double?) {
        switch status.lowercased() {
        case "pending", "waiting", "queued", "importpending":
            self = .queued
        case "paused", "pausedusenet", "pausedtorrent":
            self = .paused(progress: progress ?? 0)
        case "downloading", "importing":
            self = .downloading(progress: progress ?? 0)
        case "completed", "imported":
            self = .completed
        case "failed", "error", "failedimport", "deleting", "warning":
            self = .failed(status)
        default:
            self = .failed(status)
        }
    }

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .available: return true
        case .submitting, .queued, .downloading, .paused: return false
        }
    }
}

// MARK: - Entry

public struct DownloadEntry: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let service: DownloadService
    public let title: String
    /// TMDB id when the source reported it — used to detect "now in library".
    public let tmdbId: String?
    /// Movie/series id inside the *arr service: the id DELETE needs.
    /// Distinct from `id`, which for queue entries is the queue *record* id.
    public let remoteId: String?
    public let state: DownloadState

    public init(
        id: String,
        service: DownloadService,
        title: String,
        tmdbId: String? = nil,
        remoteId: String? = nil,
        state: DownloadState
    ) {
        self.id = id
        self.service = service
        self.title = title
        self.tmdbId = tmdbId
        self.remoteId = remoteId
        self.state = state
    }
}

// MARK: - Queue

/// Either *arr client, so one fetch call can serve both.
public enum AnyArrClient: Sendable {
    case radarr(RadarrClient)
    case sonarr(SonarrClient)

    public func fetchQueue() async throws -> [DownloadEntry] {
        switch self {
        case .radarr(let client): return try await client.queue()
        case .sonarr(let client): return try await client.queue()
        }
    }
}

public struct DownloadQueue: Sendable {
    private let client: AnyArrClient

    public init(client: AnyArrClient) {
        self.client = client
    }

    public func fetch() async throws -> [DownloadEntry] {
        try await client.fetchQueue()
    }
}

// MARK: - Queue payloads (shared between *arr services)

struct QueueResponse: Decodable {
    let records: [QueueRecord]
}

struct QueueRecord: Decodable {
    let id: Int
    let status: String
    let progress: Double?
    let movie: QueueMovie?
    let series: QueueSeries?
    let movieId: Int?
    let seriesId: Int?

    enum CodingKeys: String, CodingKey {
        case id, status, progress, movie, series, movieId, seriesId
    }

    func entry(service: DownloadService) -> DownloadEntry? {
        let title = movie?.title ?? series?.title
        guard let title else { return nil }
        // Service-side id for DELETE: the embedded object's id wins, the
        // top-level *Id field is the fallback when the object is thin.
        let remoteId = movie?.id ?? movieId ?? series?.id ?? seriesId
        return DownloadEntry(
            id: "\(service.rawValue)-\(id)",
            service: service,
            title: title,
            tmdbId: (movie?.tmdbId ?? series?.tmdbId).map(String.init),
            remoteId: remoteId.map(String.init),
            state: DownloadState(status: status, progress: progress)
        )
    }
}

struct QueueMovie: Decodable {
    let id: Int?
    let title: String
    let tmdbId: Int?
}

struct QueueSeries: Decodable {
    let id: Int?
    let title: String
    let tvdbId: Int?
    let tmdbId: Int?
}
