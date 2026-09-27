import AppKit
import LiteMDApplication
import LiteMDBackup
import LiteMDDomain
import Observation

/// 设置（spec §72、§138）。Key 与其他平台一致，存储于 UserDefaults。
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    // General
    var autoSave: Bool { didSet { store(autoSave, .generalAutoSave) } }
    var autoSaveDelayMilliseconds: Int { didSet { store(autoSaveDelayMilliseconds, .generalAutoSaveDelay) } }
    var restoreSession: Bool { didSet { store(restoreSession, .generalRestoreSession) } }

    // Appearance
    var theme: AppTheme { didSet { store(theme.rawValue, .appearanceTheme) } }
    /// 浅色模式使用的主题。
    var lightTheme: ColorTheme { didSet { store(lightTheme.rawValue, .appearanceLightTheme) } }
    /// 深色模式使用的主题。
    var darkTheme: ColorTheme { didSet { store(darkTheme.rawValue, .appearanceDarkTheme) } }
    /// 系统当前是否为深色外观（外观模式为“跟随系统”时使用）。
    var systemIsDark: Bool = SystemAppearance.isDark { didSet { if systemIsDark != oldValue { onChange?() } } }
    var appIcon: AppIconOption { didSet { store(appIcon.rawValue, .appearanceAppIcon) } }
    @ObservationIgnored private var appliedAppIcon: AppIconOption?
    var showFormattingToolbar: Bool { didSet { store(showFormattingToolbar, .editorShowToolbar) } }

    /// 界面语言。写入本应用的 `AppleLanguages`，重启后生效。
    var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            if let code = language.languageCode {
                defaults.set([code], forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }
    }

    // Editor
    /// 正文字体：空 = 系统字体，`serif` / `mono` = 系统衬线 / 等宽，其余为字体族名称。
    var textFont: String { didSet { store(textFont, .editorTextFont) } }
    /// 标题字体：空 = 与正文相同。
    var headingFont: String { didSet { store(headingFont, .editorHeadingFont) } }
    /// 代码字体：空 = 系统等宽字体。
    var codeFontFamily: String { didSet { store(codeFontFamily, .editorCodeFont) } }
    var fontSize: Double { didSet { store(fontSize, .editorFontSize) } }
    var lineHeight: Double { didSet { store(lineHeight, .editorLineHeight) } }
    /// 行宽（em），0 表示铺满。
    var lineWidth: Double { didSet { store(lineWidth, .editorLineWidth) } }
    var paragraphSpacing: Double { didSet { store(paragraphSpacing, .editorParagraphSpacing) } }
    var paragraphIndent: Double { didSet { store(paragraphIndent, .editorParagraphIndent) } }
    var wordWrap: Bool { didSet { store(wordWrap, .editorWordWrap) } }
    var indentUnit: String { didSet { store(indentUnit, .editorIndentUnit) } }
    /// 专注模式：当前段落以外的文字变淡。
    var focusMode: Bool { didSet { store(focusMode, .editorFocusMode) } }
    /// 打字机滚动：光标所在行保持在编辑区垂直居中。
    var typewriterMode: Bool { didSet { store(typewriterMode, .editorTypewriterMode) } }

    // Markdown
    var listContinuation: Bool { didSet { store(listContinuation, .markdownListContinuation) } }
    var previewSyncScroll: Bool { didSet { store(previewSyncScroll, .previewSyncScroll) } }

    // Files
    var assetFolderMode: AssetFolderMode { didSet { store(assetFolderMode.rawValue, .filesAssetFolder) } }
    var customAssetFolder: String { didSet { store(customAssetFolder, .filesCustomAssetFolder) } }
    var showHiddenFiles: Bool { didSet { store(showHiddenFiles, .filesShowHiddenFiles) } }

    // Backup（输入框逐字保存，不触发全局设置刷新）
    var backupProvider: S3Provider { didSet { storeQuietly(backupProvider.rawValue, .backupProvider) } }
    var backupAutomatic: Bool { didSet { storeQuietly(backupAutomatic, .backupAutomatic) } }
    var backupMirrorDeletions: Bool { didSet { storeQuietly(backupMirrorDeletions, .backupMirrorDeletions) } }
    var backupEndpoint: String { didSet { storeQuietly(backupEndpoint, .backupEndpoint) } }
    var backupRegion: String { didSet { storeQuietly(backupRegion, .backupRegion) } }
    var backupBucket: String { didSet { storeQuietly(backupBucket, .backupBucket) } }
    var backupPrefix: String { didSet { storeQuietly(backupPrefix, .backupPrefix) } }
    var backupPathStyle: Bool { didSet { storeQuietly(backupPathStyle, .backupPathStyle) } }
    var backupAccessKeyID: String { didSet { storeQuietly(backupAccessKeyID, .backupAccessKeyID) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: SettingsKey, _ fallback: T) -> T {
            defaults.object(forKey: key.rawValue) as? T ?? fallback
        }
        autoSave = value(.generalAutoSave, true)
        autoSaveDelayMilliseconds = value(.generalAutoSaveDelay, 500)
        restoreSession = value(.generalRestoreSession, true)
        theme = AppTheme(rawValue: value(.appearanceTheme, AppTheme.system.rawValue)) ?? .system
        let legacyTheme = (defaults.string(forKey: SettingsKey.appearanceColorTheme.rawValue)).flatMap(ColorTheme.migrated(legacy:))
        lightTheme = ColorTheme(rawValue: value(.appearanceLightTheme, "")) ?? legacyTheme ?? .defaultLight
        darkTheme = ColorTheme(rawValue: value(.appearanceDarkTheme, "")) ?? .defaultDark
        appIcon = AppIconOption(rawValue: value(.appearanceAppIcon, AppIconOption.default.rawValue)) ?? .default
        showFormattingToolbar = value(.editorShowToolbar, true)
        let bundleID = Bundle.main.bundleIdentifier ?? "app.litemd.LiteMD"
        let storedLanguages = defaults.persistentDomain(forName: bundleID)?["AppleLanguages"] as? [String]
        let launchLanguage = AppLanguage(languageCode: storedLanguages?.first)
        language = launchLanguage
        AppLanguage.atLaunch = launchLanguage
        // 旧版本：字体族枚举 + 自定义字体名、四档宽度。
        let legacyFamily: String = switch defaults.string(forKey: SettingsKey.editorFontFamily.rawValue) {
        case "serif": "serif"
        case "mono": "mono"
        case "custom": defaults.string(forKey: SettingsKey.editorCustomFontName.rawValue) ?? ""
        default: ""
        }
        let legacyWidth: Double = switch defaults.string(forKey: SettingsKey.editorWidth.rawValue) {
        case "narrow": 40
        case "wide": 64
        case "full": 0
        default: Self.defaultLineWidth
        }
        textFont = value(.editorTextFont, legacyFamily)
        headingFont = value(.editorHeadingFont, "")
        codeFontFamily = value(.editorCodeFont, "")
        fontSize = value(.editorFontSize, Self.defaultFontSize)
        lineHeight = value(.editorLineHeight, Self.defaultLineHeight)
        lineWidth = value(.editorLineWidth, legacyWidth)
        paragraphSpacing = value(.editorParagraphSpacing, 0)
        paragraphIndent = value(.editorParagraphIndent, 0)
        wordWrap = value(.editorWordWrap, true)
        indentUnit = value(.editorIndentUnit, "    ")
        focusMode = value(.editorFocusMode, false)
        typewriterMode = value(.editorTypewriterMode, false)
        listContinuation = value(.markdownListContinuation, true)
        previewSyncScroll = value(.previewSyncScroll, true)
        assetFolderMode = AssetFolderMode(rawValue: value(.filesAssetFolder, AssetFolderMode.assets.rawValue)) ?? .assets
        customAssetFolder = value(.filesCustomAssetFolder, "assets")
        showHiddenFiles = value(.filesShowHiddenFiles, false)
        backupProvider = S3Provider(rawValue: value(.backupProvider, S3Provider.aws.rawValue)) ?? .aws
        backupAutomatic = value(.backupAutomatic, false)
        backupMirrorDeletions = value(.backupMirrorDeletions, false)
        backupEndpoint = value(.backupEndpoint, "")
        backupRegion = value(.backupRegion, "")
        backupBucket = value(.backupBucket, "")
        backupPrefix = value(.backupPrefix, "LiteMD")
        backupPathStyle = value(.backupPathStyle, true)
        backupAccessKeyID = value(.backupAccessKeyID, "")
    }

    private func store(_ value: Any, _ key: SettingsKey) {
        defaults.set(value, forKey: key.rawValue)
        onChange?()
    }

    private func storeQuietly(_ value: Any, _ key: SettingsKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    var backupConfiguration: S3Configuration {
        backupProvider.configuration(
            endpoint: backupEndpoint,
            region: backupRegion,
            bucket: backupBucket,
            prefix: backupPrefix,
            usesPathStyle: backupPathStyle,
            accessKeyID: backupAccessKeyID
        )
    }

    var assetLocation: AssetLocation {
        AssetLocation(mode: assetFolderMode, customPath: customAssetFolder)
    }

    static let defaultFontSize: Double = 16
    static let defaultLineHeight: Double = 1.5
    static let defaultLineWidth: Double = 50

    var editorFont: NSFont {
        Self.font(family: textFont, size: CGFloat(fontSize))
    }

    /// 标题字体（粗体）。未单独设置时使用正文字体的粗体。
    var editorHeadingFont: NSFont {
        let base = Self.font(family: headingFont.isEmpty ? textFont : headingFont, size: CGFloat(fontSize))
        return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    }

    var codeFont: NSFont {
        let size = (CGFloat(fontSize) * 0.9).rounded()
        guard !codeFontFamily.isEmpty else { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFontManager.shared.font(withFamily: codeFontFamily, traits: [], weight: 5, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 正文最大宽度（pt），nil 表示铺满。
    var lineWidthPoints: CGFloat? {
        lineWidth > 0 ? CGFloat(lineWidth * fontSize) : nil
    }

    static func font(family: String, size: CGFloat) -> NSFont {
        switch family {
        case "":
            return NSFont.systemFont(ofSize: size)
        case "serif":
            let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
        case "mono":
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        default:
            return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? NSFont.systemFont(ofSize: size)
        }
    }

    var editorTypography: EditorTypography {
        EditorTypography(
            font: editorFont,
            headingFont: editorHeadingFont,
            codeFont: codeFont,
            lineHeight: CGFloat(lineHeight),
            paragraphSpacing: CGFloat(paragraphSpacing),
            paragraphIndent: CGFloat(paragraphIndent)
        )
    }

    /// 恢复“格式”中的所有默认值。
    func resetFormat() {
        textFont = ""
        headingFont = ""
        codeFontFamily = ""
        fontSize = Self.defaultFontSize
        lineHeight = Self.defaultLineHeight
        lineWidth = Self.defaultLineWidth
        paragraphSpacing = 0
        paragraphIndent = 0
    }

    /// 当前外观模式下是否使用深色主题槽位。
    var usesDarkThemeSlot: Bool {
        switch theme {
        case .system: systemIsDark
        case .light: false
        case .dark: true
        }
    }

    /// 正在使用的主题。
    var activeTheme: ColorTheme {
        usesDarkThemeSlot ? darkTheme : lightTheme
    }

    /// 把主题用于当前外观（浅色或深色槽位）。
    func useThemeForCurrentAppearance(_ theme: ColorTheme) {
        if usesDarkThemeSlot {
            darkTheme = theme
        } else {
            lightTheme = theme
        }
    }

    /// 应用外观跟随主题明暗：深色主题使用深色外观，菜单、弹出框、预览都保持一致。
    func applyTheme() {
        let active = activeTheme
        ThemeRuntime.shared.theme = active
        let name: NSAppearance.Name = active.isDark ? .darkAqua : .aqua
        if NSApp.appearance?.name != name {
            NSApp.appearance = NSAppearance(named: name)
        }
    }

    /// 替换 Dock 中的应用图标（应用运行期间生效；不修改应用包，保证代码签名完整）。
    /// 每次改设置都会调用：图标没变就不重读 .icns、不重设 Dock。
    func applyAppIcon() {
        guard appIcon != appliedAppIcon, let image = appIcon.image else { return }
        appliedAppIcon = appIcon
        NSApp.applicationIconImage = image
    }
}

extension AppIconOption {
    @MainActor private static var imageCache: [AppIconOption: NSImage] = [:]

    /// 应用包里对应的 .icns（Dock 与设置页的图标选择共用，读一次后缓存）。
    @MainActor var image: NSImage? {
        if let cached = Self.imageCache[self] { return cached }
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return nil }
        Self.imageCache[self] = image
        return image
    }
}

/// 系统外观。应用自身的外观由主题决定，因此不能读取 NSApp.effectiveAppearance。
enum SystemAppearance {
    static var isDark: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return (CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String) == "Dark"
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    /// 本次启动时生效的语言设置。
    @MainActor static var atLaunch: AppLanguage = .system

    var id: String { rawValue }

    init(languageCode: String?) {
        switch languageCode {
        case let code? where code.hasPrefix("zh"): self = .simplifiedChinese
        case let code? where code.hasPrefix("en"): self = .english
        default: self = .system
        }
    }

    var languageCode: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        }
    }
}
