import AppIntents

// App Intents expose the scooter's hands-free actions to the system: Siri, the
// Action button, and Shortcuts automations (including "when this NFC tag is
// scanned"). Each one opens the app, because the Bluetooth link needs the app's
// process running to scan, handshake and send a frame; a tap on the sticker
// therefore brings KQi Air to the front for the few seconds it takes to connect
// and unlock, with the progress shown in the app's action banner.

@available(iOS 17.0, *)
struct UnlockScooterIntent: AppIntent {
    static var title: LocalizedStringResource = "Unlock KQi Air"
    static var description = IntentDescription("Connect to the scooter over Bluetooth and unlock it.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppState.shared?.performExternal("unlock")
        return .result()
    }
}

@available(iOS 17.0, *)
struct LockScooterIntent: AppIntent {
    static var title: LocalizedStringResource = "Lock KQi Air"
    static var description = IntentDescription("Connect to the scooter over Bluetooth and lock it.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppState.shared?.performExternal("lock")
        return .result()
    }
}

@available(iOS 17.0, *)
struct KQiAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: UnlockScooterIntent(),
            phrases: [
                "Unlock my \(.applicationName)",
                "Unlock my scooter with \(.applicationName)",
            ],
            shortTitle: "Unlock",
            systemImageName: "lock.open"
        )
        AppShortcut(
            intent: LockScooterIntent(),
            phrases: [
                "Lock my \(.applicationName)",
                "Lock my scooter with \(.applicationName)",
            ],
            shortTitle: "Lock",
            systemImageName: "lock"
        )
    }
}
