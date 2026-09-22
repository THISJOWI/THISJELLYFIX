import SwiftUI

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

    func load(url: URL) {
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
                let (data, _) = try await URLSession.shared.data(for: request)

                guard let downloaded = PlatformImage(data: data) else {
                    await MainActor.run { self.isLoading = false }
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
                await MainActor.run { self.isLoading = false }
            }
        }
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

    @StateObject private var loader = CachedImageLoader()

    init(url: URL?, placeholder: String = "?", width: CGFloat = 150, height: CGFloat = 220) {
        self.url = url
        self.placeholder = placeholder
        self.width = width
        self.height = height
    }

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
                    .frame(width: width, height: height)
            } else {
                placeholderView
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            if let url {
                loader.load(url: url)
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
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
