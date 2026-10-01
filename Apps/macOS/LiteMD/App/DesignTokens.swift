import AppKit
import LiteMDDomain
import SwiftUI

/// 界面设计 token：4px 间距网格、固定字号阶梯、统一圆角与颜色。
/// 视图中不直接写魔法数字，统一引用这里。
enum Space {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32
    static let s12: CGFloat = 48
    static let s16: CGFloat = 64
}

enum TextSize {
    static let xs: CGFloat = 12
    static let sm: CGFloat = 14
    static let base: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    /// 基准圆角；小控件与面板按层级派生。
    static let base: CGFloat = 8
    static let small: CGFloat = base / 2
    static let medium: CGFloat = base
    static let large: CGFloat = base * 1.5
}

/// 阴影层级（全页最多两级）。
enum Elevation {
    /// 0 1px 3px rgba(0,0,0,0.08)
    static let level1Color = Color.black.opacity(0.08)
    static let level1Radius: CGFloat = 1.5
    static let level1Offset: CGFloat = 1

    /// 0 4px 12px rgba(0,0,0,0.10)：浮在内容之上的面板（格式工具栏）。
    static let level2Color = Color.black.opacity(0.10)
    static let level2Radius: CGFloat = 6
    static let level2Offset: CGFloat = 4
}

enum IconSize {
    static let inline: CGFloat = 16
    static let standalone: CGFloat = 20
}

enum Layout {
    /// 状态栏与侧栏底部栏同高，底边对齐。
    static let statusBarHeight: CGFloat = Space.s8
    static let sidebarMinimumWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 260
    static let sidebarMaximumWidth: CGFloat = 400
    static let tabMaximumWidth: CGFloat = 200
    static let tabMinimumWidth: CGFloat = 96
    static let titlebarTabHeight: CGFloat = Space.s8
    static let sidebarTabHeight: CGFloat = Space.s6
    /// 标题栏右侧格式、图片、模式按钮所需宽度。
    static let titlebarTrailingReserve: CGFloat = 320
    /// 侧栏收起时，标题栏左侧红绿灯与侧栏按钮占用的宽度。
    static let titlebarLeadingReserve: CGFloat = 140
    /// 滚动条：滑块粗细（常态 / 悬停）与离边距离。
    static let scrollerKnob: CGFloat = Space.s1 + Space.s1 / 2
    static let scrollerKnobHover: CGFloat = Space.s2
    static let scrollerInset: CGFloat = Space.s1 / 2
    static let scrollerTrack: CGFloat = Space.s3
    static let welcomeWidth: CGFloat = 480
    static let quickOpenWidth: CGFloat = 560
    static let windowMinimumWidth: CGFloat = 720
    static let windowMinimumHeight: CGFloat = 480
    static let editorMinimumInset: CGFloat = Space.s6
    static let editorMinimumWidth: CGFloat = 240
    static let defaultWindowWidth: CGFloat = 1200
    static let defaultWindowHeight: CGFloat = 800
    static let quickOpenHeight: CGFloat = 400
    static let progressSheetHeight: CGFloat = 280
    static let compareWidth: CGFloat = 800
    static let compareHeight: CGFloat = 560
    static let settingsWidth: CGFloat = 640
    static let settingsHeight: CGFloat = 600
    static let themeCardHeight: CGFloat = 128
    static let formatSliderWidth: CGFloat = 320
    static let backupPopoverWidth: CGFloat = 296
    static let remoteDocumentsWidth: CGFloat = 720
    static let remoteDocumentsHeight: CGFloat = 560
    static let remoteBucketFieldWidth: CGFloat = 180
    static let remoteDateColumnWidth: CGFloat = 128
    static let historyListWidth: CGFloat = 240
    static let backlinksMaximumHeight: CGFloat = 240
    static let folderSymbolCell: CGFloat = Space.s8
    static let dirtyIndicator: CGFloat = Space.s2
    static let closeButton: CGFloat = Space.s4
}

/// 当前颜色主题。NSColor 的动态 provider 可能在任意线程被调用，因此用锁保护。
final class ThemeRuntime: @unchecked Sendable {
    static let shared = ThemeRuntime()
    private let lock = NSLock()
    private var current: ColorTheme = .defaultLight

    var theme: ColorTheme {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    private var currentFonts: PreviewTemplate.Fonts = .system

    /// 当前的预览字体。导出 PDF 时要和屏幕上看到的一致。
    var fonts: PreviewTemplate.Fonts {
        get { lock.withLock { currentFonts } }
        set { lock.withLock { currentFonts = newValue } }
    }
}

/// 颜色 token，全部来自当前主题。
///
/// 应用外观与主题明暗一致；外观相反的界面（例如石墨红的深色侧栏）使用主题的对比色。
enum Palette {
    static var primary: NSColor { themed(\.accent) }
    static var heading: NSColor { themed(\.heading) }
    static var sidebarBackground: NSColor {
        NSColor(name: nil) { _ in NSColor(hexString: ThemeRuntime.shared.theme.sidebarBackground) ?? .windowBackgroundColor }
    }
    static var selection: NSColor { themed(\.accentSubtle) }
    static var textPrimary: NSColor { themed(\.foreground) }
    static var textSecondary: NSColor { themed(\.secondary) }
    static var textTertiary: NSColor { themed(\.tertiary) }
    static var surfaceMuted: NSColor { themed(\.surface) }
    static var border: NSColor { themed(\.border) }
    static var highlight: NSColor { themed(\.highlight) }
    static var editorBackground: NSColor { themed(\.background) }
    static let scrollerKnob = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor(white: 1, alpha: 0.28) : NSColor(white: 0, alpha: 0.22)
    }
    static let scrollerKnobHover = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor(white: 1, alpha: 0.45) : NSColor(white: 0, alpha: 0.38)
    }

    static let success = dynamic(light: 0x16A34A, dark: 0x4ADE80)
    static let warning = dynamic(light: 0xD97706, dark: 0xFBBF24)
    static let error = dynamic(light: 0xDC2626, dark: 0xF87171)
    static let warningSurface = dynamic(light: 0xFFFBEB, dark: 0x451A03)
    static let diffAdded = dynamic(light: 0xDCFCE7, dark: 0x14532D)
    static let diffRemoved = dynamic(light: 0xFEE2E2, dark: 0x7F1D1D)

    /// 按外观取当前主题的颜色。每次访问生成新的动态颜色，主题切换后重新应用即可生效。
    static func themed(_ keyPath: KeyPath<ThemeColors, String> & Sendable) -> NSColor {
        NSColor(name: nil) { appearance in
            let theme = ThemeRuntime.shared.theme
            return NSColor(hexString: colors(of: theme, for: appearance)[keyPath: keyPath]) ?? .labelColor
        }
    }

    static func colors(of theme: ColorTheme, for appearance: NSAppearance) -> ThemeColors {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark == theme.isDark ? theme.colors : theme.contrastColors
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        let digits = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    static var brand: Color { Color(nsColor: Palette.primary) }
    static var textPrimary: Color { Color(nsColor: Palette.textPrimary) }
    static var textSecondary: Color { Color(nsColor: Palette.textSecondary) }
    static var textTertiary: Color { Color(nsColor: Palette.textTertiary) }
    static var surfaceMuted: Color { Color(nsColor: Palette.surfaceMuted) }
    static var borderSubtle: Color { Color(nsColor: Palette.border) }
    static var editorBackground: Color { Color(nsColor: Palette.editorBackground) }
    static var sidebarBackground: Color { Color(nsColor: Palette.sidebarBackground) }
    static let statusSuccess = Color(nsColor: Palette.success)
    static let statusWarning = Color(nsColor: Palette.warning)
    static let statusError = Color(nsColor: Palette.error)
    static let warningSurface = Color(nsColor: Palette.warningSurface)
    static let diffAdded = Color(nsColor: Palette.diffAdded)
    static let diffRemoved = Color(nsColor: Palette.diffRemoved)

    /// 指定主题的强调色（随浅色 / 深色外观变化）。
    static func themeAccent(_ theme: ColorTheme) -> Color {
        Color(nsColor: themed(theme, \.accent))
    }

    static func themeSelection(_ theme: ColorTheme) -> Color {
        Color(nsColor: themed(theme, \.accentSubtle))
    }

    private static func themed(_ theme: ColorTheme, _ keyPath: KeyPath<ThemeColors, String> & Sendable) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hexString: Palette.colors(of: theme, for: appearance)[keyPath: keyPath]) ?? .controlAccentColor
        }
    }
}

extension Locale {
    /// 界面语言 + 系统地区。应用单独设置语言后，SwiftUI 仍按系统语言格式化日期，需要显式指定。
    static let interface: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        guard let region = Locale.current.region?.identifier else { return Locale(identifier: language) }
        return Locale(identifier: "\(language)_\(region)")
    }()
}

extension Image {
    /// 部分 SF Symbols 有本地化字形（例如 textformat 在中文系统显示“格式”），
    /// 系统默认按系统地区选择；这里改为跟随应用界面语言，避免英文界面出现中文图标。
    static func interfaceSymbol(_ name: String) -> Image {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return Image(systemName: name)
        }
        let localized = image.withLocale(Locale(identifier: language))
        localized.isTemplate = true
        return Image(nsImage: localized)
    }
}

extension EnvironmentValues {
    /// 当前颜色主题。视图读取它，主题切换时才会刷新强调色。
    @Entry var colorTheme: ColorTheme = .defaultLight
}
