import Foundation

/// Jellyfin DeviceProfile used to force HLS transcoding.
///
/// Sending this profile on PlaybackInfo makes the server reject direct play
/// (empty `DirectPlayProfiles`) and answer with a `TranscodingUrl`
/// (master.m3u8) — an HLS playlist AVPlayer can consume for
/// picture-in-picture. VLC keeps using its normal direct/remux stream.
public struct PlaybackDeviceProfile: Codable, Sendable, Equatable {
    public let name: String
    public let maxStaticBitrate: Int
    public let maxStreamingBitrate: Int
    public let directPlayProfiles: [DirectPlayProfile]
    public let transcodingProfiles: [TranscodingProfile]
    public let subtitleProfiles: [SubtitleProfile]

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maxStaticBitrate = "MaxStaticBitrate"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case directPlayProfiles = "DirectPlayProfiles"
        case transcodingProfiles = "TranscodingProfiles"
        case subtitleProfiles = "SubtitleProfiles"
    }

    public struct DirectPlayProfile: Codable, Sendable, Equatable {
        public let container: String
        public let type: String
        public let videoCodec: String
        public let audioCodec: String

        enum CodingKeys: String, CodingKey {
            case container = "Container"
            case type = "Type"
            case videoCodec = "VideoCodec"
            case audioCodec = "AudioCodec"
        }

        public init(container: String, type: String, videoCodec: String, audioCodec: String) {
            self.container = container
            self.type = type
            self.videoCodec = videoCodec
            self.audioCodec = audioCodec
        }
    }

    public struct TranscodingProfile: Codable, Sendable, Equatable {
        public let container: String
        public let type: String
        /// `Protocol` is a Swift keyword — mapped back in CodingKeys.
        public let streamingProtocol: String
        public let videoCodec: String
        public let audioCodec: String
        public let context: String
        public let maxAudioChannels: String

        enum CodingKeys: String, CodingKey {
            case container = "Container"
            case type = "Type"
            case streamingProtocol = "Protocol"
            case videoCodec = "VideoCodec"
            case audioCodec = "AudioCodec"
            case context = "Context"
            case maxAudioChannels = "MaxAudioChannels"
        }

        public init(
            container: String,
            type: String,
            streamingProtocol: String,
            videoCodec: String,
            audioCodec: String,
            context: String,
            maxAudioChannels: String
        ) {
            self.container = container
            self.type = type
            self.streamingProtocol = streamingProtocol
            self.videoCodec = videoCodec
            self.audioCodec = audioCodec
            self.context = context
            self.maxAudioChannels = maxAudioChannels
        }
    }

    public struct SubtitleProfile: Codable, Sendable, Equatable {
        public let format: String
        public let deliveryMethod: String

        enum CodingKeys: String, CodingKey {
            case format = "Format"
            case deliveryMethod = "DeliveryMethod"
        }

        public init(format: String, deliveryMethod: String) {
            self.format = format
            self.deliveryMethod = deliveryMethod
        }
    }

    public init(
        name: String,
        maxStaticBitrate: Int,
        maxStreamingBitrate: Int,
        directPlayProfiles: [DirectPlayProfile],
        transcodingProfiles: [TranscodingProfile],
        subtitleProfiles: [SubtitleProfile]
    ) {
        self.name = name
        self.maxStaticBitrate = maxStaticBitrate
        self.maxStreamingBitrate = maxStreamingBitrate
        self.directPlayProfiles = directPlayProfiles
        self.transcodingProfiles = transcodingProfiles
        self.subtitleProfiles = subtitleProfiles
    }

    /// HLS-only profile: no direct play allowed, single h264+aac HLS
    /// transcoding profile → server always returns a TranscodingUrl.
    public static let pipHLS = PlaybackDeviceProfile(
        name: "thisjellyfix-pip-hls",
        maxStaticBitrate: 140_000_000,
        maxStreamingBitrate: 140_000_000,
        directPlayProfiles: [],
        transcodingProfiles: [
            TranscodingProfile(
                container: "ts",
                type: "Video",
                streamingProtocol: "hls",
                videoCodec: "h264",
                audioCodec: "aac",
                context: "Streaming",
                maxAudioChannels: "2"
            )
        ],
        subtitleProfiles: [
            SubtitleProfile(format: "srt", deliveryMethod: "External"),
            SubtitleProfile(format: "subrip", deliveryMethod: "External"),
            SubtitleProfile(format: "ass", deliveryMethod: "External"),
            SubtitleProfile(format: "ssa", deliveryMethod: "External"),
            SubtitleProfile(format: "mov_text", deliveryMethod: "Embed"),
            SubtitleProfile(format: "pgssub", deliveryMethod: "Embed"),
        ]
    )
}
