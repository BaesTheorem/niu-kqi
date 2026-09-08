import Foundation
import SwiftUI

/// Display units. The scooter always speaks metric on the wire (speeds are
/// km/h times ten, distances are metres), so this converts at the edge only and
/// never touches a value on its way to the vehicle.
enum Units: String, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }

    var distanceUnit: String { self == .metric ? "km" : "mi" }
    var speedUnit: String { self == .metric ? "km/h" : "mph" }
    var label: String { self == .metric ? "Metric" : "Imperial" }

    private static let milesPerKm = 0.621371

    func distance(_ km: Double) -> Double { self == .metric ? km : km * Self.milesPerKm }
    func speed(_ kmh: Double) -> Double { self == .metric ? kmh : kmh * Self.milesPerKm }
    /// Back to km/h for anything being written to the scooter.
    func toKmh(_ shown: Double) -> Double { self == .metric ? shown : shown / Self.milesPerKm }

    func distanceText(_ km: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", distance(km))
    }
    func speedText(_ kmh: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", speed(kmh))
    }
}
