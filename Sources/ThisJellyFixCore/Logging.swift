import Foundation

// MARK: - Debug Logging

/// Debug logger: writes to stdout (Xcode console, including physical devices)
/// and to a capped file in `NSTemporaryDirectory()/tjf_playback.log`.
///
/// Every line passes through `redactSecrets(_:)` first: Jellyfin stream URLs
/// and PlaybackInfo bodies carry `api_key`/`AccessToken`, and those used to be
/// written verbatim to disk and stdout.
public func TJFLog(_ message: String) {
    let line = "[TJF \(TJFLogClock.timestamp())] \(TJFLogSanitizer.redactSecrets(message))"
    print(line)
    TJFLogFile.append(line)
}

/// Location of the rolling playback log, for the in-app "share diagnostics"
/// action (secrets are redacted on write, size capped at 512 KB).
public enum TJFLogExport {
    public static var filePath: String { TJFLogFile.path }
}

/// Redacted copies of the secret-bearing fields we expect in this app.
public enum TJFLogSanitizer {
    private static let patterns: [(pattern: String, template: String)] = [
        // URL / key=value style: `api_key=…`, `ApiKey: …`, `token=…`, `password=…`
        ("(?i)(api_?key|access_?token|token|password|auth)[=:]\\s*[^&\\s\"']+", "$1=***"),
        // JSON style: `"AccessToken":"…"`, `"Password":"…"`
        ("(?i)\"(accessToken|password|apiKey|api_key|token)\"\\s*:\\s*\"[^\"]*\"", "\"$1\":\"***\""),
        // Authorization headers
        ("(?i)(bearer\\s+)[a-z0-9._~+/=-]+", "$1***"),
    ]

    public static func redactSecrets(_ message: String) -> String {
        var result = message
        for entry in patterns {
            guard let regex = try? NSRegularExpression(pattern: entry.pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: entry.template
            )
        }
        return result
    }
}

/// One shared timestamp formatter — allocating an `ISO8601DateFormatter` on
/// every log line was main-thread work during library load.
enum TJFLogClock {
    private static let lock = NSLock()
    private static let formatter = ISO8601DateFormatter()

    static func timestamp() -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: Date())
    }
}

/// Append-only log file with a size cap: it used to grow without bound for the
/// lifetime of the install (every TJFLog, VLC log line and PlaybackInfo body).
enum TJFLogFile {
    static let path = NSTemporaryDirectory() + "tjf_playback.log"
    private static let maxBytes = 512 * 1024

    static func append(_ line: String) {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? NSNumber,
           size.intValue >= maxBytes {
            // Oldest history is dropped rather than growing forever.
            try? FileManager.default.removeItem(atPath: path)
        }
        if let fd = fopen(path, "a") {
            fputs(line + "\n", fd)
            fclose(fd)
        }
    }
}
