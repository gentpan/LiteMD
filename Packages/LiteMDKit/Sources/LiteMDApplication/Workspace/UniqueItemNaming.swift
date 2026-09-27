import Foundation
import LiteMDDomain

/// 新建文件（夹）时的命名规则：目标已存在时依次尝试带序号的名称，绝不覆盖。
struct UniqueItemNaming {
    /// 基础名称与序号之间的分隔符。
    var separator: String
    var maximumAttempts: Int
    /// 找不到可用名称时报告的错误类别。
    var errorKind: LiteMDError.Kind

    /// 文件树：`Untitled 2`、`Untitled 3`…
    static let workspace = UniqueItemNaming(separator: " ", maximumAttempts: 1_000, errorKind: .workspace)
    /// 图片资源：`image-2`、`image-3`…，无空格（spec §132）。
    static let asset = UniqueItemNaming(separator: "-", maximumAttempts: 10_000, errorKind: .asset)

    /// 生成不冲突的名称并执行创建。创建操作本身必须在目标已存在时失败（O_EXCL 语义）。
    /// 在调用方的 actor 上执行，创建闭包不必跨越隔离边界。
    /// - Parameter pathExtension: 为空表示没有扩展名。
    nonisolated(nonsending) func create(
        in directory: URL,
        baseName: String,
        extension pathExtension: String,
        _ create: (URL) async throws(LiteMDError) -> Void
    ) async throws(LiteMDError) -> URL {
        for attempt in 1...maximumAttempts {
            let name = attempt == 1 ? baseName : "\(baseName)\(separator)\(attempt)"
            let url = directory.appendingPathComponent(pathExtension.isEmpty ? name : "\(name).\(pathExtension)")
            do throws(LiteMDError) {
                try await create(url)
                return url.standardizedFileURL
            } catch where error.reason == .alreadyExists {
                continue
            }
        }
        throw LiteMDError(kind: errorKind, reason: .alreadyExists, fileName: baseName)
    }
}
