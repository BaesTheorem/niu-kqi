import Foundation
import CryptoKit

extension NIUProto {

    static func md5Hex(_ bytes: [UInt8]) -> String {
        Insecure.MD5.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - handshake, bleVer 10/20 (v1)

    /// First verify frame for bleVer 10. Returns (frame, random32).
    static func hs1v1(pwd: String) throws -> (frame: String, random: String) {
        let rnd = randomHex(16)
        let body = "012301" + (try aesEnc(rnd, pwd))
        return (body + checksum(body), rnd)
    }

    static func hs1v1Parse(_ frame: String, pwd: String) throws -> String {
        let hdr = String(frame.prefix(4)).lowercased()
        if hdr == "01a3" {
            guard csOK(frame) else { throw Err(msg: "bad checksum in verify reply 1") }
            return try aesDec(String(frame.dropFirst(6).dropLast(2)), pwd)
        }
        if hdr == "01c3" { throw Err(msg: "password rejected at step 1 (error \(errorCode(frame, pwd)))") }
        throw Err(msg: "unexpected verify reply header \(hdr)")
    }

    static func hs2v1(random32: String, reply32: String, pwd: String) throws -> String {
        let digest = md5Hex(try hexToBytes(random32 + reply32 + bytesToHex(Array(pwd.utf8))))
        let body = "010300" + (try aesEnc(digest, pwd))
        return body + checksum(body)
    }

    static func hs2v1Parse(_ frame: String, pwd: String) throws -> String {
        let hdr = String(frame.prefix(4)).lowercased()
        if hdr == "0183" {
            guard csOK(frame) else { throw Err(msg: "bad checksum in verify reply 2") }
            let plain = try aesDec(String(frame.dropFirst(6).dropLast(2)), pwd)
            guard plain.hasPrefix("00") else { throw Err(msg: "password verify failed (flag \(plain.prefix(2)))") }
            return plain
        }
        if hdr == "01c3" { throw Err(msg: "password rejected at step 2 (error \(errorCode(frame, pwd)))") }
        throw Err(msg: "unexpected verify reply header \(hdr)")
    }

    // MARK: - handshake, bleVer 20 (v2)

    /// (firstKey32, random1_8) for the v2 handshake.
    static func firstKey(pwd: String, mac: String?, now: Int? = nil) throws -> (key: String, random1: String) {
        let rnd = randomHex(4)
        let ts = (now ?? Int(Date().timeIntervalSince1970)) + 604800
        var body = rnd + String(format: "%08x", UInt32(truncatingIfNeeded: ts))
        let bare = (mac ?? "").replacingOccurrences(of: ":", with: "").lowercased()
        body += bare.count == 12 ? bare : "000000000000"
        body += String(format: "%04x", crc16(try hexToBytes(body)))
        return (try aesEnc(body, pwd), rnd)
    }

    static func hs1v2(firstKey32: String) -> String {
        let body = "013401" + firstKey32
        return body + checksum(body)
    }

    static func hs1v2Parse(_ frame: String, firstKey32: String) throws -> String {
        let hdr = String(frame.prefix(4)).lowercased()
        if hdr == "01b4" {
            guard csOK(frame) else { throw Err(msg: "bad checksum in verify reply 1") }
            return try aesDec(String(frame.dropFirst(6).dropLast(2)), firstKey32)
        }
        if hdr == "01d4" || hdr == "01f4" {
            throw Err(msg: "first key rejected (error \(errorCode(frame, firstKey32)))")
        }
        throw Err(msg: "unexpected verify reply header \(hdr)")
    }

    static func hs2v2(reply32: String, random1: String) throws -> String {
        let r = Array(reply32)
        var body = String(r[8..<16]) + random1 + "000000000000"
        body += String(format: "%04x", crc16(try hexToBytes(body)))
        let frame = "011400" + (try aesEnc(body, reply32))
        return frame + checksum(frame)
    }

    static func hs2v2Parse(_ frame: String, sessionKey32: String) throws -> String {
        let hdr = String(frame.prefix(4)).lowercased()
        if hdr == "0194" {
            guard csOK(frame) else { throw Err(msg: "bad checksum in verify reply 2") }
            return try aesDec(String(frame.dropFirst(6).dropLast(2)), sessionKey32)
        }
        if hdr == "01d4" { throw Err(msg: "session key rejected (error \(errorCode(frame, sessionKey32)))") }
        throw Err(msg: "unexpected verify reply header \(hdr)")
    }

    // MARK: - self test

    /// Mirrors `_selftest()` in niu_proto.py. Returns the failures it found.
    /// An empty array means the Swift codec agrees with the Python one.
    static func selfTest() -> [String] {
        var fail: [String] = []
        func check(_ cond: Bool, _ what: String) { if !cond { fail.append(what) } }
        do {
            check(checksum("5aa5") == String(format: "%02x", (0x5A + 0xA5) % 256), "checksum")
            check(csOK("5aa5" + checksum("5aa5")), "csOK")
            let k = "0123456789abcdef"
            let blk = String(repeating: "00", count: 16)
            check(try aesDec(try aesEnc(blk, k), k) == blk, "aes roundtrip")

            let fk = try firstKey(pwd: k, mac: nil, now: 1700000000)
            check(fk.key.count == 32 && fk.random1.count == 8, "firstKey shape")
            let fr = hs1v2(firstKey32: fk.key)
            check(fr.count == 40 && csOK(fr), "hs1v2 frame")

            let frames = try buildRead(["foc_k_gears", "foc_k_rt_speed"], key: k)
            check(frames.count == 1 && frames[0].count == 40 && frames[0].hasPrefix("0121"), "buildRead")

            let f5 = try buildRead5aa5(["foc_k_gears"])
            let p5 = try parse5aa5(f5)
            check(p5.cmd == "01" && p5.data == "210009", "5aa5 roundtrip")
            check(frame5aa5Complete(f5), "5aa5 complete")

            let reply = try build5aa5("03" + "00c8", "81")
            let parsed = try parseFieldsSequential(try parse5aa5(reply, expect: "01").data,
                                                   ["foc_k_gears", "foc_k_rt_speed"])
            check(parsed.count == 2 && parsed[0].1.intValue == 3 && parsed[1].1.intValue == 200, "sequential fields")

            check(try encodeValue(NIUFields.spec("db_k_timestamp"), 1700000000) == "6553f100", "encode u32")
            check(decodeValue(FieldSpec(code: "", len: 2, type: "S16"), "fffe").intValue == -2, "decode s16")

            let coded = parseFieldsCoded("2100090321000b00c8")
            check(coded.count == 2 && coded[0].1.intValue == 3 && coded[1].1.intValue == 200, "coded fields")

            // Golden vectors captured from the Python implementation. Roundtrip
            // assertions alone cannot catch a wrong constant, because encode and
            // decode cancel it out and agree with each other at any value; these
            // pin the actual bytes on the wire.
            check(try buildRead5aa5(["foc_k_gears"]) == "5aa500060154333cc996", "golden read5aa5")
            check(try buildWrite5aa5([("foc_k_gears", 3)]) == "5aa500070254333c360196", "golden write5aa5")
            check(try buildRead(["foc_k_gears", "foc_k_rt_speed"], key: k)[0]
                  == "012100cea042560759c3b4fc6e545f972daf6dfc", "golden read family1")
            check(try buildWrite([("foc_k_gears", 3)], key: k)[0]
                  == "01220080ee3837611724cb9c3c799f76aaabd4f6", "golden write family1")
            check(try aesEnc(blk, k) == "0b9b15da4b44a0f5151dcfc4c01f35d5", "golden aes")
            check(crc16(try hexToBytes("deadbeef")) == 0x0ad7, "golden crc16")
            check(checksum("210009") == "2a", "golden checksum")
            check(hs1v2(firstKey32: String(repeating: "a", count: 32))
                  == "013401" + String(repeating: "a", count: 32) + "d6", "golden hs1v2")
            // Placeholder MAC on purpose: a real one identifies a specific vehicle.
            check(try aesEnc("11223344655d2b80aabbccddeeff466b", k)
                  == "4c9c9d2f9d71ae73e761a7712d50cf6d", "golden firstKey body")
        } catch {
            fail.append("threw: \(error)")
        }
        return fail
    }
}
