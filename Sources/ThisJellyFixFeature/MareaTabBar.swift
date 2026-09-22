import SwiftUI

enum MareaTab: Int, CaseIterable, Hashable {
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

// Custom MareaTabBar replaced by native SwiftUI TabView (iOS 26+).
// Native TabView automatically provides: floating glass material, selection blob,
// minimize on scroll, search tab role, and all Liquid Glass animations.
// See ThisJellyFixRootView.swift for the TabView implementation.
