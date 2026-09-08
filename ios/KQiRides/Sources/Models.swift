import Foundation

/// One ride as NIU's cloud returns it.
///
/// The server sends both an unambiguous epoch (`startTime`, ms) and its own
/// `date` field as a yyyyMMdd integer. Those two disagree for any ride that
/// starts after 11:00 local, because the backend buckets rides into calendar
/// days in a UTC+8/+9 timezone while reporting the clock times in yours. The
/// epoch is the trustworthy one, so every date shown in this app is derived
/// from it and `date` is kept only to show what NIU got wrong.
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

    var start: Date { Date(timeIntervalSince1970: Double(startTime) / 1000) }
    var end: Date { Date(timeIntervalSince1970: Double(endTime) / 1000) }

    /// The real calendar day, in the phone's timezone.
    var day: Date { Calendar.current.startOfDay(for: start) }

    /// What NIU thinks the day is, parsed back out of its yyyyMMdd integer.
    var serverDay: Date? {
        var c = DateComponents()
        c.year = date / 10000
        c.month = (date / 100) % 100
        c.day = date % 100
        return Calendar.current.date(from: c)
    }

    /// True when NIU filed this ride under the wrong calendar day.
    var isMisdated: Bool {
        guard let s = serverDay else { return false }
        return !Calendar.current.isDate(s, inSameDayAs: day)
    }

    var km: Double { Double(distance) / 1000 }
}

/// A day's worth of rides, grouped on the corrected date.
struct RideDay: Identifiable {
    let day: Date
    let rides: [Ride]
    var id: Date { day }
    var km: Double { rides.reduce(0) { $0 + $1.km } }
    var correctedCount: Int { rides.filter(\.isMisdated).count }
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
