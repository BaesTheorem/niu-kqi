import Foundation
import CommonCrypto

/// Swift port of `niu_proto.py`: NIU's BLE framing, value codec and handshakes.
///
/// Kept deliberately close to the Python so the two can be diffed line for line.
/// `NIUProto.selfTest()` mirrors the Python `_selftest()` assertions exactly; run
/// it before trusting a build, because a silent codec drift here looks like a
/// broken scooter rather than a broken app.
enum NIUProto {

    struct Err: LocalizedError {
        let msg: String
        var code: String = ""
        var errorDescription: String? { msg }
    }

    // MARK: - hex

    static func hexToBytes(_ s: String) throws -> [UInt8] {
        let chars = Array(s.lowercased())
        guard chars.count % 2 == 0 else { throw Err(msg: "odd-length hex") }
        var out = [UInt8](); out.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { throw Err(msg: "bad hex") }
            out.append(b)
        }
        return out
    }

    static func bytesToHex(_ b: [UInt8]) -> String {
        b.map { String(format: "%02x", $0) }.joined()
    }

    static func padRight(_ hex: String, _ n: Int) -> String {
        hex + String(repeating: "0", count: max(0, n - hex.count))
    }

    // MARK: - checksum / crc

    static func checksum(_ hex: String) -> String {
        let sum = (try? hexToBytes(hex).reduce(0) { $0 + Int($1) }) ?? 0
        return String(format: "%02x", sum % 256)
    }

    static func csOK(_ frame: String) -> Bool {
        guard frame.count >= 4 else { return false }
        return String(frame.suffix(2)).lowercased() == checksum(String(frame.dropLast(2)))
    }

    /// The app's reflected table CRC-16: poly 0xA1E8, init 0xFFFF, no final xor.
    static func crc16(_ data: [UInt8], poly: UInt16 = 0xA1E8, initial: UInt16 = 0xFFFF) -> UInt16 {
        var table = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt16(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ poly : c >> 1 }
            table[i] = c
        }
        var crc = initial
        for b in data { crc = (crc >> 8) ^ table[Int((UInt16(b) ^ crc) & 0xFF)] }
        return crc
    }

    // MARK: - AES-ECB

    static func aesKey(_ key: String) throws -> [UInt8] {
        if key.count == 16 { return Array(key.utf8) }
        if key.count == 32 { return try hexToBytes(key) }
        throw Err(msg: "AES key must be 16 chars or 32 hex")
    }

    private static func crypt(_ hex32: String, _ key: String, encrypt: Bool) throws -> String {
        if key.isEmpty { return hex32 }
        guard hex32.count == 32 else { throw Err(msg: "AES block must be 16 bytes") }
        let input = try hexToBytes(hex32)
        let k = try aesKey(key)
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            k, k.count, nil, input, input.count, &out, out.count, &moved)
        guard status == kCCSuccess, moved == 16 else { throw Err(msg: "AES failed (\(status))") }
        return bytesToHex(out)
    }

    static func aesEnc(_ hex32: String, _ key: String) throws -> String { try crypt(hex32, key, encrypt: true) }
    static func aesDec(_ hex32: String, _ key: String) throws -> String { try crypt(hex32, key, encrypt: false) }
}
