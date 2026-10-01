#if DEBUG
import AppKit
import LiteMDBackup
import LiteMDDomain

/// 本地调试：设置 LITEMD_DEBUG_S3_RUN="对象键|报告文件" 后，启动时用当前的 S3 设置跑一遍不需要弹窗的流程：
/// 列出文档 → 下载打开 → 编辑保存 → 上传 → 模拟别处修改 → 重新列出 → 再次打开（更新本地）→ 取消关联，
/// 每一步的状态写进报告文件（屏幕锁定时也能核对）。
@MainActor
enum RemoteDocumentsDebugRun {
    static func runIfRequested(model: AppModel) async {
        guard let value = ProcessInfo.processInfo.environment["LITEMD_DEBUG_S3_RUN"] else { return }
        let parts = value.split(separator: "|").map(String.init)
        guard parts.count == 2 else { return }
        let key = parts[0]
        var lines: [String] = []
        func log(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(toFile: parts[1], atomically: true, encoding: .utf8)
        }
        let remote = model.remoteDocuments

        await remote.refresh()
        log("refresh: \(remote.phase) keys=\(remote.documents.map(\.key))")
        guard let document = remote.documents.first(where: { $0.key == key }) else { return log("missing \(key)") }

        await remote.open(document)
        let local = RemoteDocumentsModel.downloadsRoot(bucket: remote.configuration.bucket).appendingPathComponent(key).standardizedFileURL
        log("open: exists=\(FileManager.default.fileExists(atPath: local.path)) linked=\(remote.link(for: local) != nil) active=\(model.activeDocument?.fileReference?.url.path ?? "-") state=\(String(describing: remote.states[key]))")

        guard let opened = model.activeDocument, opened.fileReference?.url.standardizedFileURL == local else { return log("not opened") }
        let editor = model.editor(for: opened)
        editor.textView.setSelectedRange(NSRange(location: (editor.textView.string as NSString).length, length: 0))
        editor.textView.insertText("\n本地新增的一行\n", replacementRange: editor.textView.selectedRange())
        try? await model.documents.save(opened)
        log("edit: pending=\(remote.hasPendingUpload(local)) dirty=\(opened.isDirty)")

        await remote.upload(opened)
        let store = RemoteDocumentStore(client: S3Client(configuration: remote.configuration, secretAccessKey: await model.backup.loadSecret()))
        let uploaded = (try? await store.download(key).data).flatMap { String(data: $0, encoding: .utf8) } ?? "-"
        log("upload: pending=\(remote.hasPendingUpload(local)) remoteHasLine=\(uploaded.contains("本地新增的一行"))")

        let other = uploaded + "别处修改的一行\n"
        _ = try? await store.upload(Data(other.utf8), to: key)
        await remote.refresh()
        log("remote edit: state=\(String(describing: remote.states[key]))")

        if let updated = remote.documents.first(where: { $0.key == key }) {
            await remote.open(updated)
        }
        try? await Task.sleep(for: .seconds(2))
        let disk = (try? String(contentsOf: local, encoding: .utf8)) ?? "-"
        log("reopen: diskHasRemoteLine=\(disk.contains("别处修改的一行")) editorHasRemoteLine=\(opened.text.contains("别处修改的一行")) state=\(String(describing: remote.states[key])) pending=\(remote.hasPendingUpload(local))")

        remote.unlink(local)
        log("unlink: linked=\(remote.link(for: local) != nil) state=\(String(describing: remote.states[key]))")
        log("done")
    }
}
#endif
