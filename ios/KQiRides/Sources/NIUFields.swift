import Foundation

/// The field table, loaded from the same `data/fields.json` the CLI uses.
struct FieldSpec: Codable {
    let code: String
    let len: Int
    let type: String
}

enum NIUFields {
    /// kick-scooter fields (foc_k_*, db_k_*)
    static private(set) var kconfig: [String: FieldSpec] = [:]
    /// shared NIU fields (bms_*, ecu_*, db_*, foc_*)
    static private(set) var generic: [String: FieldSpec] = [:]
    static private(set) var all: [String: FieldSpec] = [:]
    /// code -> (name, spec). KConfig wins on collisions, matching the Python.
    static private(set) var byCode: [String: (name: String, spec: FieldSpec)] = [:]

    static func load(from override: URL? = nil) {
        guard let url = override ?? Bundle.main.url(forResource: "fields", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let tables = try? JSONDecoder().decode([String: [String: FieldSpec]].self, from: data)
        else { return }
        generic = tables["generic"] ?? [:]
        kconfig = tables["kconfig"] ?? [:]
        all = generic.merging(kconfig) { _, k in k }
        var codes: [String: (String, FieldSpec)] = [:]
        for (n, s) in generic { codes[s.code.uppercased()] = (n, s) }
        for (n, s) in kconfig { codes[s.code.uppercased()] = (n, s) }
        byCode = codes
    }

    static func spec(_ name: String) throws -> FieldSpec {
        guard let s = all[name] else { throw NIUProto.Err(msg: "unknown field '\(name)'") }
        return s
    }
}

extension NIUProto {

    // MARK: - value codec

    static func encodeValue(_ spec: FieldSpec, _ value: Any?) throws -> String {
        let s = value.map { String(describing: $0) } ?? ""
        switch spec.type {
        case "HEX":
            let v = s.lowercased()
            guard v.count <= spec.len * 2 else { throw Err(msg: "value too long, max \(spec.len) bytes") }
            return padRight(v, spec.len * 2)
        case "UTF-8", "US-ASCII":
            let h = bytesToHex(Array(s.utf8))
            guard h.count <= spec.len * 2 else { throw Err(msg: "value too long, max \(spec.len) bytes") }
            return padRight(h, spec.len * 2)
        case "U8", "U16", "U32", "S8", "S16", "S32":
            let n = Int64(s) ?? 0
            let bits = spec.len * 8
            let mask: UInt64 = bits >= 64 ? ~0 : (UInt64(1) << UInt64(bits)) - 1
            return String(format: "%0*llx", spec.len * 2, UInt64(bitPattern: n) & mask)
        case "F32":
            var be = Float(s).map { $0.bitPattern.bigEndian } ?? Float(0).bitPattern.bigEndian
            return bytesToHex(withUnsafeBytes(of: &be) { Array($0) })
        case "F64":
            var be = Double(s).map { $0.bitPattern.bigEndian } ?? Double(0).bitPattern.bigEndian
            return bytesToHex(withUnsafeBytes(of: &be) { Array($0) })
        default:
            throw Err(msg: "unsupported field type \(spec.type)")
        }
    }

    /// Decoded field values stay stringly-typed at the UI boundary; `intValue`
    /// carries the number when there is one, so bit rendering can use it.
    struct Value {
        let display: String
        let intValue: Int?
        let hex: String
    }

    static func decodeValue(_ spec: FieldSpec, _ hexval: String) -> Value {
        switch spec.type {
        case "HEX":
            return Value(display: hexval, intValue: nil, hex: hexval)
        case "UTF-8", "US-ASCII":
            let raw = ((try? hexToBytes(hexval)) ?? []).drop(while: { _ in false })
            let trimmed = Array(raw).reversed().drop(while: { $0 == 0 }).reversed()
            let s = String(decoding: Array(trimmed), as: UTF8.self)
            return Value(display: s, intValue: nil, hex: hexval)
        case "U8", "U16", "U32":
            let n = Int(hexval, radix: 16)
            return Value(display: n.map(String.init) ?? hexval, intValue: n, hex: hexval)
        case "S8", "S16", "S32":
            let bits = hexval.count * 4
            guard let raw = Int(hexval, radix: 16) else { return Value(display: hexval, intValue: nil, hex: hexval) }
            let n = (raw & (1 << (bits - 1))) != 0 ? raw - (1 << bits) : raw
            return Value(display: String(n), intValue: n, hex: hexval)
        case "F32":
            guard let b = try? hexToBytes(hexval), b.count == 4 else { return Value(display: hexval, intValue: nil, hex: hexval) }
            let bits = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
            return Value(display: String(Float(bitPattern: bits)), intValue: nil, hex: hexval)
        case "F64":
            guard let b = try? hexToBytes(hexval), b.count == 8 else { return Value(display: hexval, intValue: nil, hex: hexval) }
            var bits: UInt64 = 0
            for byte in b { bits = bits << 8 | UInt64(byte) }
            return Value(display: String(Double(bitPattern: bits)), intValue: nil, hex: hexval)
        default:
            return Value(display: hexval, intValue: nil, hex: hexval)
        }
    }

    /// Values laid out in request order (read replies).
    static func parseFieldsSequential(_ dataHex: String, _ names: [String]) throws -> [(String, Value)] {
        var out: [(String, Value)] = []
        var pos = 0
        let chars = Array(dataHex)
        for name in names {
            let spec = try NIUFields.spec(name)
            let end = pos + spec.len * 2
            guard end <= chars.count else { throw Err(msg: "reply too short for \(name)") }
            out.append((name, decodeValue(spec, String(chars[pos..<end]))))
            pos = end
        }
        return out
    }

    /// code(3 bytes)+value pairs (unsolicited pushes).
    static func parseFieldsCoded(_ dataHex: String) -> [(String, Value)] {
        var out: [(String, Value)] = []
        var pos = 0
        let chars = Array(dataHex)
        while pos + 6 <= chars.count {
            let code = String(chars[pos..<pos+6]).uppercased()
            guard let hit = NIUFields.byCode[code] else {
                out.append(("code_\(code)", Value(display: String(chars[(pos+6)...]), intValue: nil, hex: "")))
                break
            }
            let end = pos + 6 + hit.spec.len * 2
            guard end <= chars.count else { break }
            out.append((hit.name, decodeValue(hit.spec, String(chars[(pos+6)..<end]))))
            pos = end
        }
        return out
    }
}
