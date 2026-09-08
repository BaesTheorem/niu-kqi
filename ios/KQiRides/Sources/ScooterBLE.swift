import Foundation
import CoreBluetooth

/// Live BLE link to the scooter, ported from the `Scooter` session in `kqi_ble.py`.
///
/// CoreBluetooth never exposes a peripheral's MAC, so the scooter is matched on
/// its advertised name and NIU service UUIDs, and the MAC needed by the v2
/// handshake comes from the cloud (`bleinfo`) rather than from the scan.
@MainActor
final class ScooterBLE: NSObject, ObservableObject {

    enum State: Equatable {
        case idle, poweredOff, unauthorized, scanning, connecting, handshaking, ready
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .poweredOff: return "Bluetooth off"
            case .unauthorized: return "Bluetooth not permitted"
            case .scanning: return "Looking for scooter"
            case .connecting: return "Connecting"
            case .handshaking: return "Verifying"
            case .ready: return "Connected"
            case .failed(let m): return m
            }
        }
        var isBusy: Bool {
            switch self { case .scanning, .connecting, .handshaking: return true; default: return false }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var traffic: [String] = []
    @Published private(set) var pushed: [(String, NIUProto.Value)] = []
    @Published var verbose = false

    /// Credentials from the cloud (`bleinfo`).
    var creds: NIUCloud.BLEInfo?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    private var bleVer = 20
    private var key = ""

    private var rx: [String] = []
    private var waiters: [(headers: Set<String>?, cont: CheckedContinuation<String, Error>, deadline: Date)] = []
    private var buf = ""
    private var connectCont: CheckedContinuation<Void, Error>?
    private var scanTimer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func note(_ s: String) {
        traffic.append(s)
        if traffic.count > 400 { traffic.removeFirst(traffic.count - 400) }
    }

    // MARK: - connect

    func connect() async {
        guard central.state == .poweredOn else {
            state = central.state == .unauthorized ? .unauthorized : .poweredOff
            return
        }
        guard state != .ready else { return }
        state = .scanning
        note("scanning for \(creds?.bleName ?? "NIU device")")
        central.scanForPeripherals(withServices: nil)
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .scanning else { return }
                self.central.stopScan()
                self.state = .failed("Scooter not found. Wake it (power button or a nudge) and make sure NIU's app isn't holding the link.")
            }
        }
    }

    func disconnect() {
        scanTimer?.invalidate()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil; notifyChar = nil; writeChar = nil; key = ""
        state = .idle
    }

    // MARK: - frame plumbing

    private func deliver(_ frame: String) {
        if verbose { note("<- \(frame)") }
        if let i = waiters.firstIndex(where: { $0.headers == nil || $0.headers!.contains(String(frame.prefix(4)).lowercased()) }) {
            let w = waiters.remove(at: i)
            w.cont.resume(returning: frame)
            return
        }
        // Unsolicited: decode it for the live monitor rather than dropping it.
        if !key.isEmpty, let fields = try? NIUProto.parsePush(frame, key: key), !fields.isEmpty {
            pushed.append(contentsOf: fields)
            if pushed.count > 200 { pushed.removeFirst(pushed.count - 200) }
        }
        rx.append(frame)
        if rx.count > 100 { rx.removeFirst(rx.count - 100) }
    }

    private func nextFrame(_ headers: Set<String>?, timeout: TimeInterval = 8) async throws -> String {
        if let i = rx.firstIndex(where: { headers == nil || headers!.contains(String($0.prefix(4)).lowercased()) }) {
            return rx.remove(at: i)
        }
        return try await withCheckedThrowingContinuation { cont in
            let deadline = Date().addingTimeInterval(timeout)
            waiters.append((headers, cont, deadline))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let i = self.waiters.firstIndex(where: { $0.deadline == deadline }) {
                    let w = self.waiters.remove(at: i)
                    w.cont.resume(throwing: NIUProto.Err(msg: "no reply from scooter"))
                }
            }
        }
    }

    private func write(_ frameHex: String) throws {
        guard let p = peripheral, let ch = writeChar else { throw NIUProto.Err(msg: "not connected") }
        if verbose { note("-> \(frameHex)") }
        let bytes = try NIUProto.hexToBytes(frameHex)
        let mtu = max(20, p.maximumWriteValueLength(for: .withResponse))
        var i = 0
        while i < bytes.count {
            let chunk = Array(bytes[i..<min(i + mtu, bytes.count)])
            p.writeValue(Data(chunk), for: ch, type: .withResponse)
            i += mtu
        }
    }

    private func send(_ frames: [String]) async throws {
        for (i, f) in frames.enumerated() {
            try write(f)
            if i < frames.count - 1 { try await Task.sleep(nanoseconds: 60_000_000) }
        }
    }

    // MARK: - handshake

    private func handshake() async throws {
        guard let pwd = creds?.blePassword, !pwd.isEmpty else {
            key = ""; note("no BLE password on file; skipping verify"); return
        }
        guard pwd.count == 16 else { throw NIUProto.Err(msg: "blePassword must be 16 characters") }
        state = .handshaking
        if bleVer >= 20 {
            let fk = try NIUProto.firstKey(pwd: pwd, mac: creds?.bleMac)
            try await send([NIUProto.hs1v2(firstKey32: fk.key)])
            let reply = try NIUProto.hs1v2Parse(try await nextFrame(["01b4", "01d4", "01f4"]), firstKey32: fk.key)
            guard String(reply.prefix(8)).lowercased() == fk.random1 else {
                throw NIUProto.Err(msg: "verify step 1: random code mismatch")
            }
            try await send([try NIUProto.hs2v2(reply32: reply, random1: fk.random1)])
            let r2 = try NIUProto.hs2v2Parse(try await nextFrame(["0194", "01d4"]), sessionKey32: reply)
            guard String(r2.prefix(8)).lowercased() == fk.random1 else {
                throw NIUProto.Err(msg: "verify step 2: random code mismatch")
            }
            key = reply
        } else {
            let h1 = try NIUProto.hs1v1(pwd: pwd)
            try await send([h1.frame])
            let reply = try NIUProto.hs1v1Parse(try await nextFrame(["01a3", "01c3"]), pwd: pwd)
            try await send([try NIUProto.hs2v1(random32: h1.random, reply32: reply, pwd: pwd)])
            _ = try NIUProto.hs2v1Parse(try await nextFrame(["0183", "01c3"]), pwd: pwd)
            let aes = creds?.bleAes ?? ""
            key = (aes.count == 16 || aes.count == 32) ? aes : ""
        }
        note("verified with the scooter")
        state = .ready
    }

    // MARK: - field traffic

    private var families: [Int] { bleVer >= 21 ? [1, 10] : [1] }

    func read(_ names: [String]) async throws -> [(String, NIUProto.Value)] {
        guard state == .ready else { throw NIUProto.Err(msg: "not connected") }
        var last: Error = NIUProto.Err(msg: "read failed")
        for fam in families {
            do {
                if fam == 10 {
                    try await send([try NIUProto.buildRead5aa5(names)])
                    let fr = try await nextFrame(nil)
                    return try NIUProto.parseFieldsSequential(try NIUProto.parse5aa5(fr, expect: NIUProto.cmdRead).data, names)
                }
                let h = NIUProto.headers[fam]!
                try await send(try NIUProto.buildRead(names, key: key, family: fam))
                var frames: [String] = []
                repeat {
                    frames.append(try await nextFrame([h.readAck.0, h.readAck.1, h.readErr.0, h.readErr.1]))
                } while !NIUProto.isLastFrame(frames.last!)
                return try NIUProto.parseReadFrames(frames, names, key: key, family: fam)
            } catch { last = error }
        }
        throw last
    }

    @discardableResult
    func write(_ values: [(String, Any)]) async throws -> String {
        guard state == .ready else { throw NIUProto.Err(msg: "not connected") }
        var last: Error = NIUProto.Err(msg: "write failed")
        for fam in families {
            do {
                if fam == 10 {
                    try await send([try NIUProto.buildWrite5aa5(values)])
                    let fr = try await nextFrame(nil)
                    return try NIUProto.parse5aa5(fr, expect: NIUProto.cmdWrite).data
                }
                let h = NIUProto.headers[fam]!
                try await send(try NIUProto.buildWrite(values, key: key, family: fam))
                var frames: [String] = []
                repeat {
                    frames.append(try await nextFrame([h.writeAck.0, h.writeAck.1, h.writeErr.0, h.writeErr.1]))
                } while !NIUProto.isLastFrame(frames.last!)
                return try NIUProto.parseWriteFrames(frames, key: key, family: fam)
            } catch { last = error }
        }
        throw last
    }

    /// Send one raw frame and collect whatever comes back for a moment.
    func raw(_ hex: String, listen: TimeInterval = 3) async throws -> [String] {
        try await send([hex])
        var out: [String] = []
        let end = Date().addingTimeInterval(listen)
        while Date() < end {
            if let f = try? await nextFrame(nil, timeout: max(0.2, end.timeIntervalSinceNow)) { out.append(f) }
            else { break }
        }
        return out
    }
}

// MARK: - CoreBluetooth delegates

extension ScooterBLE: CBCentralManagerDelegate, CBPeripheralDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: if self.state == .poweredOff { self.state = .idle }
            case .unauthorized: self.state = .unauthorized
            default: self.state = .poweredOff
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString.lowercased() } ?? []
        Task { @MainActor in
            guard self.state == .scanning else { return }
            let want = self.creds?.bleName ?? ""
            let match = (!want.isEmpty && name.caseInsensitiveCompare(want) == .orderedSame)
                || name.uppercased().hasPrefix("NIU")
                || uuids.contains(where: { NIUProto.services.keys.contains($0) })
            guard match else { return }
            self.scanTimer?.invalidate()
            central.stopScan()
            self.note("found \(name.isEmpty ? "device" : name) at \(RSSI) dBm")
            self.peripheral = peripheral
            peripheral.delegate = self
            self.state = .connecting
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.note("connected, discovering services")
            peripheral.discoverServices(NIUProto.services.keys.map { CBUUID(string: $0) })
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in self.state = .failed(error?.localizedDescription ?? "connect failed") }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.note("disconnected")
            self.peripheral = nil; self.notifyChar = nil; self.writeChar = nil; self.key = ""
            if self.state == .ready { self.state = .idle }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let svc = peripheral.services?.first(where: { NIUProto.services.keys.contains($0.uuid.uuidString.lowercased()) }) else {
                self.state = .failed("No NIU service on this device"); return
            }
            let uuid = svc.uuid.uuidString.lowercased()
            self.bleVer = NIUProto.services[uuid] ?? 20
            self.note("service \(uuid) (bleVer \(self.bleVer))")
            let chars = NIUProto.charsFor(uuid)
            peripheral.discoverCharacteristics([CBUUID(string: chars.notify), CBUUID(string: chars.write)], for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            let chars = NIUProto.charsFor(service.uuid.uuidString.lowercased())
            for c in service.characteristics ?? [] {
                let u = c.uuid.uuidString.lowercased()
                if u == chars.notify { self.notifyChar = c; peripheral.setNotifyValue(true, for: c) }
                if u == chars.write { self.writeChar = c }
            }
            guard self.notifyChar != nil, self.writeChar != nil else {
                self.state = .failed("NIU characteristics missing"); return
            }
            do { try await self.handshake() }
            catch { self.state = .failed(error.localizedDescription) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let d = characteristic.value else { return }
        let hex = d.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            // 5aa5 frames arrive in pieces and carry their own length; the 20-byte
            // families never split, so a multiple of 40 hex chars is N whole frames.
            if !self.buf.isEmpty || hex.hasPrefix("5aa5") {
                self.buf += hex
                while NIUProto.frame5aa5Complete(self.buf) {
                    let need = ((Int(String(Array(self.buf)[4..<8]), radix: 16) ?? 0) + 4) * 2
                    self.deliver(String(self.buf.prefix(need)))
                    self.buf = String(self.buf.dropFirst(need))
                }
                return
            }
            if hex.count % 40 == 0 {
                let c = Array(hex)
                for i in stride(from: 0, to: c.count, by: 40) { self.deliver(String(c[i..<i+40])) }
            } else {
                self.deliver(hex)
            }
        }
    }
}
