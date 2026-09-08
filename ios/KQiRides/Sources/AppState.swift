import Foundation
import SwiftUI

/// Tiny Keychain wrapper: the NIU session token is a bearer credential for the
/// account, so it does not belong in UserDefaults.
enum Keychain {
    private static let account = "niu.session"

    static func save(_ data: Data) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var session: NIUCloud.Session?
    @Published var scooter: Scooter?
    @Published var rides: [Ride] = []
    @Published var odometerKm: Double?
    @Published var loading = false
    @Published var error: String?

    /// Live values read over BLE, keyed by field name.
    @Published var live: [String: NIUProto.Value] = [:]

    /// Smart Start (proximity unlock) config, which lives in the cloud rather
    /// than on the scooter.
    @Published var smartKey: NIUCloud.SmartKeyConfig?

    /// Display units, remembered between launches. Imperial by default: the
    /// scooter is ridden in the US even though it reports metric on the wire.
    @Published var units: Units = Units(rawValue: UserDefaults.standard.string(forKey: "units") ?? "") ?? .imperial {
        didSet { UserDefaults.standard.set(units.rawValue, forKey: "units") }
    }

    let ble = ScooterBLE()

    var isLoggedIn: Bool { session != nil }

    /// Records that are actually rides. The scooter logs a charging session as a
    /// track too, so counting those would inflate distance with a trip never taken.
    var actualRides: [Ride] { rides.filter { !$0.isChargingSession } }

    var days: [RideDay] { rides.groupedByCorrectedDay() }

    var thisWeekKm: Double {
        let cal = Calendar.current
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return 0 }
        return actualRides.filter { $0.start >= weekStart }.reduce(0) { $0 + $1.km }
    }

    var totalTrackedKm: Double { actualRides.reduce(0) { $0 + $1.km } }

    // MARK: - session

    func restore() {
        NIUFields.load()
        if let d = Keychain.load(), let s = try? JSONDecoder().decode(NIUCloud.Session.self, from: d) {
            session = s
            Task { await bootstrap() }
        }
    }

    func logIn(account: String, password: String) async {
        loading = true; error = nil
        do {
            let s = try await NIUCloud.shared.login(account: account, password: password)
            session = s
            if let d = try? JSONEncoder().encode(s) { Keychain.save(d) }
            await bootstrap()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    func logOut() {
        Keychain.clear()
        session = nil; scooter = nil; rides = []; live = [:]
        ble.disconnect()
    }

    private func validToken() async -> String? {
        guard var s = session else { return nil }
        if s.expiresAt.timeIntervalSinceNow < 3600, !s.refreshToken.isEmpty {
            if let r = try? await NIUCloud.shared.refresh(s) {
                s = r; session = r
                if let d = try? JSONEncoder().encode(r) { Keychain.save(d) }
            }
        }
        return s.token
    }

    /// Pull the account's scooter, its BLE credentials, and the ride history.
    func bootstrap() async {
        guard let token = await validToken() else { return }
        loading = true; error = nil
        do {
            let list = try await NIUCloud.shared.scooters(token: token)
            scooter = list.first
            if let sn = scooter?.snId {
                ble.creds = try? await NIUCloud.shared.bleInfo(token: token, sn: sn)
                rides = try await NIUCloud.shared.allRides(token: token, sn: sn)
                smartKey = try? await NIUCloud.shared.smartKey(token: token, sn: sn)
                if let d = try? await NIUCloud.shared.detail(token: token, sn: sn) {
                    odometerKm = (d["mileage"] as? Double).map { $0 / 1000 }
                        ?? (d["mileage"] as? Int).map { Double($0) / 1000 }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    func refreshRides() async {
        guard let token = await validToken(), let sn = scooter?.snId else { return }
        loading = true
        do { rides = try await NIUCloud.shared.allRides(token: token, sn: sn) }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    // MARK: - BLE convenience

    /// The status set the dashboard shows, read in small groups so one bad
    /// field cannot blank the whole screen.
    static let statusGroups: [[String]] = [
        ["bms_soc_rt", "foc_k_rt_speed", "foc_k_gears"],
        // Speed limits are read one at a time. Grouped, a single unsupported
        // field shifts every later value in the reply, and a misaligned read
        // still parses cleanly, so it arrives looking like data.
        ["foc_k_max_speed"],
        ["foc_k_def_max_speed"],
        ["foc_k_assist_max_speed"],
        ["foc_k_assist_def_max_speed"],
        ["foc_k_no_zero_start"],
        ["db_k_estimated_mileage", "db_k_timestamp"],
        ["foc_k_function_status1", "db_k_function_status"],
        ["db_k_realtime_status", "db_k_f_code"],
        ["foc_k_throttle_mode_set", "foc_k_automatic_shutdown_en"],
        ["foc_k_decorative_light_mode"],
        ["db_k_sn", "db_k_sw_ver", "db_k_hw_ver"],
        ["foc_k_sn", "foc_k_s_ver", "foc_k_h_ver"],
    ]

    /// What a field is allowed to contain. A parse that succeeds is not the same
    /// as a reading that is real: an unsupported field answers 0xFFFF, and a
    /// misaligned reply decodes to a number just as happily as a good one. A
    /// KQi Air does not travel at 6553 km/h, so anything outside these bounds is
    /// dropped rather than shown.
    static let plausible: [String: ClosedRange<Int>] = [
        "foc_k_max_speed": 0...1000,            // km/h x10, so 100 km/h
        "foc_k_def_max_speed": 0...1000,
        "foc_k_assist_max_speed": 0...1000,
        "foc_k_assist_def_max_speed": 0...1000,
        "foc_k_no_zero_start": 0...1000,
        "foc_k_rt_speed": 0...1000,
        "bms_soc_rt": 0...100,
        "foc_k_throttle_mode_set": 0...16,
        "foc_k_gears": 0...16,
        "foc_k_decorative_light_mode": 0...16,
        "db_k_f_code": 0...255,
        "db_k_estimated_mileage": 0...100_000,
    ]

    static func isPlausible(_ name: String, _ v: NIUProto.Value) -> Bool {
        guard let range = plausible[name] else { return true }
        guard let n = v.intValue else { return true }
        return range.contains(n)
    }

    /// The two status words every toggle reads. Refreshed on their own after a
    /// command so the UI is not held hostage by a full sweep of every group.
    static let statusWords = ["foc_k_function_status1", "db_k_function_status"]

    /// Re-read just the bit fields. Cheap enough to run after each toggle.
    func refreshStatusWords() async {
        guard ble.state == .ready else { return }
        for f in Self.statusWords {
            guard let one = try? await ble.read([f]) else { continue }
            for (k, v) in one where Self.isPlausible(k, v) { live[k] = v }
        }
    }

    func refreshStatus() async {
        guard ble.state == .ready else { return }
        for group in Self.statusGroups {
            let vals = (try? await ble.read(group)) ?? []
            // Retry singly when the group failed OR when anything in it came
            // back out of range, because that is what a shifted reply looks like.
            let suspect = vals.isEmpty || vals.contains { !Self.isPlausible($0.0, $0.1) }
            if !suspect {
                for (k, v) in vals { live[k] = v }
                continue
            }
            for f in group {
                guard let one = try? await ble.read([f]) else { continue }
                for (k, v) in one where Self.isPlausible(k, v) { live[k] = v }
            }
        }
    }

    /// Change the proximity-unlock range. Cloud-side, but the server rejects it
    /// with 1322 unless the scooter is reachable.
    func setUnlockRange(_ dbm: Int) async -> String {
        guard let token = await validToken(), let sn = scooter?.snId else { return "Not signed in" }
        do {
            try await NIUCloud.shared.setVehicleSetting(token: token, sn: sn, type: "smart_key_range", value: dbm)
            smartKey = try? await NIUCloud.shared.smartKey(token: token, sn: sn)
            return "Unlock range set"
        } catch {
            return error.localizedDescription
        }
    }

    func connectAndRead() async {
        await ble.connect()
        for _ in 0..<40 {
            if ble.state == .ready { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        await refreshStatus()
    }

    /// Connect on open without stacking attempts. The scooter only advertises
    /// when it is awake and nothing else holds the link, so a failure here is
    /// normal and should stay quiet rather than throwing an error at the user.
    private var connecting = false

    func autoConnect() async {
        guard !connecting, ble.state != .ready, !ble.state.isBusy, ble.creds != nil else { return }
        connecting = true
        defer { connecting = false }
        await connectAndRead()
    }
}
