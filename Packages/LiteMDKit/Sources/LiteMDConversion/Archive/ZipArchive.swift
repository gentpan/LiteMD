import Compression
import Foundation
import Synchronization

/// 最小 ZIP 读写实现，供 DOCX / PPTX / XLSX / EPUB 使用。
///
/// - 支持存储（method 0）与 DEFLATE（method 8）；
/// - 不支持 ZIP64、加密与分卷；
/// - 条目名只作为查找键，绝不直接拼接成磁盘路径（防止 zip-slip）；
/// - 单个条目解压上限 256 MB，整个压缩包累计 512 MB，防止压缩炸弹。
public struct ZipArchive: Sendable {
    public struct Entry: Sendable {
        public var path: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    public static let maximumEntrySize = 256 * 1024 * 1024
    /// 导入时提取的图片都留在内存里，只限制单个条目挡不住成百上千个大条目。
    public static let maximumTotalSize = 512 * 1024 * 1024

    private let data: Data
    /// 副本之间共享，同一个压缩包无论从哪里读取都算在一起。
    private let budget: DecompressionBudget
    public private(set) var entries: [String: Entry] = [:]
    public private(set) var orderedPaths: [String] = []

    public init(data: Data) throws(ConversionError) {
        try self.init(data: data, maximumTotalSize: Self.maximumTotalSize)
    }

    init(data: Data, maximumTotalSize: Int) throws(ConversionError) {
        self.data = data
        self.budget = DecompressionBudget(limit: maximumTotalSize)
        try readCentralDirectory()
    }

    public func contains(_ path: String) -> Bool {
        entries[Self.normalize(path)] != nil
    }

    public func data(for path: String) throws(ConversionError) -> Data {
        guard let entry = entries[Self.normalize(path)] else {
            throw ConversionError.missingPart(path)
        }
        guard entry.uncompressedSize <= Self.maximumEntrySize else {
            throw ConversionError.corrupted("ZIP entry too large: \(path)")
        }

        let offset = entry.localHeaderOffset
        guard try readUInt32(offset) == 0x0403_4B50 else {
            throw ConversionError.corrupted("Invalid local header for \(path)")
        }
        let nameLength = Int(try readUInt16(offset + 26))
        let extraLength = Int(try readUInt16(offset + 28))
        let start = offset + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else {
            throw ConversionError.corrupted("Truncated entry \(path)")
        }
        let size: Int
        switch entry.method {
        case 0: size = entry.compressedSize
        case 8: size = entry.uncompressedSize
        default: throw ConversionError.unsupported("ZIP compression method \(entry.method)")
        }
        guard budget.consume(size) else {
            throw ConversionError.corrupted("ZIP archive expands beyond \(Self.maximumTotalSize / 1024 / 1024) MB")
        }

        let compressed = data.subdata(in: start..<(start + entry.compressedSize))
        guard entry.method == 8 else { return compressed }
        do {
            return try Self.inflate(compressed, expectedSize: entry.uncompressedSize)
        } catch {
            budget.refund(size)
            throw error
        }
    }

    /// 去掉开头的 `/` 与 `./`，并解析 `..`。
    static func normalize(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".", "": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return components.joined(separator: "/")
    }

    /// 相对于某个条目所在目录解析路径（用于 rels 中的 Target）。
    public static func resolve(_ target: String, relativeTo base: String) -> String {
        if target.hasPrefix("/") { return normalize(target) }
        let directory = (base as NSString).deletingLastPathComponent
        return normalize(directory.isEmpty ? target : directory + "/" + target)
    }

    private mutating func readCentralDirectory() throws(ConversionError) {
        guard data.count >= 22 else { throw ConversionError.corrupted("Not a ZIP archive") }

        var eocd = -1
        let lowerBound = max(0, data.count - 22 - 65_535)
        var index = data.count - 22
        while index >= lowerBound {
            if try readUInt32(index) == 0x0605_4B50 {
                eocd = index
                break
            }
            index -= 1
        }
        guard eocd >= 0 else { throw ConversionError.corrupted("Not a ZIP archive") }

        let count = Int(try readUInt16(eocd + 10))
        var offset = Int(try readUInt32(eocd + 16))

        for _ in 0..<count {
            guard try readUInt32(offset) == 0x0201_4B50 else {
                throw ConversionError.corrupted("Invalid central directory")
            }
            let method = try readUInt16(offset + 10)
            let compressedSize = Int(try readUInt32(offset + 20))
            let uncompressedSize = Int(try readUInt32(offset + 24))
            let nameLength = Int(try readUInt16(offset + 28))
            let extraLength = Int(try readUInt16(offset + 30))
            let commentLength = Int(try readUInt16(offset + 32))
            let localOffset = Int(try readUInt32(offset + 42))
            guard offset + 46 + nameLength <= data.count else {
                throw ConversionError.corrupted("Invalid central directory")
            }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            let path = Self.normalize(String(decoding: nameData, as: UTF8.self))

            if !path.isEmpty {
                entries[path] = Entry(
                    path: path,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localOffset
                )
                orderedPaths.append(path)
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    private func readUInt16(_ offset: Int) throws(ConversionError) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw ConversionError.corrupted("Unexpected end of archive") }
        return UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private func readUInt32(_ offset: Int) throws(ConversionError) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw ConversionError.corrupted("Unexpected end of archive") }
        var value: UInt32 = 0
        for byte in 0..<4 {
            value |= UInt32(data[data.startIndex + offset + byte]) << (8 * UInt32(byte))
        }
        return value
    }

    /// 按块解压、边解边检查。声明的大小可以是假的，不按它预先分配内存；解出的数据超过声明大小就停止。
    static func inflate(_ compressed: Data, expectedSize: Int) throws(ConversionError) -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data()
        do {
            let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
                guard let chunk else { return }
                guard output.count + chunk.count <= expectedSize else { throw ConversionError.corrupted("ZIP entry larger than declared") }
                output.append(chunk)
            }
            try filter.write(compressed)
            try filter.finalize()
        } catch {
            throw ConversionError.corrupted("Could not decompress ZIP entry")
        }
        guard output.count == expectedSize else {
            throw ConversionError.corrupted("Could not decompress ZIP entry")
        }
        return output
    }
}

/// 一个压缩包累计可以解压的字节数。
private final class DecompressionBudget: Sendable {
    private let remaining: Mutex<Int>

    init(limit: Int) {
        remaining = Mutex(limit)
    }

    func consume(_ bytes: Int) -> Bool {
        remaining.withLock { remaining in
            guard bytes <= remaining else { return false }
            remaining -= bytes
            return true
        }
    }

    func refund(_ bytes: Int) {
        remaining.withLock { $0 += bytes }
    }
}

/// ZIP 写入。条目按添加顺序写出（EPUB 要求 `mimetype` 为第一个且不压缩）。
public struct ZipWriter {
    private struct Record {
        var path: Data
        var method: UInt16
        var crc: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var offset: Int
    }

    private var output = Data()
    private var records: [Record] = []

    public init() {}

    public mutating func add(_ path: String, data: Data, compress: Bool = true) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var payload = data
        if compress, data.count > 64, let deflated = Self.deflate(data), deflated.count < data.count {
            method = 8
            payload = deflated
        }

        let record = Record(path: name, method: method, crc: crc, compressedSize: payload.count, uncompressedSize: data.count, offset: output.count)
        output.appendUInt32(0x0403_4B50)
        output.appendUInt16(20) // version needed
        output.appendUInt16(0x0800) // UTF-8 file names
        output.appendUInt16(method)
        output.appendUInt16(0) // time
        output.appendUInt16(0x21) // date: 1980-01-01
        output.appendUInt32(crc)
        output.appendUInt32(UInt32(payload.count))
        output.appendUInt32(UInt32(data.count))
        output.appendUInt16(UInt16(name.count))
        output.appendUInt16(0)
        output.append(name)
        output.append(payload)
        records.append(record)
    }

    public mutating func add(_ path: String, string: String, compress: Bool = true) {
        add(path, data: Data(string.utf8), compress: compress)
    }

    public mutating func finish() -> Data {
        let directoryOffset = output.count
        for record in records {
            output.appendUInt32(0x0201_4B50)
            output.appendUInt16(20) // made by
            output.appendUInt16(20) // needed
            output.appendUInt16(0x0800)
            output.appendUInt16(record.method)
            output.appendUInt16(0)
            output.appendUInt16(0x21)
            output.appendUInt32(record.crc)
            output.appendUInt32(UInt32(record.compressedSize))
            output.appendUInt32(UInt32(record.uncompressedSize))
            output.appendUInt16(UInt16(record.path.count))
            output.appendUInt16(0) // extra
            output.appendUInt16(0) // comment
            output.appendUInt16(0) // disk
            output.appendUInt16(0) // internal attributes
            output.appendUInt32(0) // external attributes
            output.appendUInt32(UInt32(record.offset))
            output.append(record.path)
        }
        let directorySize = output.count - directoryOffset
        output.appendUInt32(0x0605_4B50)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(UInt16(records.count))
        output.appendUInt16(UInt16(records.count))
        output.appendUInt32(UInt32(directorySize))
        output.appendUInt32(UInt32(directoryOffset))
        output.appendUInt16(0)
        return output
    }

    static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}
