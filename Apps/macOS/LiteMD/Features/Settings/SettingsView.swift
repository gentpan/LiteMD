import AppKit
import LiteMDDomain
import LiteMDInfrastructure
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case themes
    case appIcon
    case editor
    case markdown
    case files
    case backup
    case advanced
}

/// 设置分组（spec §72）：General / Appearance / Editor / Markdown / Files / Backup / Advanced。
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            FormatSettings()
                .tabItem {
                    Label {
                        Text("Format")
                    } icon: {
                        Image.interfaceSymbol("textformat")
                    }
                }
                .tag(SettingsTab.editor)
            ThemeSettings()
                .tabItem { Label("Themes", systemImage: "swatchpalette") }
                .tag(SettingsTab.themes)
            AppIconSettings()
                .tabItem { Label("App Icon", systemImage: "app.gift") }
                .tag(SettingsTab.appIcon)
            MarkdownSettings()
                .tabItem { Label("Markdown", systemImage: "number") }
                .tag(SettingsTab.markdown)
            FilesSettings()
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(SettingsTab.files)
            BackupSettings()
                .tabItem { Label("Backup", systemImage: "externaldrive.badge.icloud") }
                .tag(SettingsTab.backup)
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.advanced)
        }
        .frame(width: Layout.settingsWidth, height: Layout.settingsHeight)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Save automatically", isOn: $settings.autoSave)
                Picker("Save delay", selection: $settings.autoSaveDelayMilliseconds) {
                    Text("300 ms").tag(300)
                    Text("500 ms").tag(500)
                    Text("800 ms").tag(800)
                    Text("1 second").tag(1000)
                    Text("2 seconds").tag(2000)
                }
                .disabled(!settings.autoSave)
            } footer: {
                Text("Changes are written safely after you pause typing. LiteMD never overwrites files that were changed by other apps.")
            }
            Section {
                Toggle("Reopen folder and documents on launch", isOn: $settings.restoreSession)
            }
            UpdateSection()
            Section {
                Picker("Language", selection: $settings.language) {
                    Text("System Default").tag(AppLanguage.system)
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                }
                if settings.language != launchLanguage {
                    HStack {
                        Text("Restart LiteMD to use the new language.")
                            .foregroundStyle(Color.textSecondary)
                        Spacer()
                        Button("Restart Now") { model.relaunch() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var launchLanguage: AppLanguage { AppLanguage.atLaunch }
}

/// 通用设置中的“更新”分组。
private struct UpdateSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updates = model.updates
        Section {
            LabeledContent("Version") {
                Text(verbatim: "\(UpdateModel.currentVersion) (\(UpdateModel.currentBuild ?? "-"))")
                    .foregroundStyle(Color.textSecondary)
            }
            Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                .disabled(!updates.isConfigured)
            HStack(spacing: Space.s2) {
                statusText
                Spacer()
                Button("Check Now") {
                    Task { await updates.check(userInitiated: true) }
                }
                .disabled(!updates.isConfigured || updates.phase == .checking || updates.phase == .installing)
            }
        } header: {
            Text("Updates")
        } footer: {
            if !updates.isConfigured {
                Text("This copy of LiteMD was not built with an update source.")
            } else {
                Text("Updates are downloaded over HTTPS and installed only when their signature matches the LiteMD developer key.")
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch model.updates.phase {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking…").foregroundStyle(Color.textSecondary)
        case .upToDate:
            Text("LiteMD is up to date.").foregroundStyle(Color.textSecondary)
        case .available(let item):
            Text("Version \(item.version) is available.").foregroundStyle(Color.textPrimary)
        case .installing:
            Text("Installing update…").foregroundStyle(Color.textSecondary)
        case .failed(let message):
            Text(verbatim: message).foregroundStyle(Color.statusError).lineLimit(2)
        }
    }
}

/// 设置 → 应用图标。
private struct AppIconSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                HStack(spacing: Space.s3) {
                    ForEach(AppIconOption.allCases) { option in
                        AppIconButton(option: option, isSelected: settings.appIcon == option) {
                            settings.appIcon = option
                        }
                    }
                }
                .padding(.vertical, Space.s1)
            } header: {
                Text("App Icon")
            } footer: {
                Text("The Dock icon changes while LiteMD is running.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppIconButton: View {
    @Environment(\.colorTheme) private var colorTheme
    let option: AppIconOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.s2) {
                Group {
                    if let image = option.image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        RoundedRectangle(cornerRadius: Radius.large).fill(Color.surfaceMuted)
                    }
                }
                .frame(width: Space.s16, height: Space.s16)
                .padding(Space.s1)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.large)
                        .stroke(isSelected ? Color.themeAccent(colorTheme) : Color.clear, lineWidth: 2)
                )

                Text(LocalizedStringKey(option.displayName))
                    .font(.system(size: TextSize.xs, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

}

private struct MarkdownSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Toggle("Continue lists and quotes on Return", isOn: $settings.listContinuation)
            Toggle("Sync preview scrolling with editor", isOn: $settings.previewSyncScroll)
        }
        .formStyle(.grouped)
    }
}

private struct FilesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Save images to", selection: $settings.assetFolderMode) {
                    Text("Same folder as document").tag(AssetFolderMode.sameFolder)
                    Text("assets/").tag(AssetFolderMode.assets)
                    Text("images/").tag(AssetFolderMode.images)
                    Text("Custom folder").tag(AssetFolderMode.custom)
                }
                if settings.assetFolderMode == .custom {
                    TextField("Folder", text: $settings.customAssetFolder, prompt: Text("relative to the document"))
                }
            } footer: {
                Text("Pasted and dropped images are copied here and linked with a relative path. Existing files are never overwritten.")
            }
            Section {
                Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("App data") {
                    Button("Show in Finder") {
                        let url = AppDirectories.applicationSupport()
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        SystemIntegration.revealInFinder(url)
                    }
                }
                LabeledContent("Recent items") {
                    Button("Clear") { model.session.clearRecents() }
                }
            } footer: {
                Text("LiteMD stores recent items, session state, crash recovery snapshots, version history and backup records here. Your Markdown files are never stored in this folder.")
            }
        }
        .formStyle(.grouped)
    }
}
