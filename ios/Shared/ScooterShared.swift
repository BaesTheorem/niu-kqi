import Foundation

/// What the Lock Screen widget and control show. The app writes it after every
/// power attempt and every status read; the widget extension only reads it,
/// through the shared App Group. The extension never talks to the scooter.
struct ScooterSnapshot: Codable, Equatable {
    /// `db_k_realtime_status` bit 1, as last read. Nil when the read failed.
    var poweredOn: Bool?
    /// `bms_soc_rt`, as last read.
    var battery: Int?
    /// One short line for the widget: "On", "Already on", or why it failed.
    var message: String
    var ok: Bool
    var updated: Date
}

enum ScooterShared {
    static let appGroup = "group.com.alexhedtke.KQiRides"
    static let widgetKind = "com.alexhedtke.KQiRides.PowerWidget"
    static let controlKind = "com.alexhedtke.KQiRides.PowerControl"
    private static let key = "scooterSnapshot"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static func load() -> ScooterSnapshot? {
        guard let d = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ScooterSnapshot.self, from: d)
    }

    static func save(_ s: ScooterSnapshot) {
        if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: key) }
    }
}
