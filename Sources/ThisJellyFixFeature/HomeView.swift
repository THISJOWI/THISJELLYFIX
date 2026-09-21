import SwiftUI
import ThisJellyFixCore

struct HomeView: View {
    let libraryModel: LibraryModel
    let userName: String
    let onLogout: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text("La Marea")
                            .font(.largeTitle.bold())
                        Text("Hola, \(userName)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        onLogout()
                    } label: {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                    }
                }
                .padding(.horizontal, 32)

                if libraryModel.isLoading && libraryModel.rows.isEmpty {
                    ProgressView("Cargando biblioteca…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if let error = libraryModel.errorMessage, libraryModel.rows.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .multilineTextAlignment(.center)
                        Button("Reintentar") {
                            Task { await libraryModel.load() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    ForEach(libraryModel.rows) { row in
                        ContentRowView(row: row, libraryModel: libraryModel)
                    }
                }
            }
            .padding(.top, 16)
        }
    }
}

private struct ContentRowView: View {
    let row: ContentRow
    let libraryModel: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title)
                .font(.title3.bold())
                .padding(.horizontal, 32)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(row.items) { item in
                        MediaCardView(
                            item: item,
                            imageURL: libraryModel.imageURL(for: item)
                        )
                    }
                }
                .padding(.horizontal, 32)
            }
        }
    }
}
