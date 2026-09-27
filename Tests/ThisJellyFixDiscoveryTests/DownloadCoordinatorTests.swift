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
        // Radarr's movie id (what DELETE /movie/{id} needs) must be kept
        // from the add response: cancel before the first refresh needs it.
        XCTAssertEqual(coordinator.entries[0].remoteId, "1")
        XCTAssertEqual(radarr.addedMovies.count, 1)
        XCTAssertEqual(radarr.addedMovies[0].tmdbId, "335984")
    }

    /// After the add, the coordinator must post the search command itself:
    /// the add-time search runs non-Manual and Radarr drops unavailable
    /// movies from it, so without this the order never downloads.
    func testSubmitMovieTriggersManualSearchAfterAdd() async throws {
        let radarr = FakeRadarr()
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        try await coordinator.submit(movie, options: nil)

        XCTAssertEqual(radarr.addedMovies.count, 1)
        XCTAssertEqual(radarr.searchTriggeredIds, [1])
    }

    /// The options sheet can turn the immediate search off: then only the
    /// add happens (no command posted).
    func testSubmitMovieWithoutSearchNowSkipsManualSearch() async throws {
        let radarr = FakeRadarr()
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)
        let options = AddOptions(qualityProfileId: 1, rootFolderPath: "/films", searchNow: false)

        try await coordinator.submit(movie, options: options)

        XCTAssertEqual(radarr.addedMovies.count, 1)
        XCTAssertTrue(radarr.searchTriggeredIds.isEmpty)
    }

    /// The movie is already created server-side when the command is posted:
    /// a failing command must not flip the entry to failed or lose the id
    /// cancel needs (the add already asked for a search too).
    func testTriggerSearchFailureKeepsSubmitSuccessful() async throws {
        let radarr = FakeRadarr()
        radarr.triggerError = ArrError.unreachable
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        try await coordinator.submit(movie, options: nil)

        XCTAssertEqual(radarr.searchTriggeredIds, [1])
        XCTAssertEqual(coordinator.entries[0].state, .submitting)
        XCTAssertEqual(coordinator.entries[0].remoteId, "1")
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
        XCTAssertEqual(coordinator.entries[0].remoteId, "1")
    }

    /// Series get the same Manual-trigger search as movies: the add-time
    /// search runs non-Manual, which delay profiles can swallow.
    func testSubmitSeriesTriggersManualSearchAfterAdd() async throws {
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

        XCTAssertEqual(sonarr.addedSeries.count, 1)
        XCTAssertEqual(sonarr.searchTriggeredIds, [1])
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
        radarr.addError = ArrError.serverError(500, nil)
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        do {
            try await coordinator.submit(movie, options: nil)
            XCTFail("Expected error")
        } catch { /* surfaced to UI */ }

        XCTAssertEqual(coordinator.entries.count, 1)
        // User-facing text, not the enum's debug dump.
        XCTAssertEqual(
            coordinator.entries[0].state,
            .failed("El servicio devolvió un error (código 500).")
        )
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

    // MARK: - Persistence

    private func seedHistory(_ entries: [DownloadEntry]) throws {
        config.saveDownloadHistory(try JSONEncoder().encode(entries))
    }

    func testHistorySurvivesNewCoordinatorInstance() async throws {
        let radarr = FakeRadarr()
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let first = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)
        try await first.submit(movie, options: nil)
        XCTAssertEqual(first.entries.count, 1)

        // App relaunched: fresh coordinator over the same storage.
        let second = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries[0].id, first.entries[0].id)
        XCTAssertEqual(second.entries[0].remoteId, "1")
        // In-flight `.submitting` can't be trusted after relaunch; the
        // first refresh re-adopts the real remote queue entry.
        XCTAssertEqual(second.entries[0].state, .failed("Envío interrumpido"))
    }

    func testCompletedHistorySurvivesRefresh() async throws {
        // Download finished long ago: no longer in any remote queue, but
        // it IS the history the user asked to keep across launches.
        let done = DownloadEntry(id: "radarr-5", service: .radarr, title: "Old Movie",
                                 tmdbId: "111", remoteId: "2", state: .completed)
        try seedHistory([done])
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let radarr = FakeRadarr()   // remote queue empty
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        XCTAssertEqual(coordinator.entries, [done])   // hydrated
        await coordinator.refresh()

        XCTAssertEqual(coordinator.entries, [done])   // not wiped by empty queue
        XCTAssertNil(coordinator.lastRefreshError)
    }

    func testRefreshFailureKeepsPreviousList() async throws {
        let radarr = FakeRadarr()
        radarr.queueRecords = [
            DownloadEntry(id: "radarr-7", service: .radarr, title: "Dune",
                          tmdbId: "438631", remoteId: "5", state: .downloading(progress: 10))
        ]
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.entries.count, 1)

        // Service drops mid-session: rebuilding from an empty remote would
        // wipe real entries.
        radarr.queueError = ArrError.unreachable
        await coordinator.refresh()

        XCTAssertEqual(coordinator.entries.count, 1)
        XCTAssertEqual(coordinator.entries[0].title, "Dune")
        XCTAssertNotNil(coordinator.lastRefreshError)
    }

    func testCancelPersistsRemovalAcrossRestart() async throws {
        let done = DownloadEntry(id: "radarr-5", service: .radarr,
                                 title: "Blade Runner 2049",
                                 tmdbId: "335984", remoteId: "2", state: .completed)
        try seedHistory([done])
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let radarr = FakeRadarr()
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        await coordinator.removeEntries(matching: movie)
        XCTAssertEqual(radarr.deletedIds, ["2"])
        XCTAssertTrue(coordinator.entries.isEmpty)

        let relaunched = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)
        XCTAssertTrue(relaunched.entries.isEmpty)
    }

    func testInterruptedSubmitHydratesAsFailed() async throws {
        // App died mid-submit: `.submitting` is meaningless after relaunch.
        let stuck = DownloadEntry(id: "local-radarr-1", service: .radarr,
                                  title: "X", tmdbId: "1", remoteId: "9",
                                  state: .submitting)
        try seedHistory([stuck])
        let coordinator = DownloadCoordinator(config: config, radarr: nil, sonarr: nil)

        XCTAssertEqual(coordinator.entries.count, 1)
        guard case .failed = coordinator.entries[0].state else {
            return XCTFail("Expected failed, got \(coordinator.entries[0].state)")
        }
    }

    func testDownloadStateRoundTripsThroughJSON() throws {
        let states: [DownloadState] = [
            .submitting, .queued, .downloading(progress: 42.5), .paused(progress: 3),
            .completed, .available, .failed("boom"),
        ]
        let data = try JSONEncoder().encode(states)
        XCTAssertEqual(try JSONDecoder().decode([DownloadState].self, from: data), states)
    }

    // MARK: - Removal

    func testRemoveEntriesDeletesRemoteIdNotQueueRecordId() async throws {
        let radarr = FakeRadarr()
        radarr.queueRecords = [
            // Queue record id 11, but Radarr's movie id is 77: cancel must
            // DELETE /movie/77 — record ids 404 and the old code hid it.
            DownloadEntry(id: "radarr-11", service: .radarr, title: "Dune",
                          tmdbId: "438631", remoteId: "77",
                          state: .downloading(progress: 10))
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

        XCTAssertEqual(radarr.deletedIds, ["77"])
        // Queue is now empty server-side → local list must be empty too.
        radarr.queueRecords = []
        await coordinator.refresh()
        XCTAssertTrue(coordinator.entries.isEmpty)
    }

    func testCancelRightAfterSubmitDeletesFromService() async throws {
        // Before the first refresh the entry is still local-* — cancel must
        // still reach Radarr using the id returned by the add call,
        // otherwise the movie stays in Radarr forever.
        let radarr = FakeRadarr()
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        try await coordinator.submit(movie, options: nil)
        XCTAssertEqual(coordinator.entries.count, 1)
        XCTAssertTrue(coordinator.entries[0].id.hasPrefix("local-"))

        await coordinator.removeEntries(matching: movie)

        XCTAssertEqual(radarr.deletedIds, ["1"])
        XCTAssertTrue(coordinator.entries.isEmpty)
    }

    func testRemoveFallsBackToLookupWhenRemoteIdMissing() async throws {
        let radarr = FakeRadarr()
        radarr.lookupResults = [
            RadarrMovieLookup(id: 77, title: "Dune", year: 2021, tmdbId: "438631",
                              hasFile: false, monitored: true, status: "released", images: nil)
        ]
        radarr.queueRecords = [
            DownloadEntry(id: "radarr-11", service: .radarr, title: "Dune",
                          tmdbId: "438631", state: .downloading(progress: 10))
        ]
        config.radarrURL = URL(string: "http://r:7878")
        config.radarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: radarr, sonarr: nil)

        await coordinator.refresh()
        let target = CatalogItem(id: "438631", kind: .movie, title: "Dune", year: 2021,
                                 overview: nil, posterURL: nil, backdropURL: nil,
                                 tmdbId: "438631", imdbId: nil)
        await coordinator.removeEntries(matching: target)

        XCTAssertEqual(radarr.lookupTerms, ["438631"])
        XCTAssertEqual(radarr.deletedIds, ["77"])
    }

    func testRemoveMatchingSonarrEntryDeletesSeries() async throws {
        let sonarr = FakeSonarr()
        sonarr.queueRecords = [
            DownloadEntry(id: "sonarr-1", service: .sonarr, title: "Breaking Bad",
                          tmdbId: "1396", remoteId: "3", state: .queued)
        ]
        config.sonarrURL = URL(string: "http://s:8989")
        config.sonarrApiKey = "k"
        let coordinator = DownloadCoordinator(config: config, radarr: nil, sonarr: sonarr)

        await coordinator.refresh()
        await coordinator.removeEntries(matching: series)

        XCTAssertEqual(sonarr.deletedIds, ["3"])
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
    var lookupResults: [RadarrMovieLookup] = []
    private(set) var lookupTerms: [String] = []
    var qualityProfilesResult: [ArrQualityProfile] = [ArrQualityProfile(id: 1, name: "HD")]
    var rootFoldersResult: [ArrRootFolder] = [ArrRootFolder(id: 1, path: "/films")]
    private(set) var queueFetchCount = 0
    private(set) var deletedIds: [String] = []
    var triggerError: Error?
    private(set) var searchTriggeredIds: [Int] = []

    func triggerSearch(movieId: Int) async throws {
        searchTriggeredIds.append(movieId)
        if let triggerError { throw triggerError }
    }

    func deleteEntry(id: String) async throws {
        deletedIds.append(id)
        queueRecords.removeAll { $0.remoteId == id }
    }

    func lookup(tmdbId: String) async throws -> [RadarrMovieLookup] {
        lookupTerms.append(tmdbId)
        return lookupResults
    }

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
    var triggerError: Error?
    private(set) var searchTriggeredIds: [Int] = []

    func triggerSearch(seriesId: Int) async throws {
        searchTriggeredIds.append(seriesId)
        if let triggerError { throw triggerError }
    }

    func deleteEntry(id: String) async throws {
        deletedIds.append(id)
        queueRecords.removeAll { $0.remoteId == id }
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
