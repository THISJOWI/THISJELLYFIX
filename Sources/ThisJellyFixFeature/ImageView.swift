import SwiftUI
import ThisJellyFixCore

// MARK: - Image Cache

/// Thread-safe image cache using NSCache. Stores decoded images in memory
/// so scrolling through lists doesn't re-fetch from network.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, PlatformImage>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
    }

    func image(for url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    func setImage(_ image: PlatformImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

#if os(macOS)
typealias PlatformImage = NSImage
extension NSImage {
    func resized(to size: NSSize) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: size),
             from: NSRect(origin: .zero, size: self.size),
             operation: .copy,
             fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}
#else
typealias PlatformImage = UIImage
#endif

// MARK: - Cached Async Image Loader

@MainActor
private final class CachedImageLoader: ObservableObject {
    @Published var image: PlatformImage?
    @Published var isLoading = false

    private var currentURL: URL?
    /// Portrait poster to fall back to when the preferred (wide) frame fails:
    /// a failed Thumb/Backdrop fetch used to leave a dead dark card.
    private var fallbackURL: URL?
    private var triedFallbackFor: URL?

    func load(url: URL, fallback: URL? = nil) {
        if let fallback { fallbackURL = fallback }
        // Return cached image immediately
        if let cached = ImageCache.shared.image(for: url) {
            self.image = cached
            return
        }

        guard currentURL != url else { return }
        currentURL = url
        isLoading = true

        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200

                // A 4xx/5xx body decodes to nothing — without the status check
                // we used to treat "error JSON" as a broken image and give up.
                guard (200..<300).contains(status),
                      let downloaded = PlatformImage(data: data) else {
                    await self.retryWithFallback(url: url)
                    return
                }

                // Cache the decoded image
                ImageCache.shared.setImage(downloaded, for: url)

                // Only update if this is still the current request
                if self.currentURL == url {
                    self.image = downloaded
                    self.isLoading = false
                }
            } catch {
                await self.retryWithFallback(url: url)
            }
        }
    }

    /// One retry with the portrait poster when the preferred frame is missing
    /// or unreadable; otherwise settle on the placeholder (never spin forever).
    private func retryWithFallback(url: URL) async {
        guard let fallback = fallbackURL,
              fallback != url,
              triedFallbackFor != url,
              currentURL == url
        else {
            isLoading = false
            return
        }
        TJFLog("image: fallback \(url.lastPathComponent) → \(fallback.lastPathComponent)")
        triedFallbackFor = url
        currentURL = nil
        load(url: fallback)
    }

    func cancel() {
        currentURL = nil
    }
}

// MARK: - MareaImageView

struct MareaImageView: View {
    let url: URL?
    let placeholder: String
    let width: CGFloat
    let height: CGFloat
    /// Tried once when `url` fails (missing Thumb/Backdrop frame) so the card
    /// shows the portrait poster instead of a dead dark rectangle.
    var fallbackURL: URL? = nil

    @StateObject private var loader = CachedImageLoader()

    init(url: URL?, placeholder: String = "?", width: CGFloat = 150, height: CGFloat = 220, fallbackURL: URL? = nil) {
        self.url = url
        self.placeholder = placeholder
        self.width = width
        self.height = height
        self.fallbackURL = fallbackURL
    }

    /// Cards are fixed 2:3-ish tiles; the detail hero asks for 0/0 and gets a
    /// view that fills whatever frame it's given, so a 16:9 backdrop is cropped
    /// to the hero instead of being letterboxed inside a 600x400 box.
    var isFlexible: Bool { width <= 0 && height <= 0 }

    var body: some View {
        Group {
            if let uiImage = loader.image {
                #if os(macOS)
                Image(nsImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #else
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #endif
            } else if loader.isLoading {
                ProgressView()
                    .mareaImageSizing(width: width, height: height)
            } else {
                placeholderView
            }
        }
        .mareaImageSizing(width: width, height: height)
        .task(id: url) {
            if let url {
                loader.load(url: url, fallback: fallbackURL)
            }
        }
    }

    private var placeholderView: some View {
        ZStack {
            Color(red: 0.12, green: 0.14, blue: 0.22)
            Text(placeholder)
                .font(.title2.bold())
                .foregroundStyle(.cyan.opacity(0.6))
        }
        .mareaImageSizing(width: width, height: height)
    }
}

/// Fixed tile (frame + rounded corners) for cards, or fill-the-frame with no
/// corner rounding when the caller passes 0/0.
private struct MareaImageSizing: ViewModifier {
    let width: CGFloat
    let height: CGFloat

    private var isFlexible: Bool { width <= 0 && height <= 0 }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFlexible {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private extension View {
    func mareaImageSizing(width: CGFloat, height: CGFloat) -> some View {
        modifier(MareaImageSizing(width: width, height: height))
    }
}
