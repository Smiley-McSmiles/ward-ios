import Foundation

/// Minimal protobuf encoder/decoder. OMEMO only needs varints and length-delimited bytes; keeping
/// this local avoids a second generated-code dependency and makes the wire format auditable.
struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ field: Int, _ value: UInt64, always: Bool = false) {
        guard value != 0 || always else { return }
        data.append(contentsOf: [UInt8((field << 3) | 0)])
        appendVarint(value)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        guard !value.isEmpty else { return }
        data.append(contentsOf: [UInt8((field << 3) | 2)])
        appendVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func message(_ field: Int, _ value: Data) {
        bytes(field, value)
    }

    private mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }
}

struct ProtoField {
    let number: Int
    let wire: Int
    let varint: UInt64?
    let bytes: Data?
}

struct ProtoReader {
    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    mutating func next() -> ProtoField? {
        guard index < data.endIndex else { return nil }
        guard let key = readVarint() else { return nil }
        let number = Int(key >> 3)
        let wire = Int(key & 7)
        switch wire {
        case 0:
            guard let value = readVarint() else { return nil }
            return ProtoField(number: number, wire: wire, varint: value, bytes: nil)
        case 1:
            guard index + 8 <= data.endIndex else { return nil }
            index += 8
            return ProtoField(number: number, wire: wire, varint: nil, bytes: nil)
        case 2:
            guard let length = readVarint() else { return nil }
            let end = index + Int(length)
            guard end <= data.endIndex else { return nil }
            let value = data[index..<end]
            index = end
            return ProtoField(number: number, wire: wire, varint: nil, bytes: Data(value))
        case 5:
            guard index + 4 <= data.endIndex else { return nil }
            index += 4
            return ProtoField(number: number, wire: wire, varint: nil, bytes: nil)
        default:
            return nil
        }
    }

    private mutating func readVarint() -> UInt64? {
        var shift: UInt64 = 0
        var result: UInt64 = 0
        while index < data.endIndex && shift < 64 {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}
