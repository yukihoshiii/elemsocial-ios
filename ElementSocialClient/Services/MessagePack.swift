import Foundation

enum MessagePackValue {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([String: MessagePackValue])
}

enum MessagePackError: Error {
    case unsupportedType
    case invalidData
    case invalidMapKey
    case unexpectedEOF
}

enum MessagePack {
    static func encode(_ value: MessagePackValue) throws -> Data {
        var data = Data()
        try encode(value, into: &data)
        return data
    }

    static func decode(_ data: Data) throws -> MessagePackValue {
        var index = data.startIndex
        let value = try decodeValue(data, index: &index)
        return value
    }

    static func fromJSONObject(_ object: Any) throws -> MessagePackValue {
        switch object {
        case is NSNull:
            return .null
        case let value as NSNumber:
            // JSONSerialization returns numbers as NSNumber.
            // CFBoolean is also NSNumber, so we must distinguish it explicitly.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            if CFNumberIsFloatType(value) {
                return .float(value.doubleValue)
            }
            let intValue = value.int64Value
            if intValue < 0 {
                return .int(intValue)
            } else {
                return .uint(value.uint64Value)
            }
        case let value as String:
            return .string(value)
        case let value as Data:
            return .binary(value)
        case let value as [Any]:
            return .array(try value.map { try fromJSONObject($0) })
        case let value as [String: Any]:
            var map: [String: MessagePackValue] = [:]
            for (k, v) in value {
                map[k] = try fromJSONObject(v)
            }
            return .map(map)
        default:
            throw MessagePackError.unsupportedType
        }
    }

    static func toJSONObject(_ value: MessagePackValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let b):
            return b
        case .int(let i):
            return i
        case .uint(let u):
            if u <= UInt64(Int64.max) { return Int64(u) }
            return String(u)
        case .float(let d):
            return d
        case .string(let s):
            return s
        case .binary(let d):
            return d.base64EncodedString()
        case .array(let arr):
            return arr.map(toJSONObject)
        case .map(let map):
            var obj: [String: Any] = [:]
            map.forEach { obj[$0.key] = toJSONObject($0.value) }
            return obj
        }
    }

    private static func encode(_ value: MessagePackValue, into data: inout Data) throws {
        switch value {
        case .null:
            data.append(0xc0)
        case .bool(let b):
            data.append(b ? 0xc3 : 0xc2)
        case .int(let i):
            try encodeInt(i, into: &data)
        case .uint(let u):
            try encodeUInt(u, into: &data)
        case .float(let d):
            data.append(0xcb)
            var bits = d.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        case .string(let s):
            let utf8 = Data(s.utf8)
            try encodeLength(prefixes: (0xa0, 0xd9, 0xda, 0xdb), length: utf8.count, into: &data)
            data.append(utf8)
        case .binary(let b):
            try encodeLength(prefixes: (0, 0xc4, 0xc5, 0xc6), length: b.count, into: &data, useFix: false)
            data.append(b)
        case .array(let arr):
            try encodeLength(prefixes: (0x90, 0xdc, 0xdd, 0), length: arr.count, into: &data)
            for v in arr { try encode(v, into: &data) }
        case .map(let map):
            try encodeLength(prefixes: (0x80, 0xde, 0xdf, 0), length: map.count, into: &data)
            for (k, v) in map {
                try encode(.string(k), into: &data)
                try encode(v, into: &data)
            }
        }
    }

    private static func encodeLength(prefixes: (UInt8, UInt8, UInt8, UInt8), length: Int, into data: inout Data, useFix: Bool = true) throws {
        if useFix && length < 16 {
            data.append(prefixes.0 | UInt8(length))
        } else if length <= 0xff {
            data.append(prefixes.1)
            data.append(UInt8(length))
        } else if length <= 0xffff {
            data.append(prefixes.2)
            var be = UInt16(length).bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        } else {
            let p = prefixes.3 == 0 ? prefixes.2 : prefixes.3
            data.append(p)
            var be = UInt32(length).bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
    }

    private static func encodeInt(_ i: Int64, into data: inout Data) throws {
        if i >= 0 {
            try encodeUInt(UInt64(i), into: &data)
            return
        }
        if i >= -32 {
            data.append(UInt8(bitPattern: Int8(i)))
        } else if i >= Int64(Int8.min) {
            data.append(0xd0)
            data.append(UInt8(bitPattern: Int8(i)))
        } else if i >= Int64(Int16.min) {
            data.append(0xd1)
            var be = Int16(i).bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        } else if i >= Int64(Int32.min) {
            data.append(0xd2)
            var be = Int32(i).bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        } else {
            data.append(0xd3)
            var be = i.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
    }

    private static func encodeUInt(_ u: UInt64, into data: inout Data) throws {
        if u <= 0x7f {
            data.append(UInt8(u))
        } else if u <= UInt64(UInt8.max) {
            data.append(0xcc)
            data.append(UInt8(u))
        } else if u <= UInt64(UInt16.max) {
            data.append(0xcd)
            var be = UInt16(u).bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        } else if u <= UInt64(UInt32.max) {
            data.append(0xce)
            var be = UInt32(u).bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        } else {
            data.append(0xcf)
            var be = u.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
    }

    private static func decodeValue(_ data: Data, index: inout Data.Index) throws -> MessagePackValue {
        guard index < data.endIndex else { throw MessagePackError.unexpectedEOF }
        let byte = data[index]
        index = data.index(after: index)

        if byte <= 0x7f { return .uint(UInt64(byte)) }
        if byte >= 0xe0 { return .int(Int64(Int8(bitPattern: byte))) }
        if byte >= 0xa0 && byte <= 0xbf {
            let len = Int(byte & 0x1f)
            return .string(try readString(data, index: &index, length: len))
        }
        if byte >= 0x90 && byte <= 0x9f {
            let count = Int(byte & 0x0f)
            return .array(try readArray(data, index: &index, count: count))
        }
        if byte >= 0x80 && byte <= 0x8f {
            let count = Int(byte & 0x0f)
            return .map(try readMap(data, index: &index, count: count))
        }

        switch byte {
        case 0xc0: return .null
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)
        case 0xc4:
            let len = Int(try readUInt8(data, index: &index))
            return .binary(try readData(data, index: &index, length: len))
        case 0xc5:
            let len = Int(try readUInt16(data, index: &index))
            return .binary(try readData(data, index: &index, length: len))
        case 0xc6:
            let len = Int(try readUInt32(data, index: &index))
            return .binary(try readData(data, index: &index, length: len))
        case 0xcb:
            let bits = try readUInt64(data, index: &index)
            return .float(Double(bitPattern: bits))
        case 0xcc:
            return .uint(UInt64(try readUInt8(data, index: &index)))
        case 0xcd:
            return .uint(UInt64(try readUInt16(data, index: &index)))
        case 0xce:
            return .uint(UInt64(try readUInt32(data, index: &index)))
        case 0xcf:
            return .uint(try readUInt64(data, index: &index))
        case 0xd0:
            return .int(Int64(try readInt8(data, index: &index)))
        case 0xd1:
            return .int(Int64(try readInt16(data, index: &index)))
        case 0xd2:
            return .int(Int64(try readInt32(data, index: &index)))
        case 0xd3:
            return .int(try readInt64(data, index: &index))
        case 0xd9:
            let len = Int(try readUInt8(data, index: &index))
            return .string(try readString(data, index: &index, length: len))
        case 0xda:
            let len = Int(try readUInt16(data, index: &index))
            return .string(try readString(data, index: &index, length: len))
        case 0xdb:
            let len = Int(try readUInt32(data, index: &index))
            return .string(try readString(data, index: &index, length: len))
        case 0xdc:
            let count = Int(try readUInt16(data, index: &index))
            return .array(try readArray(data, index: &index, count: count))
        case 0xdd:
            let count = Int(try readUInt32(data, index: &index))
            return .array(try readArray(data, index: &index, count: count))
        case 0xde:
            let count = Int(try readUInt16(data, index: &index))
            return .map(try readMap(data, index: &index, count: count))
        case 0xdf:
            let count = Int(try readUInt32(data, index: &index))
            return .map(try readMap(data, index: &index, count: count))
        case 0xc7:
            let len = Int(try readUInt8(data, index: &index))
            return try readExt(data, index: &index, length: len)
        case 0xc8:
            let len = Int(try readUInt16(data, index: &index))
            return try readExt(data, index: &index, length: len)
        case 0xc9:
            let len = Int(try readUInt32(data, index: &index))
            return try readExt(data, index: &index, length: len)
        case 0xd4: return try readExt(data, index: &index, length: 1)
        case 0xd5: return try readExt(data, index: &index, length: 2)
        case 0xd6: return try readExt(data, index: &index, length: 4)
        case 0xd7: return try readExt(data, index: &index, length: 8)
        case 0xd8: return try readExt(data, index: &index, length: 16)
        default:
            throw MessagePackError.invalidData
        }
    }

    private static func readArray(_ data: Data, index: inout Data.Index, count: Int) throws -> [MessagePackValue] {
        var out: [MessagePackValue] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            out.append(try decodeValue(data, index: &index))
        }
        return out
    }

    private static func readMap(_ data: Data, index: inout Data.Index, count: Int) throws -> [String: MessagePackValue] {
        var out: [String: MessagePackValue] = [:]
        for _ in 0..<count {
            let keyVal = try decodeValue(data, index: &index)
            guard case .string(let key) = keyVal else { throw MessagePackError.invalidMapKey }
            out[key] = try decodeValue(data, index: &index)
        }
        return out
    }

    private static func readString(_ data: Data, index: inout Data.Index, length: Int) throws -> String {
        let d = try readData(data, index: &index, length: length)
        if let s = String(data: d, encoding: .utf8) {
            return s
        }
        // Tolerate malformed UTF-8 from server payloads by replacing invalid sequences.
        return String(decoding: d, as: UTF8.self)
    }

    private static func readData(_ data: Data, index: inout Data.Index, length: Int) throws -> Data {
        guard data.distance(from: index, to: data.endIndex) >= length else { throw MessagePackError.unexpectedEOF }
        let end = data.index(index, offsetBy: length)
        let d = data[index..<end]
        index = end
        return Data(d)
    }

    private static func readUInt8(_ data: Data, index: inout Data.Index) throws -> UInt8 {
        guard index < data.endIndex else { throw MessagePackError.unexpectedEOF }
        let b = data[index]
        index = data.index(after: index)
        return b
    }

    private static func readUInt16(_ data: Data, index: inout Data.Index) throws -> UInt16 {
        let d = try readData(data, index: &index, length: 2)
        return d.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    }

    private static func readUInt32(_ data: Data, index: inout Data.Index) throws -> UInt32 {
        let d = try readData(data, index: &index, length: 4)
        return d.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    private static func readUInt64(_ data: Data, index: inout Data.Index) throws -> UInt64 {
        let d = try readData(data, index: &index, length: 8)
        return d.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
    }

    private static func readInt8(_ data: Data, index: inout Data.Index) throws -> Int8 {
        Int8(bitPattern: try readUInt8(data, index: &index))
    }

    private static func readInt16(_ data: Data, index: inout Data.Index) throws -> Int16 {
        let d = try readData(data, index: &index, length: 2)
        return d.withUnsafeBytes { $0.load(as: Int16.self).bigEndian }
    }

    private static func readInt32(_ data: Data, index: inout Data.Index) throws -> Int32 {
        let d = try readData(data, index: &index, length: 4)
        return d.withUnsafeBytes { $0.load(as: Int32.self).bigEndian }
    }

    private static func readExt(_ data: Data, index: inout Data.Index, length: Int) throws -> MessagePackValue {
        let type = Int8(bitPattern: try readUInt8(data, index: &index))
        let payload = try readData(data, index: &index, length: length)

        // Timestamp extension (type = -1) per MessagePack spec.
        if type == -1 {
            let date = try decodeTimestamp(from: payload)
            if let date {
                return .string(iso8601String(from: date))
            }
        }

        return .binary(payload)
    }

    private static func decodeTimestamp(from data: Data) throws -> Date? {
        switch data.count {
        case 4:
            let seconds = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        case 8:
            let value = data.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            let nsec = value >> 34
            let seconds = value & 0x3ffffffff
            let interval = TimeInterval(seconds) + TimeInterval(nsec) / 1_000_000_000
            return Date(timeIntervalSince1970: interval)
        case 12:
            let nsec = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let seconds = data.suffix(8).withUnsafeBytes { $0.load(as: Int64.self).bigEndian }
            let interval = TimeInterval(seconds) + TimeInterval(nsec) / 1_000_000_000
            return Date(timeIntervalSince1970: interval)
        default:
            return nil
        }
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func readInt64(_ data: Data, index: inout Data.Index) throws -> Int64 {
        let d = try readData(data, index: &index, length: 8)
        return d.withUnsafeBytes { $0.load(as: Int64.self).bigEndian }
    }
}
