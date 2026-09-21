import SwiftUI

struct MareaImageView: View {
    let url: URL?
    let placeholder: String
    let width: CGFloat
    let height: CGFloat

    init(url: URL?, placeholder: String = "?", width: CGFloat = 150, height: CGFloat = 220) {
        self.url = url
        self.placeholder = placeholder
        self.width = width
        self.height = height
    }

    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    placeholderView
                case .empty:
                    ProgressView()
                        .frame(width: width, height: height)
                @unknown default:
                    placeholderView
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            placeholderView
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
