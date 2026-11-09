import Foundation
import UIKit
import WidgetKit

/// The one-shot power-on behind the Lock Screen widget and control.
///
/// It does what the NIU app's power button does for a kick scooter: one
/// `db_k_cmd = 1` write over the verified link, with a 2 s wait for the ack and
/// one retry if the link is still up. Two reads are added around it. The power
/// bit is read first, so a tap on a scooter that is already on sends nothing,
/// and read again afterwards, so the widget shows what the scooter reports
/// rather than what was sent. It never sends "off".
@MainActor
final class ScooterPower {
    static let shared = ScooterPower()
    private init() {}

    private var running = false

    func powerOn(trigger: String) async {
        guard !running else { return }        // a second tap while the first runs
        running = true
        defer { running = false }

        let started = Date()
        var entry = PowerLog.Entry(trigger: trigger,
                                   foreground: UIApplication.shared.applicationState == .active)
        entry.sinceLaunchMs = Self.ms(since: AppLaunch.at)
        // A start line, so an attempt the system cut short still shows up.
        var startLine = entry
        startLine.phase = "start"
        PowerLog.append(startLine)
        let ble = ScooterBLE.shared
        NIUFields.load()
        if ble.creds == nil {
            ble.creds = BLECredsCache.load()
            entry.creds = ble.creds == nil ? "none" : "keychain"
        } else {
            entry.creds = "in memory"
        }

        var poweredOn: Bool?
        var battery = ScooterShared.load()?.battery
        var message = ""
        var ok = false

        if ble.creds?.blePassword?.isEmpty ?? true {
            message = "Open KQi Air once to sign in"
        } else {
            do {
                // A first tap has no saved identifier yet and has to scan, which
                // iOS runs slower in the background.
                try await ble.connectNow(timeout: 12)
                entry.route = ble.lastRoute
                entry.connectedMs = Self.ms(since: started)
                let before = try await readPower(ble)
                entry.before = before.on
                battery = before.battery ?? battery
                if before.on == true {
                    poweredOn = true; ok = true; message = "Already on"
                } else {
                    try await sendOn(ble, entry: &entry)
                    // The dashboard takes a moment to boot, and one read at
                    // 400 ms reported "off" for a power-on that worked. Poll the
                    // bit instead, for up to 3 s.
                    let wrote = Date()
                    var after: (on: Bool?, battery: Int?) = (nil, nil)
                    repeat {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if let r = try? await readPower(ble) { after = r }
                    } while after.on != true && Date().timeIntervalSince(wrote) < 3
                    entry.confirmMs = Self.ms(since: wrote)
                    entry.after = after.on
                    battery = after.battery ?? battery
                    poweredOn = after.on
                    ok = after.on == true
                    message = ok ? "On" : "Sent, but it reads off"
                }
            } catch {
                entry.route = ble.lastRoute
                message = (error as? NIUProto.Err)?.msg ?? error.localizedDescription
            }
        }

        // A background launch has no screen that needs the session, so park it:
        // the link stays up, as the NIU app leaves it, and nothing wakes the app.
        if UIApplication.shared.applicationState != .active { ble.park() }

        entry.battery = battery
        entry.ok = ok
        entry.result = message
        entry.totalMs = Self.ms(since: started)
        PowerLog.append(entry)
        Self.publish(poweredOn: poweredOn, battery: battery, message: message, ok: ok)
    }

    private func readPower(_ ble: ScooterBLE) async throws -> (on: Bool?, battery: Int?) {
        var on: Bool?
        var battery: Int?
        for (k, v) in try await ble.read(["db_k_realtime_status", "bms_soc_rt"], replyTimeout: 3) {
            if k == "db_k_realtime_status", let n = v.intValue { on = n & 1 == 1 }
            if k == "bms_soc_rt", let n = v.intValue, (0...100).contains(n) { battery = n }
        }
        return (on, battery)
    }

    /// The NIU app retries a failed command once, unless the link dropped.
    private func sendOn(_ ble: ScooterBLE, entry: inout PowerLog.Entry) async throws {
        entry.writes = 1
        do {
            try await ble.run("on", replyTimeout: 2.5)
        } catch {
            guard ble.state == .ready else { throw error }
            entry.writes = 2
            try await ble.run("on", replyTimeout: 2.5)
        }
    }

    /// Hand the latest state to the widget and the control, and redraw them.
    /// A nil message keeps the last line, for plain status reads.
    static func publish(poweredOn: Bool?, battery: Int?, message: String?, ok: Bool) {
        let old = ScooterShared.load()
        let snap = ScooterSnapshot(poweredOn: poweredOn ?? old?.poweredOn,
                                   battery: battery ?? old?.battery,
                                   message: message ?? old?.message ?? "",
                                   ok: message == nil ? (old?.ok ?? true) : ok,
                                   updated: .now)
        ScooterShared.save(snap)
        WidgetCenter.shared.reloadTimelines(ofKind: ScooterShared.widgetKind)
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: ScooterShared.controlKind)
        }
    }

    private static func ms(since d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }
}

/// When this process started, to tell a cold background launch from a warm one.
enum AppLaunch {
    static let at = Date()
}

/// One line per power attempt in Documents/power-log.jsonl, so a run that failed
/// on the Lock Screen can be read back afterwards:
/// `xcrun devicectl device copy from --domain-type appDataContainer
///  --domain-identifier com.alexhedtke.KQiRides --source Documents/power-log.jsonl`.
enum PowerLog {
    struct Entry: Codable {
        var at = Date()
        var phase = "done"
        var trigger: String
        var foreground: Bool
        var creds = ""
        var route = ""
        var sinceLaunchMs: Int?
        var connectedMs: Int?
        var before: Bool?
        var writes = 0
        var after: Bool?
        var confirmMs: Int?
        var battery: Int?
        var ok = false
        var result = ""
        var totalMs = 0
    }

    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("power-log.jsonl")
    }

    static func append(_ e: Entry) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let line = try? enc.encode(e) else { return }
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        lines.append(String(decoding: line, as: UTF8.self))
        let kept = lines.suffix(200).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }
}
