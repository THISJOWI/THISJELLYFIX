import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Activity Type Identifiers

/// Centralised identifiers for every `NSUserActivity` this app can publish or
/// receive.  Identifiers must be listed in **NSUserActivityTypes** inside each
/// target's `Info.plist` so the system knows the app can handle them.
public enum HandoffActivity {

    // MARK: Identifiers

    /// User is browsing the home library (catch-all, lowest priority).
    public static let browsing  = "com.thisjellyfix.activity.browsing"

    /// User is looking at a media item's detail screen.
    public static let detail    = "com.thisjellyfix.activity.detail"

    /// User is actively playing a media item.
    public static let playing   = "com.thisjellyfix.activity.playing"

    // MARK: UserInfo keys

    public enum Key {
        /// `String` — Jellyfin item ID.
        public static let itemId     = "itemId"
        /// `String` — Absolute URL of the Jellyfin server.
        public static let serverURL  = "serverURL"
        /// `String` — Display title of the item.
        public static let title      = "title"
        /// `String` — Media type ("Movie", "Episode", "Series", …).
        public static let mediaType  = "mediaType"
        /// `Double` — Current playback position in seconds.
        public static let position   = "position"
        /// `String` — Authenticated user ID.
        public static let userId     = "userId"
        /// `String` — Auth token (omitted from Handoff payload for security).
        // Token is intentionally NOT included — the receiving device reads it
        // from its own Keychain after the user is confirmed authenticated.
    }

    // MARK: Factory helpers

    /// Creates a `NSUserActivity` for the detail screen of a given item.
    public static func detailActivity(
        item: HandoffMediaItem,
        serverURL: URL
    ) -> NSUserActivity {
        let activity = NSUserActivity(activityType: HandoffActivity.detail)
        activity.title = item.name
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch  = false // Spotlight handled separately
        activity.userInfo = [
            Key.itemId:    item.id,
            Key.serverURL: serverURL.absoluteString,
            Key.title:     item.name,
            Key.mediaType: item.type,
        ]
        return activity
    }

    /// Creates a `NSUserActivity` for an active playback session.
    /// Call `update(position:)` to keep the position current.
    public static func playingActivity(
        item: HandoffMediaItem,
        serverURL: URL,
        userId: String,
        position: Double
    ) -> NSUserActivity {
        let activity = NSUserActivity(activityType: HandoffActivity.playing)
        activity.title = "Reproduciendo \(item.name)"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch  = false
        activity.userInfo = [
            Key.itemId:    item.id,
            Key.serverURL: serverURL.absoluteString,
            Key.title:     item.name,
            Key.mediaType: item.type,
            Key.userId:    userId,
            Key.position:  position,
        ]
        return activity
    }
}

// MARK: - HandoffMediaItem

/// Minimal representation of a media item needed for Handoff payloads.
/// Deliberately flat (no nested types) so it can be reconstructed from
/// `NSUserActivity.userInfo` without importing the full `JellyfinMediaItem`.
public struct HandoffMediaItem: Sendable {
    public let id: String
    public let name: String
    public let type: String

    public init(id: String, name: String, type: String) {
        self.id = id
        self.name = name
        self.type = type
    }
}
