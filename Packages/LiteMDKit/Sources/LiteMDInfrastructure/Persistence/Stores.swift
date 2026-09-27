import CryptoKit
import Foundation
import LiteMDDomain

/// 应用内部数据目录。优先使用 Application Support，而不是在用户 Workspace 中创建 `.litemd/`（spec §78）。
public enum AppDirectories {
    public static func applicationSupport(appName: String = "LiteMD") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appName, isDirectory: true)
    }
}

/// Crash Recovery 存储（spec §133）：
///
/// ```
/// Recovery/
/// ├── manifest.json
/// └── documents/
///     └── <DocumentID>.md
/// ```
public actor FileRecoveryStore: RecoveryStoring {
    private let directory: URL
    private var manifest: [DocumentID: RecoveryEntry]?

    public init(directory: URL) {
        self.directory = directory
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var documentsURL: URL { directory.appendingPathComponent("documents", isDirectory: true) }

    private func contentURL(_ id: DocumentID) -> URL {
        documentsURL.appendingPathComponent("\(id.rawValue.uuidString).md")
    }

    private func loadManifest() -> [DocumentID: RecoveryEntry] {
        if let manifest { return manifest }
        var loaded: [DocumentID: RecoveryEntry] = [:]
        if let data = try? Data(contentsOf: manifestURL),
           let entries = try? JSONDecoder().decode([RecoveryEntry].self, from: data) {
            for entry in entries where FileManager.default.fileExists(atPath: contentURL(entry.documentID).path) {
                loaded[entry.documentID] = entry
            }
        }
        manifest = loaded
        return loaded
    }

    private func persistManifest(_ entries: [DocumentID: RecoveryEntry]) throws {
        manifest = entries
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Array(entries.values).sorted { $0.timestamp < $1.timestamp })
        try data.write(to: manifestURL, options: .atomic)
    }

    public func entries() -> [RecoveryEntry] {
        loadManifest().values.sorted { $0.timestamp < $1.timestamp }
    }

    public func content(for id: DocumentID) throws(LiteMDError) -> String {
        do {
            let data = try Data(contentsOf: contentURL(id))
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw FileErrorMapper.map(error, fileName: nil, kind: .recovery)
        }
    }

    public func store(_ entry: RecoveryEntry, content: String) throws(LiteMDError) {
        do {
            try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: contentURL(entry.documentID), options: .atomic)
            var entries = loadManifest()
            entries[entry.documentID] = entry
            try persistManifest(entries)
        } catch {
            throw FileErrorMapper.map(error, fileName: entry.displayName, kind: .recovery)
        }
    }

    public func remove(_ id: DocumentID) {
        var entries = loadManifest()
        guard entries.removeValue(forKey: id) != nil || FileManager.default.fileExists(atPath: contentURL(id).path) else { return }
        try? FileManager.default.removeItem(at: contentURL(id))
        try? persistManifest(entries)
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: documentsURL)
        try? persistManifest([:])
    }
}

/// 覆盖前备份存储：
///
/// ```
/// History/
/// └── <路径哈希>/
///     ├── path.txt              原文件路径
///     └── 20260917-203015.md    覆盖前的内容
/// ```
/// 每个文件保留最近 `limit` 份；与最近一份内容相同时不重复保存。
public actor FileVersionHistoryStore: VersionHistoryStoring {
    private let directory: URL
    private let limit: Int

    public init(directory: URL, limit: Int = 50) {
        self.directory = directory
        self.limit = limit
    }

    private func folder(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(12).hexString
        return directory.appendingPathComponent(digest, isDirectory: true)
    }

    private static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }

    public func storeSnapshot(of url: URL, data: Data, date: Date) {
        let folder = folder(for: url)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(url.standardizedFileURL.path.utf8).write(to: folder.appendingPathComponent("path.txt"), options: .atomic)

            if let latest = snapshots(for: url).first,
               latest.byteCount == Int64(data.count),
               (try? Data(contentsOf: latest.fileURL)) == data {
                return
            }

            let name = Self.makeFormatter().string(from: date) + "." + (url.pathExtension.isEmpty ? "md" : url.pathExtension)
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)

            let versions = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent != "path.txt" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in versions.dropLast(limit) {
                try? FileManager.default.removeItem(at: old)
            }
        } catch {
            // 备份失败不阻止保存，但不会静默丢失原文件：保存本身仍是原子写入。
        }
    }

    public func snapshots(for url: URL) -> [VersionSnapshot] {
        let folder = folder(for: url)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        let formatter = Self.makeFormatter()
        return files
            .filter { $0.lastPathComponent != "path.txt" }
            .map { file in
                let values = try? file.resourceValues(forKeys: Set(keys))
                // 文件名记录保存时间；无法解析时退回修改时间。
                let stamp = String(file.deletingPathExtension().lastPathComponent)
                let date = formatter.date(from: stamp) ?? values?.contentModificationDate ?? .distantPast
                return VersionSnapshot(originalURL: url, fileURL: file, date: date, byteCount: Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
    }
}

/// 以 JSON 文件保存应用状态（Recent、Session 等），不保存 Markdown 正文。
public actor JSONStateStore: StateStoring {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func fileURL(_ key: String) -> URL {
        let safeKey = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        return directory.appendingPathComponent(String(safeKey) + ".json")
    }

    public func load<Value: Codable & Sendable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = try? Data(contentsOf: fileURL(key)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func save<Value: Codable & Sendable>(_ value: Value, key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: fileURL(key), options: .atomic)
        } catch {
            // 状态文件写入失败不影响文档数据，忽略。
        }
    }
}
