import LiteMDDomain
import SwiftUI

/// 批量导出一个文件夹：把里面的每个 Markdown 文件转换成同一种格式，保持原有的目录结构。
struct FolderExportRequest: Identifiable, Hashable {
    let id = UUID()
    let source: URL
    let destination: URL
    let format: ExportFormat
}

struct FolderExportReport {
    struct Failure: Identifiable {
        let id = UUID()
        let name: String
        let message: String
    }

    var exported = 0
    var failures: [Failure] = []
    var outputDirectory: URL
}

struct FolderExportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: FolderExportRequest

    private enum Phase {
        case preparing
        case exporting(completed: Int, total: Int, name: String)
        case finished(FolderExportReport)
    }

    @State private var phase: Phase = .preparing
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Export Folder")
                    .font(.system(size: TextSize.lg, weight: .semibold))
                Text("Every Markdown file in “\(request.source.lastPathComponent)” is converted, keeping the folder structure.")
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(Space.s4)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: Space.s2) {
                Spacer()
                footerButtons
            }
            .padding(Space.s4)
        }
        .frame(width: Layout.quickOpenWidth, height: Layout.progressSheetHeight)
        .task { await run() }
        .onDisappear { exportTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preparing:
            VStack(spacing: Space.s3) {
                ProgressView().progressViewStyle(.linear)
                Text("Looking for documents…")
            }
            .font(.system(size: TextSize.sm))
            .foregroundStyle(Color.textSecondary)
            .padding(Space.s8)
        case .exporting(let completed, let total, let name):
            VStack(spacing: Space.s3) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                Text("Exporting \(completed) of \(total)…")
                Text(verbatim: name)
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: TextSize.sm))
            .foregroundStyle(Color.textSecondary)
            .padding(Space.s8)
        case .finished(let report) where report.exported == 0 && report.failures.isEmpty:
            ContentUnavailableView("No Documents to Export", systemImage: "doc.text.magnifyingglass", description: Text("“\(request.source.lastPathComponent)” does not contain any Markdown files."))
        case .finished(let report):
            VStack(spacing: Space.s3) {
                Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: TextSize.xxl))
                    .foregroundStyle(report.failures.isEmpty ? Color.statusSuccess : Color.statusWarning)
                Text("\(report.exported) files exported")
                    .font(.system(size: TextSize.base, weight: .semibold))
                if let failure = report.failures.first {
                    Text("\(report.failures.count) files could not be exported.")
                        .font(.system(size: TextSize.sm))
                        .foregroundStyle(Color.statusError)
                    Text(verbatim: "\(failure.name): \(failure.message)")
                        .font(.system(size: TextSize.xs))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                }
                Text(verbatim: (report.outputDirectory.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.textTertiary)
                    .textSelection(.enabled)
            }
            .padding(Space.s8)
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch phase {
        case .preparing, .exporting:
            Button("Cancel") {
                exportTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        case .finished(let report):
            if report.exported > 0 {
                Button("Show in Finder") { SystemIntegration.revealInFinder(report.outputDirectory) }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func run() async {
        let task = Task { @MainActor in
            let report = await model.exportFolder(request) { completed, total, name in
                phase = .exporting(completed: completed, total: total, name: name)
            }
            guard !Task.isCancelled else { return }
            phase = .finished(report)
        }
        exportTask = task
        await task.value
    }
}

@MainActor
extension AppModel {
    /// 选择导出位置后开始批量导出。文件夹里没有文档时直接提示，不弹出进度面板。
    func exportFolder(_ url: URL, as format: ExportFormat) {
        guard !isPresentingSheet, let destination = SystemIntegration.chooseExportFolder(startingAt: url.deletingLastPathComponent()) else { return }
        folderExportRequest = FolderExportRequest(source: url, destination: destination, format: format)
    }

    func exportFolder(_ request: FolderExportRequest, onProgress: @MainActor (Int, Int, String) -> Void) async -> FolderExportReport {
        let files = (try? await fileSystem.markdownFiles(under: request.source, rules: workspace.rules)) ?? []
        let sorted = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let root = Self.uniqueURL(request.destination.appendingPathComponent(request.source.lastPathComponent))
        var report = FolderExportReport(outputDirectory: root)
        guard !sorted.isEmpty else { return report }

        let sourceDepth = request.source.standardizedFileURL.pathComponents.count
        for (index, file) in sorted.enumerated() {
            if Task.isCancelled { return report }
            onProgress(index, sorted.count, file.lastPathComponent)

            let components = file.standardizedFileURL.pathComponents.dropFirst(sourceDepth)
            var directory = root
            for component in components.dropLast() {
                directory.appendPathComponent(component)
            }
            let name = file.deletingPathExtension().lastPathComponent
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = Self.uniqueURL(directory.appendingPathComponent("\(name).\(request.format.fileExtension)"))
                let markdown = try await markdownForExport(of: file)
                try await conversion.export(
                    markdown: markdown,
                    title: name,
                    documentDirectory: file.deletingLastPathComponent(),
                    format: request.format,
                    to: destination
                )
                report.exported += 1
            } catch {
                let message = (error as? LiteMDError)?.localizedMessage ?? error.localizedDescription
                report.failures.append(FolderExportReport.Failure(name: file.lastPathComponent, message: message))
            }
        }
        onProgress(sorted.count, sorted.count, "")
        return report
    }

    /// 已经打开的文件用编辑器里的正文（包含未保存的修改），其余的读磁盘。
    func markdownForExport(of url: URL) async throws -> String {
        if let document = documents.documents.first(where: { $0.fileReference?.url == url }) {
            return document.text
        }
        try await fileSystem.ensureDownloaded(at: url)
        return try await fileSystem.readText(at: url).text
    }

    /// 名称已被占用时依次尝试 “name 2”、“name 3”……
    private static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        for attempt in 2...1_000 {
            let name = pathExtension.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(pathExtension)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}

#if DEBUG
/// 本地调试：设置 LITEMD_DEBUG_EXPORT_FOLDER="源目录|目标目录|格式" 后，启动时直接跑一次批量导出并打印报告。
@MainActor
enum FolderExportDebugRun {
    static func runIfRequested(model: AppModel) async {
        guard let value = ProcessInfo.processInfo.environment["LITEMD_DEBUG_EXPORT_FOLDER"] else { return }
        let parts = value.split(separator: "|").map(String.init)
        guard parts.count == 3, let format = ExportFormat(rawValue: parts[2]) else { return }
        let request = FolderExportRequest(
            source: URL(fileURLWithPath: parts[0], isDirectory: true),
            destination: URL(fileURLWithPath: parts[1], isDirectory: true),
            format: format
        )
        let report = await model.exportFolder(request) { completed, total, name in
            print("[export] \(completed)/\(total) \(name)")
        }
        print("[export] exported=\(report.exported) failures=\(report.failures.map(\.name)) output=\(report.outputDirectory.path)")
    }
}
#endif
