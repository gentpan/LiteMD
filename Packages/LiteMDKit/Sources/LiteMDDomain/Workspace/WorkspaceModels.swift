import Foundation

public struct WorkspaceEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case file
        case directory
    }

    public var url: URL
    public var kind: Kind
    public var cloudStatus: CloudStatus

    public init(url: URL, kind: Kind, cloudStatus: CloudStatus = .local) {
        self.url = url
        self.kind = kind
        self.cloudStatus = cloudStatus
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    public var isDirectory: Bool { kind == .directory }
}

/// Workspace 默认忽略规则（spec §120）。
public struct WorkspaceIgnoreRules: Sendable, Equatable {
    public var ignoredNames: Set<String>
    public var showHiddenFiles: Bool

    public init(
        ignoredNames: Set<String> = ["node_modules", ".DS_Store", "Thumbs.db", ".git"],
        showHiddenFiles: Bool = false
    ) {
        self.ignoredNames = ignoredNames
        self.showHiddenFiles = showHiddenFiles
    }

    public func isIgnored(name: String) -> Bool {
        if ignoredNames.contains(name) { return true }
        if !showHiddenFiles, name.hasPrefix(".") { return true }
        return false
    }
}

public enum MarkdownFileType {
    public static let documentExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "bmp", "tiff", "tif", "avif"]

    public static func isDocument(_ url: URL) -> Bool {
        documentExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }
}

/// 文件系统变化事件。File Watcher 只产生事件，不直接修改 Document（spec §121）。
public struct FileEvent: Hashable, Sendable {
    public struct Flags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let created = Flags(rawValue: 1 << 0)
        public static let modified = Flags(rawValue: 1 << 1)
        public static let renamed = Flags(rawValue: 1 << 2)
        public static let removed = Flags(rawValue: 1 << 3)
        public static let isDirectory = Flags(rawValue: 1 << 4)
        /// 事件被合并，需要重新扫描该目录。
        public static let mustRescan = Flags(rawValue: 1 << 5)
    }

    public var url: URL
    public var flags: Flags
    /// 平台提供的 inode（同一卷内唯一），用于把重命名事件的新旧路径配对。
    public var inode: UInt64?

    public init(url: URL, flags: Flags, inode: UInt64? = nil) {
        self.url = url
        self.flags = flags
        self.inode = inode
    }
}
