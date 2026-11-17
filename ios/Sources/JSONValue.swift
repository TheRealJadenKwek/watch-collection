import Foundation

/// Any JSON value, kept raw. A document read from iCloud keeps every key, including ones this build does
/// not know, so `CollectionMerge` can carry them through and write them back.
///
/// Numbers are one case, a `Double`, so 42 and 42.0 are the same value, as Python compares them.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool before Double: JSONDecoder reads only true and false as a Bool, and never a Bool as a number.
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// The fields, when this is an object.
    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// The items, when this is an array.
    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// The value as JSON sees it: encoded with a plain `JSONEncoder`, as the app sends documents today, so
    /// optionals that are nil are absent rather than null.
    init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// Decodes a model from this value with a plain `JSONDecoder`.
    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: canonicalData)
    }

    /// One spelling per value, for fingerprints and for the bytes written to iCloud: keys sorted by Unicode
    /// code point, no spaces, a whole number below 2^63 without a fraction ("42", never "42.0"), any other number in
    /// its shortest form. Strings are escaped as Python's `json.dumps` escapes them (ASCII only, `\u00e9` for é), so
    /// a document is spelled byte for byte as `sync.fingerprint` spells it only when it holds no float with a
    /// whole value (Python writes "42.0") and no integer a Double cannot hold below 2^63. Past 2^53 most
    /// integers are rounded as they are read (9007199254740993 comes back as 9007199254740992), and from
    /// 2^63 on this writes the exponent form where Python writes every digit; CollectionMergeTests lists
    /// both as known differences.
    /// A number that is not finite (which no JSON text can hold) is written as null.
    var canonicalData: Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4096)
        write(into: &bytes)
        return Data(bytes)
    }

    /// The order `sorted()` puts Python strings in: by code point. UTF-8 bytes compare in that same order.
    static func codePointOrder(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    /// A number as `canonicalData` writes it.
    static func canonicalNumber(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        // 2^63: every whole Double below it converts to Int64 exactly; -0 is written as 0.
        if value.rounded(.towardZero) == value, abs(value) < 9_223_372_036_854_775_808 {
            return String(Int64(value))
        }
        // Swift's shortest round-trip form, which is also Python's repr of a float (1e-07, 0.1, 1.5e+300).
        return value.description
    }

    private func write(into bytes: inout [UInt8]) {
        switch self {
        case .null:
            bytes.append(contentsOf: "null".utf8)
        case let .bool(value):
            bytes.append(contentsOf: (value ? "true" : "false").utf8)
        case let .number(value):
            bytes.append(contentsOf: Self.canonicalNumber(value).utf8)
        case let .string(value):
            Self.writeString(value, into: &bytes)
        case let .array(items):
            bytes.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { bytes.append(UInt8(ascii: ",")) }
                item.write(into: &bytes)
            }
            bytes.append(UInt8(ascii: "]"))
        case let .object(fields):
            bytes.append(UInt8(ascii: "{"))
            for (index, key) in fields.keys.sorted(by: Self.codePointOrder).enumerated() {
                if index > 0 { bytes.append(UInt8(ascii: ",")) }
                Self.writeString(key, into: &bytes)
                bytes.append(UInt8(ascii: ":"))
                fields[key]!.write(into: &bytes)
            }
            bytes.append(UInt8(ascii: "}"))
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Python's `json.dumps` with `ensure_ascii`: printable ASCII as is, the short escapes for quote,
    /// backslash and five control characters, and every other UTF-16 unit as `\uXXXX` in lower-case hex
    /// (a character beyond the BMP becomes its surrogate pair, as Python writes it).
    private static func writeString(_ string: String, into bytes: inout [UInt8]) {
        bytes.append(UInt8(ascii: "\""))
        for unit in string.utf16 {
            switch unit {
            case 0x22: bytes.append(contentsOf: [0x5C, 0x22])
            case 0x5C: bytes.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: bytes.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: bytes.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: bytes.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x08: bytes.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: bytes.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x20...0x7E: bytes.append(UInt8(unit))
            default:
                bytes.append(contentsOf: [0x5C, UInt8(ascii: "u")])
                for shift in stride(from: 12, through: 0, by: -4) {
                    bytes.append(hexDigits[Int((unit >> UInt16(shift)) & 0xF)])
                }
            }
        }
        bytes.append(UInt8(ascii: "\""))
    }
}
