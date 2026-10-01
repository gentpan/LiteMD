import SwiftUI

/// 侧栏底部的备份状态按钮，点击弹出状态与操作。
struct BackupStatusButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        let backup = model.backup

        Button {
            isPresented.toggle()
        } label: {
            icon(for: backup)
                .font(.system(size: IconSize.inline, weight: .regular))
                .frame(width: Space.s6 + Space.s1, height: Space.s6 + Space.s1)
                .background(
                    RoundedRectangle(cornerRadius: Radius.small)
                        .fill(isHovering ? Color.borderSubtle : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering = $0 }
        .help("S3 Backup")
        .accessibilityLabel("S3 Backup")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            BackupPopover(openSettings: {
                isPresented = false
                model.settingsTab = .backup
                openSettings()
            }, openRestore: {
                isPresented = false
                model.isRestorePresented = true
            }, openDocuments: {
                isPresented = false
                model.isRemoteDocumentsPresented = true
            })
            .environment(model)
        }
    }

    @ViewBuilder
    private func icon(for backup: BackupModel) -> some View {
        switch backup.phase {
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, options: .repeat(.continuous))
                .foregroundStyle(Color.brand)
        case .failed:
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(Color.statusWarning)
        case .idle:
            if !backup.isConfigured {
                Image(systemName: "icloud")
                    .foregroundStyle(isHovering ? Color.textPrimary : Color.textSecondary)
            } else if backup.lastReport(for: model.workspace.rootURL) != nil {
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(isHovering ? Color.textPrimary : Color.textSecondary)
            } else {
                Image(systemName: "icloud.and.arrow.up")
                    .foregroundStyle(isHovering ? Color.textPrimary : Color.textSecondary)
            }
        }
    }
}

private struct BackupPopover: View {
    @Environment(AppModel.self) private var model
    let openSettings: () -> Void
    let openRestore: () -> Void
    let openDocuments: () -> Void

    var body: some View {
        let backup = model.backup

        VStack(alignment: .leading, spacing: Space.s3) {
            Text("S3 Backup")
                .font(.system(size: TextSize.sm, weight: .semibold))
                .foregroundStyle(Color.textPrimary)

            if backup.isConfigured {
                BackupStatusDetails()
                Button("Browse Documents in S3…", action: openDocuments)
                    .buttonStyle(.link)
                    .font(.system(size: TextSize.xs))
            } else {
                Text("Back up this folder to Amazon S3, Cloudflare R2, MinIO or another S3-compatible bucket.")
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.s2) {
                Button(backup.isConfigured ? "Settings…" : "Set Up…", action: openSettings)
                if backup.isConfigured {
                    Button("Restore…", action: openRestore)
                }
                Spacer()
                if backup.isRunning {
                    Button("Stop") { backup.cancel() }
                } else if backup.isConfigured {
                    Button("Back Up Now") { backup.backUpNow() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.workspace.rootURL == nil)
                }
            }
            .controlSize(.small)
        }
        .padding(Space.s4)
        .frame(width: Layout.backupPopoverWidth)
    }
}
