import AppKit
import SwiftUI

@main
struct LiteMDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("LiteMD", id: MainWindowView.windowID) {
            MainWindowView()
                .environment(model)
        }
        .defaultSize(width: Layout.defaultWindowWidth, height: Layout.defaultWindowHeight)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            LiteMDCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.locale, .interface)
                .environment(\.colorTheme, model.settings.activeTheme)
                .tint(Color.themeAccent(model.settings.activeTheme))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            await AppModel.shared.open(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppModel.shared.openMainWindow?()
        }
        return true
    }

    /// 退出前等待所有保存完成（spec §184：不能有数据丢失）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let model = AppModel.shared
            let approved = await model.prepareForTermination()
            if !approved {
                model.updates.installationCancelled()
                if !sender.windows.contains(where: \.isVisible) {
                    model.openMainWindow?()
                }
            }
            if approved, model.updates.preparedApplication != nil {
                model.updates.scheduleInstallation()
            } else if approved, model.isRelaunchRequested {
                SystemIntegration.relaunchAfterExit()
            }
            model.isRelaunchRequested = false
            sender.reply(toApplicationShouldTerminate: approved)
        }
        return .terminateLater
    }
}
