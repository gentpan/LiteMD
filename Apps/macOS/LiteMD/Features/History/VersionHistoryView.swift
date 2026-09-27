import LiteMDApplication
import LiteMDDomain
import SwiftUI

/// 历史版本：列出 LiteMD 覆盖文件前保存的副本，与当前内容对比后恢复或另存。
struct VersionHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorTheme) private var colorTheme
    let document: Document

    @State private var snapshots: [VersionSnapshot] = []
    @State private var selection: VersionSnapshot?
    @State private var selectedText: String?
    @State private var lines: [CompareView.DiffLine] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s4) {
                Text("Version History of “\(document.displayName)”")
                    .font(.system(size: TextSize.lg, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Label("This Version", systemImage: "minus")
                    .foregroundStyle(Color.statusError)
                Label("Current", systemImage: "plus")
                    .foregroundStyle(Color.statusSuccess)
            }
            .font(.system(size: TextSize.sm))
            .padding(Space.s4)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshots.isEmpty {
                ContentUnavailableView {
                    Label("No Earlier Versions", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("LiteMD keeps a copy of a file before overwriting it, at most once every 10 minutes. Versions appear here after you edit and save this document. iCloud conflict versions from your other devices also appear here.")
                }
                .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(snapshots, selection: $selection) { snapshot in
                        VStack(alignment: .leading, spacing: Space.s1) {
                            HStack(spacing: Space.s1) {
                                if snapshot.origin == .cloudConflict {
                                    Image(systemName: "icloud.slash")
                                        .font(.system(size: TextSize.xs))
                                        .foregroundStyle(Color.statusWarning)
                                }
                                Text(snapshot.date, format: .dateTime.month().day().hour().minute())
                                    .font(.system(size: TextSize.sm, weight: .semibold))
                                    .foregroundStyle(Color.textPrimary)
                            }
                            HStack(spacing: Space.s2) {
                                if snapshot.origin == .cloudConflict {
                                    Text(snapshot.deviceName.map { String(localized: "iCloud conflict from \($0)") } ?? String(localized: "iCloud conflict"))
                                } else {
                                    Text(snapshot.date, format: .relative(presentation: .named))
                                }
                                Text(ByteCountFormatter.string(fromByteCount: snapshot.byteCount, countStyle: .file))
                            }
                            .font(.system(size: TextSize.xs))
                            .foregroundStyle(Color.textSecondary)
                        }
                        .padding(.vertical, Space.s1)
                        .tag(snapshot)
                    }
                    .listStyle(.sidebar)
                    .frame(width: Layout.historyListWidth)

                    Divider()

                    diffView
                }
            }

            Divider()

            HStack(spacing: Space.s2) {
                Button("Show in Finder") {
                    if let selection { SystemIntegration.revealInFinder(selection.fileURL) }
                }
                .disabled(selection == nil)
                if let loadError {
                    Text(verbatim: loadError)
                        .font(.system(size: TextSize.xs))
                        .foregroundStyle(Color.statusError)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open as New Document") {
                    guard let selectedText else { return }
                    model.newDocument(text: selectedText)
                    dismiss()
                }
                .disabled(selectedText == nil)
                Button(selection?.origin == .cloudConflict ? "Keep This Version" : "Restore This Version") {
                    guard let selectedText else { return }
                    model.restoreVersion(selectedText, of: document, resolvesCloudConflicts: selection?.origin == .cloudConflict)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedText == nil || selectedText == document.text)
            }
            .padding(Space.s4)
        }
        .frame(width: Layout.compareWidth, height: Layout.compareHeight)
        .task {
            snapshots = await model.documents.versionSnapshots(for: document)
            selection = snapshots.first
            isLoading = false
        }
        .onChange(of: selection) { _, snapshot in
            Task { await load(snapshot) }
        }
    }

    private var diffView: some View {
        DiffLinesView(lines: lines) {
            if selectedText != nil, lines.allSatisfy({ $0.kind == .same }) {
                Text("This version is identical to the current document.")
                    .font(.system(size: TextSize.sm))
                    .foregroundStyle(Color.textSecondary)
                    .padding(Space.s4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load(_ snapshot: VersionSnapshot?) async {
        guard let snapshot else {
            selectedText = nil
            lines = []
            return
        }
        do {
            let text = try await model.documents.text(of: snapshot)
            guard selection == snapshot else { return }
            loadError = nil
            selectedText = text
            let current = document.text
            lines = await Task.detached { CompareView.diff(old: text, new: current) }.value
        } catch {
            selectedText = nil
            lines = []
            loadError = error.localizedMessage
        }
    }
}

@MainActor
extension AppModel {
    func showVersionHistory() {
        guard let document = activeDocument else { return }
        guard document.fileReference != nil else {
            SystemIntegration.runAlert(
                title: String(localized: "This document has not been saved yet."),
                message: String(localized: "Save the document first. LiteMD keeps earlier versions of saved files."),
                buttons: [String(localized: "OK")],
                style: .informational
            )
            return
        }
        guard !isPresentingSheet else { return }
        versionHistoryDocument = document
    }

    /// 恢复旧版本：先把磁盘上的当前版本存入历史，再作为一次可撤销的编辑替换正文。
    /// 选择的是 iCloud 冲突版本时，同时把其余冲突版本标记为已解决。
    func restoreVersion(_ text: String, of document: Document, resolvesCloudConflicts: Bool = false) {
        Task {
            await documents.storeSnapshotOfDiskVersion(document)
            editor(for: document).replaceEntireText(with: text, actionName: String(localized: "Restore Version"))
            if resolvesCloudConflicts {
                await save(document)
                await documents.resolveCloudConflicts(for: document)
            }
        }
    }
}
