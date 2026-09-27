import Foundation
import LiteMDDomain
import LiteMDEditor
import Observation

/// 编辑器视图实现此协议，使 Reload 等整体替换走视图的编辑通道（可撤销、选区合理）。
@MainActor
public protocol DocumentTextEditing: AnyObject {
    func replaceEntireText(with text: String)
}

/// 当前运行中的 Markdown 编辑会话（spec §83）。它不是磁盘文件本身。
@MainActor
@Observable
public final class Document: Identifiable {
    public let id: DocumentID
    public private(set) var fileReference: FileReference?

    @ObservationIgnored
    public let buffer: StringTextBuffer

    /// 与 `buffer.revision` 同步，供界面观察。
    public private(set) var revision: Int
    public internal(set) var savedRevision: Int
    public internal(set) var knownDiskRevision: DiskRevision?

    public internal(set) var lifecycle: DocumentLifecycle = .ready
    public internal(set) var saveActivity: SaveActivity = .idle
    public internal(set) var conflict: ConflictState = .none
    public internal(set) var parseResult: ParseResult?
    public internal(set) var isComposing = false

    /// 未命名文档的序号（Untitled、Untitled 2…）。
    public let untitledNumber: Int?

    @ObservationIgnored
    public weak var textEditor: (any DocumentTextEditing)?

    @ObservationIgnored
    var recoveryRevision: Int?

    init(id: DocumentID = DocumentID(), fileReference: FileReference?, text: String, untitledNumber: Int? = nil) {
        self.id = id
        self.fileReference = fileReference
        self.buffer = StringTextBuffer(text)
        self.revision = buffer.revision
        self.savedRevision = buffer.revision
        self.untitledNumber = untitledNumber
    }

    /// `isDirty = revision != savedRevision`，不单独维护布尔值（spec §90）。
    public var isDirty: Bool { revision != savedRevision }
    public var isUntitled: Bool { fileReference == nil }

    /// 未命名文档的显示名称，由界面层提供本地化版本。
    public static var untitledTitle: (Int) -> String = { number in
        number > 1 ? "Untitled \(number)" : "Untitled"
    }

    public var displayName: String {
        if let fileReference { return fileReference.displayName }
        return Self.untitledTitle(untitledNumber ?? 1)
    }

    public var saveState: SaveState {
        switch saveActivity {
        case .saving: .saving
        case .failed(let error): .failed(error)
        case .scheduled: isDirty ? .scheduled : .clean
        case .idle: isDirty ? .dirty : .clean
        }
    }

    public var text: String { buffer.snapshot() }

    /// 编辑器同步入口：视图中的每一次文本变化都经由此处进入 TextBuffer（spec §89）。
    public func applyEdit(range: NSRange, replacement: String) {
        buffer.replaceCharacters(in: range, with: replacement)
        revision = buffer.revision
    }

    func replaceAllText(_ text: String) {
        buffer.replaceAll(with: text)
        revision = buffer.revision
    }

    func setFileReference(_ reference: FileReference?) {
        fileReference = reference
    }
}
