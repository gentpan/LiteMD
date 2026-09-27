import Foundation

public enum DocumentLifecycle: Equatable, Sendable {
    case ready
    case closed
}

/// 保存流程的进行状态。Dirty 与否由 revision 推导，不在这里维护。
public enum SaveActivity: Equatable, Sendable {
    case idle
    case scheduled
    case saving
    case failed(LiteMDError)
}

/// 对外展示的保存状态（spec §92），由 revision 与 SaveActivity 推导。
public enum SaveState: Equatable, Sendable {
    case clean
    case dirty
    case scheduled
    case saving
    case failed(LiteMDError)
}

public enum ConflictState: Equatable, Sendable {
    case none
    /// 磁盘内容已被外部修改，同时本地还有未保存修改。
    case externalModified
    /// 文件已被外部删除。
    case externalDeleted

    public var isConflict: Bool { self != .none }
}

public enum EditorMode: String, Codable, Sendable, CaseIterable {
    case source
    case split
    /// P1：Live Preview，MVP 不开放。
    case live
}

/// anchor == head 时表示光标。偏移量单位是 UTF-16 code unit（与 NSString / NSTextView 一致）。
public struct Selection: Equatable, Hashable, Codable, Sendable {
    public var anchor: Int
    public var head: Int

    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    public init(cursor: Int) {
        self.init(anchor: cursor, head: cursor)
    }

    public init(range: NSRange) {
        self.init(anchor: range.location, head: range.location + range.length)
    }

    public var lowerBound: Int { min(anchor, head) }
    public var upperBound: Int { max(anchor, head) }
    public var range: NSRange { NSRange(location: lowerBound, length: upperBound - lowerBound) }
}
