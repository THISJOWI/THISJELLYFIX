#if canImport(AppIntents)
import AppIntents
import Foundation

// MARK: - ResumePlaybackIntent

public struct ResumePlaybackIntent: AppIntent {
    public static var title: LocalizedStringResource = "Continuar viendo"
    public static var description = IntentDescription("Abre THISJELLYFIX y continúa viendo tu contenido pendiente.")
    public static var openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        return .result()
    }
}

// MARK: - AppShortcutsProvider

public struct ThisJellyFixShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                "Continuar viendo en \(.applicationName)",
                "Reanudar reproducción en \(.applicationName)",
                "Pon lo que estaba viendo en \(.applicationName)"
            ],
            shortTitle: "Continuar viendo",
            systemImageName: "play.fill"
        )
    }
}
#endif
