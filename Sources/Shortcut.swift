import AppIntents

// Lets the Action Button, Back Tap, Siri or Shortcuts open Seth and start listening.
@MainActor
final class Launch: ObservableObject {
    static let shared = Launch()
    @Published var wantsListen = false
}

struct TalkToSeth: AppIntent {
    static var title: LocalizedStringResource = "Talk to Seth"
    static var description = IntentDescription("Opens Seth and starts listening.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Launch.shared.wantsListen = true
        return .result()
    }
}

struct SethShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToSeth(),
                    phrases: ["Talk to \(.applicationName)", "Hey \(.applicationName)", "Ask \(.applicationName)"],
                    shortTitle: "Talk to Seth",
                    systemImageName: "mic.fill")
    }
}
