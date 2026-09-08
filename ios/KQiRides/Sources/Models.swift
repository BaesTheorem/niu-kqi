import Foundation

/// One ride as NIU's cloud returns it.
///
/// `startTime` and `endTime` are NOT trustworthy as sent: they run one whole UTC
/// offset ahead of when the ride happened, which is 5 hours in CDT. The proof is
/// causal rather than circumstantial. A ride is buffered on the scooter and
/// uploaded when the phone next connects, and `trackId` carries the upload time
/// as a leading epoch-ms, so a ride must end before it is uploaded. Three rides
/// in this account were stamped up to 4.8 hours AFTER the upload that carried
/// them. Subtracting the local UTC offset is the smallest correction that leaves
/// zero violations, and it lands the tightest ride 11 minutes before its upload.
///
/// The shape of it is a double conversion: a UTC wall clock stored as if it were
/// local and converted to an epoch a second time. That is why the correction is
/// the zone offset rather than a constant, and why it should follow DST on its
/// own. Every ride on this account is from CDT, so the DST half of that is
/// reasoned, not observed.
struct Ride: Codable, Identifiable {
    let trackId: String
    let startTime: Int64
    let endTime: Int64
    let distance: Int          // meters
    let avespeed: Double       // km/h
    let ridingtime: Int        // seconds
    let date: Int              // server's yyyyMMdd, frequently wrong
    let powerConsumption: Int?

    var id: String { trackId }

    enum CodingKeys: String, CodingKey {
        case trackId, startTime, endTime, distance, avespeed, ridingtime, date
        case powerConsumption = "power_consumption"
    }

    /// As-sent, before correction. Only useful for diagnosing the offset.
    var rawStart: Date { Date(timeIntervalSince1970: Double(startTime) / 1000) }

    private static func corrected(_ ms: Int64) -> Date {
        let raw = Date(timeIntervalSince1970: Double(ms) / 1000)
        return raw.addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT(for: raw)))
    }

    var start: Date { Self.corrected(startTime) }
    var end: Date { Self.corrected(endTime) }

    /// A ride that gained charge was not a ride: it is a charging session the
    /// scooter logged as one. Negative consumption is the giveaway.
    var isChargingSession: Bool { (powerConsumption ?? 0) < 0 }

    /// The real calendar day, in the phone's timezone.
    var day: Date { Calendar.current.startOfDay(for: start) }

    var km: Double { Double(distance) / 1000 }
}

/// A day's worth of rides, grouped on the corrected date.
struct RideDay: Identifiable {
    let day: Date
    let rides: [Ride]
    var id: Date { day }
    var km: Double { rides.filter { !$0.isChargingSession }.reduce(0) { $0 + $1.km } }
}

extension Array where Element == Ride {
    /// Group by the corrected day, newest first.
    func groupedByCorrectedDay() -> [RideDay] {
        Dictionary(grouping: self, by: \.day)
            .map { RideDay(day: $0.key, rides: $0.value.sorted { $0.startTime > $1.startTime }) }
            .sorted { $0.day > $1.day }
    }
}

struct Scooter: Codable, Identifiable {
    let snId: String
    let scooterName: String?
    let skuName: String?
    var id: String { snId }

    enum CodingKeys: String, CodingKey {
        case snId = "sn_id"
        case scooterName = "scooter_name"
        case skuName = "sku_name"
    }
}
