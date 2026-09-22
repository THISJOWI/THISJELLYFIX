import SwiftUI

enum MareaTab: Int, CaseIterable {
    case home
    case search
    case favorites
    case profile

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .search: "magnifyingglass"
        case .favorites: "heart.fill"
        case .profile: "person.fill"
        }
    }

    var label: String {
        switch self {
        case .home: "Inicio"
        case .search: "Buscar"
        case .favorites: "Favoritos"
        case .profile: "Perfil"
        }
    }

    var activeColor: Color {
        switch self {
        case .home: .purple
        case .search: .white
        case .favorites: .pink
        case .profile: .white
        }
    }
}

struct MareaTabBar: View {
    @Binding var selected: MareaTab

    var body: some View {
        HStack(spacing: 10) {
            ForEach(MareaTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.interpolatingSpring(stiffness: 280, damping: 18)) {
                        selected = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 26, weight: selected == tab ? .bold : .regular))
                            .symbolVariant(selected == tab ? .fill : .none)
                            .foregroundStyle(selected == tab ? tab.activeColor : .white.opacity(0.5))
                            .frame(width: 52, height: 30)

                        Text(tab.label)
                            .font(.system(size: 10, weight: selected == tab ? .semibold : .regular))
                            .foregroundStyle(selected == tab ? tab.activeColor : .white.opacity(0.5))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        selected == tab
                            ? RoundedRectangle(cornerRadius: 20)
                                .fill(.white.opacity(0.15))
                                .matchedGeometryEffect(id: "tab_bg", in: namespace)
                            : nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 28)
                    .fill(.white.opacity(0.04))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .padding(.horizontal, 28)
    }

    @Namespace private var namespace
}
