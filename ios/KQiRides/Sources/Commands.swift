import Foundation

/// The command set, copied verbatim from `COMMANDS` in kqi_ble.py.
///
/// These numbers came out of the decompiled NIU app. Nothing here is guessed,
/// and nothing should be added without a source: an unknown command number sent
/// to a live scooter is not a safe experiment. `factory-reset` is deliberately
/// absent from the UI and only reachable from Advanced.
enum Cmd {
    static let foc = "foc_k_cmd"
    static let db = "db_k_cmd"

    static let table: [String: (field: String, value: Int)] = [
        "lock": (foc, 1), "unlock": (foc, 2),
        "on": (db, 1), "off": (db, 2),
        "alarm on": (db, 6), "alarm off": (db, 5),
        "kickstart on": (foc, 5), "kickstart off": (foc, 6),
        "cruise on": (foc, 7), "cruise off": (foc, 8),
        "unit 0": (foc, 12), "unit 1": (foc, 13),
        "fastlock on": (foc, 18), "fastlock off": (foc, 19),
        "daylight on": (db, 9), "daylight off": (db, 10), "daylight led": (db, 11),
        "factory-reset": (db, 100),
    ]

    /// Bit meanings for the status words. A trailing "(?)" marks a label that a
    /// live toggle has not yet confirmed.
    static let bits: [String: [(mask: Int, label: String)]] = [
        "foc_k_function_status1": [
            (1, "Speed unit index 1"), (2, "Kick-start required"), (4, "Cruise control"),
            (256, "EBS bit A"), (512, "EBS bit B"), (1024, "bit 1024 (?)"),
            (2048, "Custom ride mode"), (8192, "Novice course done"),
            (32768, "Fast lock supported"), (65536, "Fast lock on"),
            (131072, "Dynamic mode"),
        ],
        "foc_k_realtime_status1": [
            (2048, "Ride records waiting to sync"), (4096, "Fault records waiting to sync"),
        ],
        "db_k_realtime_status": [(1, "Powered on")],
        "db_k_function_status": [(2, "Alarm sound OFF (bit clear = on)")],
    ]
}

extension ScooterBLE {
    /// Send one of the named commands.
    func run(_ name: String, replyTimeout: TimeInterval = 8) async throws {
        guard let c = Cmd.table[name] else { throw NIUProto.Err(msg: "unknown command '\(name)'") }
        try await write([(c.field, c.value)], replyTimeout: replyTimeout)
    }

    /// Regen braking level 0-3, encoded as two bits of the FOC status word.
    ///
    /// The write replaces the whole word, so the speed unit, kick-start, cruise,
    /// custom mode and fast lock bits are written back from the value that was
    /// read. A read that fails must stop the write: falling back to 0 would
    /// clear every one of them. A reply that belongs to another request parses
    /// as a number too, so two reads have to agree before anything is sent.
    func setEBS(_ level: Int) async throws {
        guard (0...3).contains(level) else { throw NIUProto.Err(msg: "regen level must be 0 to 3") }
        func word() async throws -> Int {
            guard let n = try await read(["foc_k_function_status1"]).first?.1.intValue,
                  (0...0x00FF_FFFF).contains(n) else {
                throw NIUProto.Err(msg: "could not read the settings word; nothing was changed")
            }
            return n
        }
        let cur = try await word()
        guard try await word() == cur else {
            throw NIUProto.Err(msg: "the settings word changed between two reads; nothing was changed")
        }
        var new = cur & ~(256 | 512)
        if level == 1 || level == 3 { new |= 256 }
        if level == 2 || level == 3 { new |= 512 }
        try await write([("foc_k_function_status1", new)])
    }

    func setCustomMode(on: Bool, maxKmh: Double? = nil) async throws {
        var vals: [(String, Any)] = [(Cmd.foc, on ? 10 : 11)]
        if on, let m = maxKmh { vals.append(("foc_k_def_max_speed", Int((m * 10).rounded()))) }
        try await write(vals)
    }

    /// Push the phone's clock to the scooter. The scooter stores a bare u32 with
    /// no timezone, and the app writes a plain UTC epoch, so that is what we send.
    func syncClock() async throws {
        try await write([("db_k_timestamp", Int(Date().timeIntervalSince1970))])
    }
}
