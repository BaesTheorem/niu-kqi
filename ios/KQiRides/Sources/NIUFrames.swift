import Foundation
import CryptoKit

extension NIUProto {

    static let serviceBase = "8ec94e3%d-f315-4f60-9fb8-838830daea5%d"
    /// service uuid -> BLE version. 10/20 are 20-byte AES frames, 21 is 5aa5.
    static let services: [String: Int] = [
        String(format: serviceBase, 0, 0): 10,
        String(format: serviceBase, 0, 1): 20,
        String(format: serviceBase, 0, 2): 21,
    ]
    static let frameTail = "96"
    /// byte offset applied to 5aa5 payloads
    static let obf: UInt8 = 51

    /// (notify characteristic, write characteristic) for a NIU service UUID.
    static func charsFor(_ serviceUUID: String) -> (notify: String, write: String) {
        let v = Int(String(serviceUUID.lowercased().suffix(1))) ?? 0
        return (String(format: serviceBase, 1, v), String(format: serviceBase, 2, v))
    }

    static func randomHex(_ bytes: Int) -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    // MARK: - family 1 / 2 (20-byte frames)

    struct Headers {
        let read: (String, String), readAck: (String, String), readErr: (String, String)
        let write: (String, String), writeAck: (String, String), writeErr: (String, String)
    }

    static let headers: [Int: Headers] = [
        1: Headers(read: ("0121", "0101"), readAck: ("01a1", "0181"), readErr: ("01e1", "01c1"),
                   write: ("0122", "0102"), writeAck: ("01a2", "0182"), writeErr: ("01e2", "01c2")),
        2: Headers(read: ("012f", "010f"), readAck: ("01af", "018f"), readErr: ("01ef", "01cf"),
                   write: ("0130", "0110"), writeAck: ("01b0", "0190"), writeErr: ("01f0", "01d0")),
    ]

    /// Split data into 16-byte AES blocks, one 20-byte frame each.
    static func buildChunked(_ firstHdr: String, _ nextHdr: String, _ dataHex: String, _ key: String) throws -> [String] {
        let n = max(1, (dataHex.count + 31) / 32)
        let chars = Array(dataHex)
        var frames: [String] = []
        for i in 0..<n {
            let lo = min(i * 32, chars.count), hi = min((i + 1) * 32, chars.count)
            let chunk = padRight(String(chars[lo..<hi]), 32)
            let body = (i == 0 ? firstHdr : nextHdr) + String(format: "%02x", n - i - 1) + (try aesEnc(chunk, key))
            frames.append(body + checksum(body))
        }
        return frames
    }

    static func buildRead(_ names: [String], key: String, family: Int = 1) throws -> [String] {
        let h = headers[family]!
        let data = try names.map { try NIUFields.spec($0).code.lowercased() }.joined()
        return try buildChunked(h.read.0, h.read.1, data, key)
    }

    static func buildWrite(_ values: [(String, Any)], key: String, family: Int = 1) throws -> [String] {
        let h = headers[family]!
        var data = ""
        for (n, v) in values {
            let spec = try NIUFields.spec(n)
            data += spec.code.lowercased() + (try encodeValue(spec, v))
        }
        return try buildChunked(h.write.0, h.write.1, data, key)
    }

    /// A 5aa5 frame stands alone; otherwise index byte 00 closes the reply.
    static func isLastFrame(_ frame: String) -> Bool {
        if frame.prefix(4).lowercased() == "5aa5" { return true }
        let c = Array(frame)
        return c.count >= 6 && String(c[4..<6]) == "00"
    }

    static func errorCode(_ frame: String, _ key: String) -> String {
        if key.isEmpty { return String(Array(frame)[6..<8]).uppercased() }
        let body = String(frame.dropFirst(6).dropLast(2))
        return String(((try? aesDec(body, key)) ?? "").prefix(2)).uppercased()
    }

    /// Reassemble a family-1 read reply and split it into fields.
    static func parseReadFrames(_ frames: [String], _ names: [String], key: String, family: Int = 1) throws -> [(String, Value)] {
        let h = headers[family]!
        var receivable = 0, actual = 0, data = ""
        for f in frames {
            guard csOK(f) else { throw Err(msg: "bad checksum in reply frame \(f)") }
            let hdr = String(f.prefix(4)).lowercased()
            let idx = String(Array(f)[4..<6]).lowercased()
            if idx == "ff" { continue }
            let body = String(f.dropFirst(6).dropLast(2))
            if hdr == h.readAck.0 {
                receivable = (Int(idx, radix: 16) ?? 0) + 1
                data += try aesDec(body, key); actual += 1
            } else if hdr == h.readAck.1 {
                data += try aesDec(body, key); actual += 1
            } else if hdr == h.readErr.0 || hdr == h.readErr.1 {
                let c = errorCode(f, key)
                throw Err(msg: "scooter refused the read (error \(c))", code: c)
            } else {
                throw Err(msg: "unexpected reply header \(hdr)")
            }
        }
        guard receivable == actual else { throw Err(msg: "frame loss: expected \(receivable), got \(actual)") }
        return try parseFieldsSequential(data, names)
    }

    /// Validate a family-1 write reply; returns the result byte ("00" = ok).
    static func parseWriteFrames(_ frames: [String], key: String, family: Int = 1) throws -> String {
        let h = headers[family]!
        guard let last = frames.last else { throw Err(msg: "empty write reply") }
        guard csOK(last) else { throw Err(msg: "bad checksum in write reply") }
        let hdr = String(last.prefix(4)).lowercased()
        if hdr == h.writeErr.0 || hdr == h.writeErr.1 {
            let c = errorCode(last, key)
            throw Err(msg: "scooter refused the write (error \(c))", code: c)
        }
        guard hdr == h.writeAck.0 || hdr == h.writeAck.1 else { throw Err(msg: "unexpected write reply header \(hdr)") }
        guard String(Array(last)[4..<6]) == "00" else { throw Err(msg: "write reply did not finish") }
        return errorCode(last, key)
    }

    static func parsePush(_ frame: String, key: String) throws -> [(String, Value)] {
        guard csOK(frame) else { throw Err(msg: "bad checksum in push frame") }
        return parseFieldsCoded(try aesDec(String(frame.dropFirst(6).dropLast(2)), key))
    }

    // MARK: - family 10 (5aa5 frames)

    static let cmdRead = "01", cmdWrite = "02"

    static func build5aa5(_ payloadHex: String, _ cmd: String) throws -> String {
        let ob = bytesToHex(try hexToBytes(payloadHex).map { $0 &+ obf })
        let frame = "5aa5" + String(format: "%04x", ob.count / 2 + 3) + cmd + ob
        return frame + checksum(frame) + frameTail
    }

    static func frame5aa5Complete(_ buf: String) -> Bool {
        guard buf.count >= 8, buf.prefix(4).lowercased() == "5aa5" else { return false }
        let ln = Int(String(Array(buf)[4..<8]), radix: 16) ?? 0
        return buf.count >= (ln + 4) * 2
    }

    static func parse5aa5(_ frame: String, expect: String? = nil) throws -> (cmd: String, data: String) {
        let f = frame.lowercased()
        guard f.prefix(4) == "5aa5" else { throw Err(msg: "bad 5aa5 header") }
        guard f.hasSuffix(frameTail) else { throw Err(msg: "bad 5aa5 tail") }
        guard csOK(String(f.dropLast(2))) else { throw Err(msg: "bad 5aa5 checksum") }
        let ln = Int(String(Array(f)[4..<8]), radix: 16) ?? 0
        guard f.count == (ln + 4) * 2 else { throw Err(msg: "bad 5aa5 length") }
        let cmd = String(Array(f)[8..<10])
        let payload = String(Array(f)[10..<(10 + (ln - 3) * 2)])
        let data = bytesToHex(try hexToBytes(payload).map { $0 &- obf })
        if let expect, let want = Int(expect, radix: 16), let got = Int(cmd, radix: 16) {
            if got == (want | 0xC0) {
                let c = String(data.prefix(2)).uppercased()
                throw Err(msg: "scooter refused command \(expect) (error \(c))", code: c)
            }
            guard got == (want | 0x80) else { throw Err(msg: "unexpected 5aa5 reply \(cmd) for \(expect)") }
        }
        return (cmd, data)
    }

    static func buildRead5aa5(_ names: [String]) throws -> String {
        try build5aa5(names.map { try NIUFields.spec($0).code.lowercased() }.joined(), cmdRead)
    }

    static func buildWrite5aa5(_ values: [(String, Any)]) throws -> String {
        var data = ""
        for (n, v) in values {
            let spec = try NIUFields.spec(n)
            data += spec.code.lowercased() + (try encodeValue(spec, v))
        }
        return try build5aa5(data, cmdWrite)
    }
}
