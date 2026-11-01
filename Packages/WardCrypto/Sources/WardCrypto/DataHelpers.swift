import Foundation

extension Data {
    init?(hex: String) {
        let cleaned = hex.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var output = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        self = output
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
    var base64: String { base64EncodedString() }
}

func xor(_ lhs: Data, _ rhs: Data) -> Data {
    Data(zip(lhs, rhs).map { $0 ^ $1 })
}

func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var diff: UInt8 = 0
    for (left, right) in zip(lhs, rhs) { diff |= left ^ right }
    return diff == 0
}
