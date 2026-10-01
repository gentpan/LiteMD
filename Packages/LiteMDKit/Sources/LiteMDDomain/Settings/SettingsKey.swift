import Foundation

/// 跨平台统一的设置 Key（spec §138）。各平台存储机制可以不同，但 Key 与行为保持一致。
public enum SettingsKey: String, CaseIterable, Sendable {
    case generalAutoSave = "general.autoSave"
    case generalAutoSaveDelay = "general.autoSaveDelay"
    case generalRestoreSession = "general.restoreSession"

    case appearanceTheme = "appearance.theme"
    /// 旧版本的单一颜色主题，仅用于迁移。
    case appearanceColorTheme = "appearance.colorTheme"
    case appearanceLightTheme = "appearance.lightTheme"
    case appearanceDarkTheme = "appearance.darkTheme"
    case appearanceAppIcon = "appearance.appIcon"

    /// 旧版本的字体与宽度设置，仅用于迁移。
    case editorFontFamily = "editor.fontFamily"
    case editorCustomFontName = "editor.customFontName"
    case editorWidth = "editor.width"
    /// 正文字体：空 = 系统字体，`serif`、`mono` 为系统衬线 / 等宽，其他为字体族名称。
    case editorTextFont = "editor.textFont"
    /// 标题字体：空 = 与正文相同。
    case editorHeadingFont = "editor.headingFont"
    /// 代码字体：空 = 系统等宽字体。
    case editorCodeFont = "editor.codeFont"
    case editorFontSize = "editor.fontSize"
    case editorLineHeight = "editor.lineHeight"
    /// 行宽（em），0 表示铺满。
    case editorLineWidth = "editor.lineWidth"
    /// 段落间距（em）。
    case editorParagraphSpacing = "editor.paragraphSpacing"
    /// 段落首行缩进（em）。
    case editorParagraphIndent = "editor.paragraphIndent"
    case editorWordWrap = "editor.wordWrap"
    case editorIndentUnit = "editor.indentUnit"
    case editorShowToolbar = "editor.showToolbar"
    case editorFocusMode = "editor.focusMode"
    case editorTypewriterMode = "editor.typewriterMode"

    case markdownListContinuation = "markdown.listContinuation"
    case previewSyncScroll = "preview.syncScroll"

    case filesAssetFolder = "files.assetFolder"
    case filesCustomAssetFolder = "files.customAssetFolder"
    case filesShowHiddenFiles = "files.showHiddenFiles"

    case backupProvider = "backup.provider"
    case backupAutomatic = "backup.automatic"
    case backupMirrorDeletions = "backup.mirrorDeletions"
    case backupEndpoint = "backup.endpoint"
    case backupRegion = "backup.region"
    case backupBucket = "backup.bucket"
    case backupPrefix = "backup.prefix"
    case backupPathStyle = "backup.pathStyle"
    case backupAccessKeyID = "backup.accessKeyID"
    /// S3 文档浏览器使用的桶；为空时与备份相同。
    case backupBrowserBucket = "backup.browserBucket"
}

public enum AppTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// 图片保存位置（spec §20）。
public enum AssetFolderMode: String, CaseIterable, Sendable {
    /// 与文档同一目录。
    case sameFolder
    /// 文档目录下的 `assets/`。
    case assets
    /// 文档目录下的 `images/`。
    case images
    /// 相对文档目录的自定义路径。
    case custom
}
