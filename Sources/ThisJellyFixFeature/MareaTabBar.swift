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
        .red
    }
}

struct MareaTabBar: View {
    @Binding var selected: MareaTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(MareaTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.interpolatingSpring(stiffness: 300, damping: 22)) {
                        selected = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 22, weight: selected == tab ? .bold : .regular))
                            .symbolVariant(selected == tab ? .fill : .none)
                            .foregroundStyle(selected == tab ? tab.activeColor : .white.opacity(0.6))

                        Text(tab.label)
                            .font(.system(size: 10, weight: selected == tab ? .semibold : .regular))
                            .foregroundStyle(selected == tab ? tab.activeColor : .white.opacity(0.6))
                    }
                    .frame(width: 64, height: 52)
                    .background(
                        selected == tab
                            ? AnyView(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        Capsule()
                                            .fill(.white.opacity(0.12))
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(.white.opacity(0.18), lineWidth: 0.5)
                                    )
                                    .matchedGeometryEffect(id: "tab_capsule", in: namespace)
                              )
                            : AnyView(EmptyView())
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .fill(.white.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        )
        .padding(.horizontal, 24)
    }

    @Namespace private var namespace
}
