import AppIntents
import WidgetKit

/// Turn the scooter's dashboard on from the Lock Screen without opening the app.
///
/// Both targets compile this type, because the widget's button has to name it.
/// The work never runs in the extension: an intent that conforms to
/// `LiveActivityIntent` is performed in the app's own process, which the system
/// launches in the background when it is not running (Apple, "Adding
/// interactivity to widgets and Live Activities"). Only that process has the
/// Bluetooth permission, the `bluetooth-central` background mode and the
/// scooter credentials.
struct PowerOnScooterIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Power on KQi Air"
    static var description = IntentDescription("Connect to the scooter over Bluetooth and turn its dashboard on.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        // Reaching this line means the system ran the intent in the widget
        // process, against the documented behavior. Show that on the widget
        // instead of failing without a word.
        ScooterShared.save(ScooterSnapshot(poweredOn: nil, battery: ScooterShared.load()?.battery,
                                           message: "Ran in the widget, not the app",
                                           ok: false, updated: .now))
        WidgetCenter.shared.reloadAllTimelines()
        #else
        await ScooterPower.shared.powerOn(trigger: "intent")
        #endif
        return .result()
    }
}
