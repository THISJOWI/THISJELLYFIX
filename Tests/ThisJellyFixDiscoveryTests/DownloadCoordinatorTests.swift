import XCTest
@testable import ThisJellyFixDiscovery
@testable import ThisJellyFixCore

/// Coordinator tests: what happens when the user hits "Descargar" and when
/// the queue refreshes. Fake clients record calls; no real network.
final class DownloadCoordinatorTests: XCTestCase {
    private var config: IntegrationConfig!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "DownloadCoordinatorTests.\(UUID().uuidString)")
        config = IntegrationConfig(defaults: defaults, keychain: InMemoryKeychain())
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
        super.tearDown()
    }

    private var movie: CatalogItem {
        CatalogItem(id: "335984", kind: .movie, title: "Blade Runner 2049", year: 2017,
                    overview: nil, posterURL: nil, backdropURL: nil,
                    tmdbId: "335984", imdbId: nil)
    }

    private var series: CatalogItem {
        CatalogItem(id: "1396", kind: .series, title: "Breaking Bad", year: 2008,
                    overview: nil, posterURL: nil, backdropURL: nil,
                    tmdbId: "1396", imdbId: nil)
    }

    // MARK: - Submitting

    func testSubmitMovieWithoutConfigThrowsMissingService() async {
        let coordinator = DownloadCoordinator(config: config, radarr: nil, sonarr: nil)
        do {
            try await coordinator.submit(movie, options: nil)
            XCTFail("Expected error")
        } catch let error as DownloadCoordinatorError {
            XCTAssertEqual(error, .serviceNotConfigured(.radarr))
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testSubmitMovieCreatesLocalEntryInSubmittingState() async throws {
        let radarr = FakeRadarr()
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)
        // Radarr configured (needed by submit path) but fake client ignores keys.
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"

        try await coordinator.submit(movie, options: nil)

        XCTAssertEqual(coordinator.entries.count, 1)
        XCTAssertEqual(coordinator.entries[0].title, "Blade Runner 2049")
        XCTAssertEqual(coordinator.entries[0].service, .radarr)
        XCTAssertEqual(coordinator.entries[0].state, .submitting)
        XCTAssertEqual(radarr.addedMovies.count, 1)
        XCTAssertEqual(radarr.addedMovies[0].tmdbId, "335984")
    }

    func testSubmitSeriesLooksUpThenGoesToSonarr() async throws {
        let sonarr = FakeSonarr()
        sonarr.lookupResults = [
            SonarrSeriesLookup(
                id: nil, title: "Breaking Bad", year: 2008, tvdbId: 81189,
                tmdbId: "1396", status: "continuing", network: "AMC",
                seasonCount: 5, images: nil,
                seasons: [SonarrSeason(seasonNumber: 1, monitored: true)]
            )
        ]
        config.sonarrURL = URL(string: "http://s:8989")
        config.sonarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: nil, sonarr: sonarr)

        try await coordinator.submit(series, options: nil)

        // tvdbId comes from the lookup, never from the TMDB id.
        XCTAssertEqual(sonarr.lookupTerms, ["tmdb:1396"])
        XCTAssertEqual(sonarr.addedSeries.count, 1)
        XCTAssertEqual(sonarr.addedSeries[0].tvdbId, 81189)
        XCTAssertEqual(coordinator.entries[0].service, .sonarr)
    }

    func testSubmitSeriesWithNoLookupResultThrows() async {
        let sonarr = FakeSonarr()   // lookupResults empty
        config.sonarrURL = URL(string: "http://s:8989")
        config.sonarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: nil, sonarr: sonarr)

        do {
            try await coordinator.submit(series, options: nil)
            XCTFail("Expected error")
        } catch let error as DownloadCoordinatorError {
            XCTAssertEqual(error, .lookupReturnedNothing)
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertTrue(sonarr.addedSeries.isEmpty)
    }

    func testFailedSubmitMarksEntryFailed() async {
        let radarr = FakeRadarr()
        radarr.addError = ArrError.serverError(500)
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        do {
            try await coordinator.submit(movie, options: nil)
            XCTFail("Expected error")
        } catch { /* surfaced to UI */ }

        XCTAssertEqual(coordinator.entries.count, 1)
        XCTAssertEqual(coordinator.entries[0].state, .failed("serverError(500)"))
    }

    // MARK: - Refresh merges remote queue over local optimistic entries

    func testRefreshReplacesSubmittingEntryWithRemoteProgress() async throws {
        let radarr = FakeRadarr()
        radarr.queueRecords = [
            DownloadEntry(id: "radarr-11", service: .radarr, title: "Blade Runner 2049",
                          state: .downloading(progress: 42.5))
        ]
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        try await coordinator.submit(movie, options: nil)
        await coordinator.refresh()

        XCTAssertEqual(coordinator.entries.count, 1)
        XCTAssertEqual(coordinator.entries[0].state, .downloading(progress: 42.5))
        XCTAssertEqual(radarr.queueFetchCount, 1)
    }

    func testRefreshKeepsLocalEntryNotYetInRemoteQueue() async throws {
        let radarr = FakeRadarr()
        radarr.queueRecords = []   // still submitting, not queued server-side
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        try await coordinator.submit(movie, options: nil)
        await coordinator.refresh()

        XCTAssertEqual(coordinator.entries.count, 1)
        XCTAssertEqual(coordinator.entries[0].state, .submitting)
    }

    func testRefreshFetchesBothConfiguredServices() async throws {
        let radarr = FakeRadarr()
        let sonarr = FakeSonarr()
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        config.sonarrURL = URL(string: "http://s:8989")
        config.sonarrApiKey = "k2"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: sonarr)

        await coordinator.refresh()

        XCTAssertEqual(radarr.queueFetchCount, 1)
        XCTAssertEqual(sonarr.queueFetchCount, 1)
    }

    func testRefreshSwallowsErrorsIntoEntrylessResult() async {
        let radarr = FakeRadarr()
        radarr.queueError = ArrError.unreachable
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        await coordinator.refresh()
        // No crash, no bogus entries; UI keeps the previous list.
        XCTAssertEqual(coordinator.entries, [])
        XCTAssertNotNil(coordinator.lastRefreshError)
    }

    // MARK: - Removal

    func testRemoveEntriesDeletesRemoteAndDropsLocal() async throws {
        let radarr = FakeRadarr()
        radarr.queueRecords = [
            DownloadEntry(id: "radarr-11", service: .radarr, title: "Dune",
                          tmdbId: "438631", state: .downloading(progress: 10))
        ]
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        await coordinator.refresh()
        XCTAssertEqual(coordinator.entries.count, 1)

        let target = CatalogItem(id: "438631", kind: .movie, title: "Dune", year: 2021,
                                 overview: nil, posterURL: nil, backdropURL: nil,
                                 tmdbId: "438631", imdbId: nil)
        await coordinator.removeEntries(matching: target)

        XCTAssertEqual(radarr.deletedIds, ["11"])
        // Queue is now empty server-side → local list must be empty too.
        radarr.queueRecords = []
        await coordinator.refresh()
        XCTAssertTrue(coordinator.entries.isEmpty)
    }

    func testRemoveLocalOptimisticEntryNeverCallsService() async throws {
        let radarr = FakeRadarr()
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        try await coordinator.submit(movie, options: nil)
        XCTAssertEqual(coordinator.entries.count, 1)

        await coordinator.removeEntries(matching: movie)

        XCTAssertTrue(radarr.deletedIds.isEmpty)
        XCTAssertTrue(coordinator.entries.isEmpty)
    }

    // MARK: - Availability (Jellyfin picked the file up)

    func testMarkAvailableFlipsCompletedEntry() async throws {
        let radarr = FakeRadarr()
        radarr.queueRecords = [
            DownloadEntry(id: "radarr-11", service: .radarr, title: "Dune",
                          tmdbId: "438631", state: .downloading(progress: 99))
        ]
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        await coordinator.refresh()
        XCTAssertEqual(coordinator.entries[0].state, .downloading(progress: 99))

        coordinator.markAvailable(tmdbId: "438631")
        XCTAssertEqual(coordinator.entries[0].state, .available)
    }
}

// MARK: - Fakes

final class FakeRadarr: RadarrProviding, @unchecked Sendable {
    struct AddedMovie: Equatable {
        let tmdbId: String
        let title: String
        let qualityProfileId: Int
        let rootFolderPath: String
        let searchForMovie: Bool
    }

    var addedMovies: [AddedMovie] = []
    var addError: Error?
    var queueRecords: [DownloadEntry] = []
    var queueError: Error?
    var qualityProfilesResult: [ArrQualityProfile] = [ArrQualityProfile(id: 1, name: "HD")]
    var rootFoldersResult: [ArrRootFolder] = [ArrRootFolder(id: 1, path: "/films")]
    private(set) var queueFetchCount = 0
    private(set) var deletedIds: [String] = []

    func deleteEntry(id: String) async throws {
        deletedIds.append(id)
        queueRecords.removeAll { $0.id == "radarr-\(id)" }
    }

    func lookup(tmdbId: String) async throws -> [RadarrMovieLookup] { [] }

    func addMovie(
        tmdbId: String, title: String, qualityProfileId: Int,
        rootFolderPath: String, monitored: Bool, searchForMovie: Bool
    ) async throws -> Int {
        if let addError { throw addError }
        addedMovies.append(AddedMovie(
            tmdbId: tmdbId, title: title, qualityProfileId: qualityProfileId,
            rootFolderPath: rootFolderPath, searchForMovie: searchForMovie
        ))
        return 1
    }

    func qualityProfiles() async throws -> [ArrQualityProfile] { qualityProfilesResult }
    func rootFolders() async throws -> [ArrRootFolder] { rootFoldersResult }
    func testConnection() async throws {}

    func queue() async throws -> [DownloadEntry] {
        queueFetchCount += 1
        if let queueError { throw queueError }
        return queueRecords
    }
}

final class FakeSonarr: SonarrProviding, @unchecked Sendable {
    struct AddedSeries: Equatable {
        let tvdbId: Int
        let title: String
        let qualityProfileId: Int
        let rootFolderPath: String
        let monitor: SeriesMonitor
        let seasons: [Int]
    }

    var addedSeries: [AddedSeries] = []
    var addError: Error?
    var lookupResults: [SonarrSeriesLookup] = []
    var qualityProfilesResult: [ArrQualityProfile] = [ArrQualityProfile(id: 2, name: "Any")]
    var rootFoldersResult: [ArrRootFolder] = [ArrRootFolder(id: 1, path: "/series")]
    private(set) var lookupTerms: [String] = []
    var queueRecords: [DownloadEntry] = []
    var queueError: Error?
    private(set) var queueFetchCount = 0
    private(set) var deletedIds: [String] = []

    func deleteEntry(id: String) async throws {
        deletedIds.append(id)
        queueRecords.removeAll { $0.id == "sonarr-\(id)" }
    }

    func lookup(tmdbId: String) async throws -> [SonarrSeriesLookup] {
        lookupTerms.append("tmdb:\(tmdbId)")
        return lookupResults
    }

    func addSeries(
        tvdbId: Int, title: String, qualityProfileId: Int,
        rootFolderPath: String, monitored: Bool, monitor: SeriesMonitor,
        seasons: [Int], searchForMissing: Bool
    ) async throws -> Int {
        if let addError { throw addError }
        addedSeries.append(AddedSeries(
            tvdbId: tvdbId, title: title, qualityProfileId: qualityProfileId,
            rootFolderPath: rootFolderPath, monitor: monitor, seasons: seasons
        ))
        return 1
    }

    func qualityProfiles() async throws -> [ArrQualityProfile] { qualityProfilesResult }
    func rootFolders() async throws -> [ArrRootFolder] { rootFoldersResult }
    func testConnection() async throws {}

    func queue() async throws -> [DownloadEntry] {
        queueFetchCount += 1
        if let queueError { throw queueError }
        return queueRecords
    }
}
