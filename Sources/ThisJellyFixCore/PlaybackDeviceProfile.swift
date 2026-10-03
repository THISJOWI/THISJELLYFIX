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

    /// AVPlayer profile for the main player: direct play first (mp4/mov/mkv
    /// containers with codecs AVPlayer actually decodes), HLS h264+aac as the
    /// transcoding fallback. Subtitle delivery mirrors the hybrid strategy:
    /// text subs external (client renders), mov_text embedded (AVPlayer
    /// media selection), bitmap subs burned in by the server (Encode).
    public static let avPlayer = PlaybackDeviceProfile(
        name: "thisjellyfix-avplayer",
        maxStaticBitrate: 140_000_000,
        maxStreamingBitrate: 140_000_000,
        // Conservative on purpose: only declare what AVPlayer decodes on
        // every supported OS version. AV1/VP9 are hardware-gated — undeclared
        // here so the server remuxes/transcodes instead of failing at runtime.
        // mkv is NOT listed: AVPlayer cannot open it, so an mkv source gets
        // remuxed to mp4 (DirectStreamUrl) or HLS-transcoded by the server.
        directPlayProfiles: [
            DirectPlayProfile(
                container: "mp4,m4v,mov",
                type: "Video",
                videoCodec: "h264,hevc,mpeg4",
                audioCodec: "aac,mp3,ac3,eac3,alac,flac"
            ),
            DirectPlayProfile(container: "mp3,m4a,flac", type: "Audio", videoCodec: "", audioCodec: "aac,mp3,flac,alac")
        ],
        transcodingProfiles: [
            TranscodingProfile(
                container: "ts",
                type: "Video",
                streamingProtocol: "hls",
                videoCodec: "h264",
                audioCodec: "aac",
                context: "Streaming",
                maxAudioChannels: "6"
            )
        ],
        subtitleProfiles: [
            SubtitleProfile(format: "srt", deliveryMethod: "External"),
            SubtitleProfile(format: "subrip", deliveryMethod: "External"),
            SubtitleProfile(format: "webvtt", deliveryMethod: "External"),
            // ASS/SSA can't be rendered client-side by AVPlayer → server burns.
            SubtitleProfile(format: "ass", deliveryMethod: "Encode"),
            SubtitleProfile(format: "ssa", deliveryMethod: "Encode"),
            SubtitleProfile(format: "mov_text", deliveryMethod: "Embed"),
            SubtitleProfile(format: "tx3g", deliveryMethod: "Embed"),
            SubtitleProfile(format: "pgssub", deliveryMethod: "Encode"),
            SubtitleProfile(format: "dvdsub", deliveryMethod: "Encode"),
            SubtitleProfile(format: "dvb_subtitle", deliveryMethod: "Encode")
        ]
    )

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
