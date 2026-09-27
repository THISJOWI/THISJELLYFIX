import XCTest

/// Radarr/Sonarr live on the user's LAN, so both apps need the local
/// network permission keys. Without `NSLocalNetworkUsageDescription` the
/// system **denies the connection silently — no dialog ever appears**,
/// which is impossible to debug from the UI.
final class InfoPlistNetworkPermissionTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/ThisJellyFixCoreTests/File.swift
            .deletingLastPathComponent()          // …/Tests/ThisJellyFixCoreTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // repo root
    }

    private func plist(_ relativePath: String) throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(object as? [String: Any], "Expected dictionary in \(relativePath)")
    }

    func testMacOSDeclaresLocalNetworkUsageDescription() throws {
        let info = try plist("Apps/macOS/Info.plist")
        let reason = info["NSLocalNetworkUsageDescription"] as? String
        XCTAssertNotNil(reason, "macOS app must ask for the local network permission")
        XCTAssertFalse((reason ?? "").isEmpty)
    }

    func testIOSDeclaresLocalNetworkUsageDescription() throws {
        let info = try plist("Apps/iOS/Info.plist")
        let reason = info["NSLocalNetworkUsageDescription"] as? String
        XCTAssertNotNil(reason, "iOS app must ask for the local network permission")
        XCTAssertFalse((reason ?? "").isEmpty)
    }

    /// Radarr/Sonarr on `http://192.168.x.x:7878` are plain HTTP: ATS blocks
    /// them unless local networking is explicitly allowed.
    func testIOSAllowsPlainHTTPOnTheLocalNetwork() throws {
        let info = try plist("Apps/iOS/Info.plist")
        let ats = try XCTUnwrap(info["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
    }

    func testMacOSSandboxAllowsOutgoingConnections() throws {
        let entitlements = try plist("Apps/macOS/ThisJellyfix.entitlements")
        XCTAssertEqual(
            entitlements["com.apple.security.network.client"] as? Bool, true,
            "Sandboxed macOS app cannot reach Radarr/Sonarr without network.client"
        )
    }
}
