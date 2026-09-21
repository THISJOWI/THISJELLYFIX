import Foundation
import ThisJellyFixCore

/// The stable boundary for AVFoundation, an eventual universal player, and server-transcoded streams.
public protocol PlaybackEngine: Sendable {
    var kind: PlaybackEngineKind { get }
    func prepare(_ request: PlaybackRequest) async throws
    func play() async
    func pause() async
    func stop() async
}

public enum PlaybackEngineKind: String, Sendable {
    case native
    case universal
    case jellyfinTranscoded
}

public struct PlaybackRequest: Sendable, Equatable {
    public let itemID: String
    public let streamURL: URL

    public init(itemID: String, streamURL: URL) {
        self.itemID = itemID
        self.streamURL = streamURL
    }
}
