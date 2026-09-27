import Foundation
import Network
import ThisJellyFixCore

/// Manages Local Network permission triggers for iOS 14+ / macOS 15+.
///
/// On iOS 14+, regular URLSession requests to local IP addresses (e.g. Radarr/Sonarr on 192.168.x.x)
/// do not reliably trigger Apple's system Local Network permission dialog, resulting in silent
/// connection failures or POSIX error 50 (network down).
///
/// Starting a lightweight `NWBrowser` for a declared `NSBonjourServices` entry prompts iOS
/// to display the system permission alert.
public final class LocalNetworkAuthorizer: NSObject, @unchecked Sendable {
    public static let shared = LocalNetworkAuthorizer()

    private var browser: NWBrowser?
    private var isPrompting = false
    private let lock = NSLock()

    private override init() {
        super.init()
    }

    /// Triggers the system Local Network permission prompt if not yet granted or prompted.
    public func triggerPrompt() {
        lock.lock()
        guard !isPrompting else {
            lock.unlock()
            return
        }
        isPrompting = true
        lock.unlock()

        TJFLog("LocalNetworkAuthorizer: triggering local network permission prompt")

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_bonjour._tcp", domain: nil), using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready, .failed, .cancelled:
                self?.stop()
            default:
                break
            }
        }

        browser.start(queue: .main)

        // Automatically stop browsing after 2.5s so no unnecessary background scanning happens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.stop()
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        browser?.cancel()
        browser = nil
        isPrompting = false
    }
}
