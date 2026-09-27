private let hexDigits = Array("0123456789abcdef")

extension Sequence where Element == UInt8 {
    /// 小写十六进制字符串，用于哈希摘要、ETag 比较与文件名。
    public var hexString: String {
        var characters: [Character] = []
        characters.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(characters)
    }
}
