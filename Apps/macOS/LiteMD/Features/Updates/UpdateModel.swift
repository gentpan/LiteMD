import AppKit
import LiteMDUpdates
import Observation
import Security

/// 应用内更新：检查更新源 → 下载并校验 Ed25519 签名 → 解压并校验代码签名 → 退出后替换应用并重新打开。
///
/// 更新源地址与公钥写在 Info.plist（发布脚本注入）；未配置时不检查更新。
@MainActor
@Observable
final class UpdateModel {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateItem)
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Self.automaticKey) }
    }

    /// 已准备好的新版本；退出获准后由 AppDelegate 替换。
    @ObservationIgnored private(set) var preparedApplication: URL?
    /// 解压用的临时目录，安装完成或放弃安装后删除。
    @ObservationIgnored private var preparedWorkspace: URL?
    @ObservationIgnored private var installingItem: UpdateItem?

    private static let automaticKey = "updates.automaticallyCheck"
    private static let lastCheckKey = "updates.lastCheck"

    let feedURL: URL?
    let publicKey: String

    init(bundle: Bundle = .main) {
        let feed = (bundle.object(forInfoDictionaryKey: "LiteMDUpdateFeedURL") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        feedURL = feed.isEmpty ? nil : URL(string: feed)
        publicKey = (bundle.object(forInfoDictionaryKey: "LiteMDUpdatePublicKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        checksAutomatically = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    var isConfigured: Bool { feedURL != nil && !publicKey.isEmpty }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var currentBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private var checker: UpdateChecker? {
        guard let feedURL, !publicKey.isEmpty else { return nil }
        return UpdateChecker(feedURL: feedURL, publicKey: publicKey)
    }

    // MARK: Check

    /// 启动时：开启自动检查且距上次检查超过一天时静默检查，发现新版本才提示。
    func checkOnLaunchIfNeeded() {
        guard isConfigured, checksAutomatically else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 60 * 60 else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await check(userInitiated: false)
        }
    }

    func check(userInitiated: Bool) async {
        guard let checker else {
            if userInitiated {
                SystemIntegration.runAlert(
                    title: String(localized: "Updates are not available for this build."),
                    message: String(localized: "This copy of LiteMD was not built with an update source."),
                    buttons: [String(localized: "OK")],
                    style: .informational
                )
            }
            return
        }
        guard phase != .checking, phase != .installing else { return }
        phase = .checking
        do throws(UpdateError) {
            let item = try await checker.availableUpdate(
                currentVersion: Self.currentVersion,
                currentBuild: Self.currentBuild,
                systemVersion: ProcessInfo.processInfo.operatingSystemVersion
            )
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            if let item {
                phase = .available(item)
                // 自动检查不弹出模态提示（正在输入时按回车可能误点安装），只在状态栏显示入口。
                if userInitiated { promptToInstall(item) }
            } else {
                phase = .upToDate
                if userInitiated {
                    SystemIntegration.runAlert(
                        title: String(localized: "LiteMD is up to date."),
                        message: String(localized: "Version \(Self.currentVersion) is the latest version."),
                        buttons: [String(localized: "OK")],
                        style: .informational
                    )
                }
            }
        } catch {
            phase = .failed(Self.message(for: error))
            if userInitiated {
                SystemIntegration.runAlert(
                    title: String(localized: "Could not check for updates."),
                    message: Self.message(for: error),
                    buttons: [String(localized: "OK")]
                )
            }
        }
    }

    func promptToInstall(_ item: UpdateItem) {
        let notes = item.notes(for: Bundle.main.preferredLocalizations + Locale.preferredLanguages) ?? ""
        let choice = SystemIntegration.runAlert(
            title: String(localized: "LiteMD \(item.version) is available."),
            message: String(localized: "You have version \(Self.currentVersion). LiteMD will save your documents, install the update and reopen."),
            buttons: [String(localized: "Later"), String(localized: "Install and Relaunch")],
            style: .informational,
            details: notes
        )
        guard choice == 1 else { return }
        Task { await install(item) }
    }

    // MARK: Install

    func install(_ item: UpdateItem) async {
        guard let checker else { return }
        phase = .installing
        installingItem = item
        do {
            let data = try await checker.download(item)
            let prepared = try await Task.detached(priority: .userInitiated) {
                try Self.prepare(package: data, expectedVersion: item.version, expectedBuild: item.build)
            }.value
            preparedApplication = prepared.application
            preparedWorkspace = prepared.workspace
            AppModel.shared.relaunch()
        } catch let error as UpdateError {
            fail(Self.message(for: error))
        } catch let error as InstallError {
            fail(error.message)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// 用户在退出前的“未保存”提示里点了取消：放弃这次安装，更新入口重新出现。
    /// 不清掉的话，之后一次普通的 ⌘Q 会悄悄替换应用并重新打开。
    func installationCancelled() {
        guard preparedApplication != nil || phase == .installing else { return }
        discardPreparedUpdate()
        phase = installingItem.map(Phase.available) ?? .idle
        installingItem = nil
    }

    private func discardPreparedUpdate() {
        if let preparedWorkspace { try? FileManager.default.removeItem(at: preparedWorkspace) }
        preparedApplication = nil
        preparedWorkspace = nil
    }

    private func fail(_ message: String) {
        discardPreparedUpdate()
        installingItem = nil
        phase = .failed(message)
        SystemIntegration.runAlert(
            title: String(localized: "The update could not be installed."),
            message: message,
            buttons: [String(localized: "OK")]
        )
    }

    struct InstallError: Error {
        let message: String
    }

    /// 解压安装包并校验：包含同一 Bundle ID、版本号与构建号一致、代码签名有效，
    /// 并且由与当前应用相同的开发者团队用 Apple 签发的证书签名。
    nonisolated static func prepare(package: Data, expectedVersion: String, expectedBuild: String?) throws -> (application: URL, workspace: URL) {
        let current = Bundle.main.bundleURL
        // 把应用包移到别的目录，除了上级目录还需要应用包本身可写。
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: current.path) else {
            throw InstallError(message: String(localized: "LiteMD cannot replace itself in “\(current.deletingLastPathComponent().path)”. Move LiteMD to the Applications folder and try again."))
        }
        guard let team = teamIdentifier(of: current) else {
            throw InstallError(message: String(localized: "The code signature of the update could not be verified."))
        }

        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("LiteMD-Update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let archive = workspace.appendingPathComponent("update.zip")
        try package.write(to: archive)

        let extracted = workspace.appendingPathComponent("extracted", isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, extracted.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw InstallError(message: String(localized: "The update package could not be opened.")) }

        guard let application = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: application),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion,
              expectedBuild == nil || bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == expectedBuild else {
            throw InstallError(message: String(localized: "The update package does not contain the expected version of LiteMD."))
        }
        guard isSigned(application, byTeam: team) else {
            throw InstallError(message: String(localized: "The code signature of the update could not be verified."))
        }
        return (application, workspace)
    }

    nonisolated private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// 代码签名有效，且证书链到 Apple、叶证书属于指定团队。
    /// 只比较签名信息里的团队 ID 不够：那个字段没有经过证书链校验，ad-hoc 签名时两边都是 nil 也会“相等”。
    nonisolated static func isSigned(_ url: URL, byTeam team: String) -> Bool {
        guard !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let code = staticCode(url) else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess
    }

    nonisolated static func teamIdentifier(of url: URL) -> String? {
        guard let code = staticCode(url) else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// 退出获准后安排安装。准备好的应用在临时目录里放了一段时间，替换前再校验一次签名，
    /// 不完整或被改动过就放弃安装，只重新打开当前版本。
    func scheduleInstallation() {
        guard let preparedApplication else { return }
        let current = Bundle.main.bundleURL
        if let team = Self.teamIdentifier(of: current), Self.isSigned(preparedApplication, byTeam: team) {
            SystemIntegration.relaunchAfterExit(installing: preparedApplication, cleaningUp: preparedWorkspace)
        } else {
            discardPreparedUpdate()
            SystemIntegration.relaunchAfterExit()
        }
    }

    static func message(for error: UpdateError) -> String {
        switch error {
        case .invalidFeed:
            String(localized: "The update information could not be read.")
        case .network(let message):
            String(localized: "Could not connect to the update server. \(message)")
        case .lengthMismatch:
            String(localized: "The downloaded update is incomplete.")
        case .invalidSignature:
            String(localized: "The update is not signed by the LiteMD developer and was not installed.")
        case .unsupportedSystem(let version):
            String(localized: "The new version requires macOS \(version) or later.")
        }
    }
}
