import Foundation

/// 一组主题颜色（spec §28），十六进制 `#RRGGBB`。各平台使用同一份取值。
public struct ThemeColors: Equatable, Sendable {
    /// 链接、列表标记、光标、当前标签页等强调色。
    public var accent: String
    /// 强调色的浅底：选中文本背景、选中行。
    public var accentSubtle: String
    /// 编辑器与预览背景。
    public var background: String
    public var foreground: String
    /// 标题文字。
    public var heading: String
    public var secondary: String
    public var tertiary: String
    /// 代码块、状态栏等次级表面。
    public var surface: String
    public var border: String
    /// `==高亮==` 背景。
    public var highlight: String

    public init(
        accent: String,
        accentSubtle: String,
        background: String,
        foreground: String,
        heading: String,
        secondary: String,
        tertiary: String,
        surface: String,
        border: String,
        highlight: String
    ) {
        self.accent = accent
        self.accentSubtle = accentSubtle
        self.background = background
        self.foreground = foreground
        self.heading = heading
        self.secondary = secondary
        self.tertiary = tertiary
        self.surface = surface
        self.border = border
        self.highlight = highlight
    }
}

/// 颜色主题：每套主题本身是浅色或深色，浅色模式与深色模式各选一套。
///
/// 配色参考了常见的开源配色方案（Solarized、Nord、Dracula、Catppuccin、Rosé Pine、Tokyo Night、
/// One Dark、Gruvbox 等，均为 MIT 许可），并按 LiteMD 的界面语义重新整理。
public enum ColorTheme: String, CaseIterable, Identifiable, Sendable {
    case paper
    case redGraphite
    case blueGraphite
    case forest
    case solarizedLight
    case glacier
    case sepia
    case roseDawn
    case latte
    case wheat
    case charcoal
    case midnight
    case solarizedDark
    case dracula
    case nord
    case cobalt
    case tokyoNight
    case oneDark
    case mocha
    case rosePine

    public var id: String { rawValue }

    /// 英文名，界面通过本地化表显示中文名。
    public var displayName: String {
        switch self {
        case .paper: "Paper"
        case .redGraphite: "Red Graphite"
        case .blueGraphite: "Blue Graphite"
        case .forest: "Forest"
        case .solarizedLight: "Solarized Light"
        case .glacier: "Glacier"
        case .sepia: "Sepia"
        case .roseDawn: "Rosé Dawn"
        case .latte: "Latte"
        case .wheat: "Wheat"
        case .charcoal: "Charcoal"
        case .midnight: "Midnight"
        case .solarizedDark: "Solarized Dark"
        case .dracula: "Dracula"
        case .nord: "Nord"
        case .cobalt: "Cobalt"
        case .tokyoNight: "Tokyo Night"
        case .oneDark: "One Dark"
        case .mocha: "Mocha"
        case .rosePine: "Rosé Pine"
        }
    }

    public var isDark: Bool {
        switch self {
        case .charcoal, .midnight, .solarizedDark, .dracula, .nord, .cobalt, .tokyoNight, .oneDark, .mocha, .rosePine: true
        default: false
        }
    }

    public var colors: ThemeColors {
        switch self {
        case .paper: ThemeColors(accent: "#2563EB", accentSubtle: "#DBEAFE", background: "#FFFFFF", foreground: "#1F2937", heading: "#111827", secondary: "#6B7280", tertiary: "#9CA3AF", surface: "#F3F4F6", border: "#E5E7EB", highlight: "#FEF3C7")
        case .redGraphite: ThemeColors(accent: "#D0423B", accentSubtle: "#FBE3E1", background: "#FFFFFF", foreground: "#333333", heading: "#222222", secondary: "#6E6E73", tertiary: "#A1A1A6", surface: "#F5F5F7", border: "#E5E5EA", highlight: "#FFF1B8")
        case .blueGraphite: ThemeColors(accent: "#2871C3", accentSubtle: "#DCEBFA", background: "#F9F9FA", foreground: "#2E2E33", heading: "#1C1C1E", secondary: "#6E6E73", tertiary: "#A1A1A6", surface: "#EFEFF2", border: "#E3E3E8", highlight: "#FFF1B8")
        case .forest: ThemeColors(accent: "#12853C", accentSubtle: "#DCFCE7", background: "#FFFFFF", foreground: "#1F2A24", heading: "#14532D", secondary: "#5F6B63", tertiary: "#9AA59E", surface: "#F1F5F2", border: "#DFE7E1", highlight: "#FEF9C3")
        case .solarizedLight: ThemeColors(accent: "#8D6A00", accentSubtle: "#F4E7BD", background: "#FDF6E3", foreground: "#586E75", heading: "#073642", secondary: "#657B83", tertiary: "#93A1A1", surface: "#EEE8D5", border: "#E4DCC5", highlight: "#F6E3A1")
        case .glacier: ThemeColors(accent: "#527197", accentSubtle: "#DDE6F1", background: "#F7F9FC", foreground: "#3B4252", heading: "#2E3440", secondary: "#4C566A", tertiary: "#8A93A6", surface: "#ECEFF4", border: "#DCE2EA", highlight: "#F4E6C3")
        case .sepia: ThemeColors(accent: "#1E4E8C", accentSubtle: "#DCE5F0", background: "#F8F4EC", foreground: "#433422", heading: "#2F2415", secondary: "#6F5E48", tertiary: "#A39480", surface: "#EFE8DB", border: "#E2D8C6", highlight: "#F3E2A9")
        case .roseDawn: ThemeColors(accent: "#9A5D5A", accentSubtle: "#F5E0DD", background: "#FAF4ED", foreground: "#575279", heading: "#286983", secondary: "#797593", tertiary: "#9893A5", surface: "#F2E9E1", border: "#E6DCD3", highlight: "#F6E2B8")
        case .latte: ThemeColors(accent: "#8839EF", accentSubtle: "#E6DAFC", background: "#EFF1F5", foreground: "#4C4F69", heading: "#12777D", secondary: "#5C5F77", tertiary: "#8C8FA1", surface: "#E6E9EF", border: "#DCE0E8", highlight: "#F7E6B5")
        case .wheat: ThemeColors(accent: "#3F7654", accentSubtle: "#DDE8C8", background: "#FBF1C7", foreground: "#3C3836", heading: "#746F0D", secondary: "#665C54", tertiary: "#928374", surface: "#F2E5BC", border: "#E5D5A6", highlight: "#F5D98B")
        case .charcoal: ThemeColors(accent: "#60A5FA", accentSubtle: "#1E3A5F", background: "#1E1F22", foreground: "#D4D4D8", heading: "#F4F4F5", secondary: "#A1A1AA", tertiary: "#71717A", surface: "#2A2B2F", border: "#38393E", highlight: "#5C4813")
        case .midnight: ThemeColors(accent: "#FF9F0A", accentSubtle: "#3D2A05", background: "#000000", foreground: "#E5E5E5", heading: "#FFD60A", secondary: "#A3A3A3", tertiary: "#737373", surface: "#141414", border: "#262626", highlight: "#4D3B00")
        case .solarizedDark: ThemeColors(accent: "#2AA198", accentSubtle: "#0B4A4A", background: "#002B36", foreground: "#93A1A1", heading: "#EEE8D5", secondary: "#839496", tertiary: "#586E75", surface: "#073642", border: "#0E4452", highlight: "#594A0B")
        case .dracula: ThemeColors(accent: "#8BE9FD", accentSubtle: "#2F4A5A", background: "#282A36", foreground: "#F8F8F2", heading: "#50FA7B", secondary: "#C5C8D6", tertiary: "#6272A4", surface: "#343746", border: "#44475A", highlight: "#5A4E1E")
        case .nord: ThemeColors(accent: "#A3BE8C", accentSubtle: "#3F4B3A", background: "#2E3440", foreground: "#D8DEE9", heading: "#ECEFF4", secondary: "#B3BBC8", tertiary: "#7B8394", surface: "#3B4252", border: "#434C5E", highlight: "#5E5335")
        case .cobalt: ThemeColors(accent: "#3AD29F", accentSubtle: "#1E5249", background: "#193549", foreground: "#E1EFFF", heading: "#FFC600", secondary: "#A9C1D9", tertiary: "#6A8BA8", surface: "#1F4662", border: "#234E6D", highlight: "#6B5A12")
        case .tokyoNight: ThemeColors(accent: "#BB9AF7", accentSubtle: "#3A3155", background: "#1A1B26", foreground: "#A9B1D6", heading: "#7AA2F7", secondary: "#8C93B8", tertiary: "#565F89", surface: "#24283B", border: "#292E42", highlight: "#4E4323")
        case .oneDark: ThemeColors(accent: "#61AFEF", accentSubtle: "#23405A", background: "#282C34", foreground: "#ABB2BF", heading: "#E5C07B", secondary: "#9DA5B4", tertiary: "#5C6370", surface: "#2F343D", border: "#3A3F4B", highlight: "#5A4B24")
        case .mocha: ThemeColors(accent: "#CBA6F7", accentSubtle: "#45386A", background: "#1E1E2E", foreground: "#CDD6F4", heading: "#94E2D5", secondary: "#A6ADC8", tertiary: "#6C7086", surface: "#313244", border: "#45475A", highlight: "#5B4F2E")
        case .rosePine: ThemeColors(accent: "#EBBCBA", accentSubtle: "#4A3A45", background: "#191724", foreground: "#E0DEF4", heading: "#C4A7E7", secondary: "#908CAA", tertiary: "#6E6A86", surface: "#1F1D2E", border: "#26233A", highlight: "#5A4A2A")
        }
    }

    /// 侧栏背景。石墨红、石墨蓝使用深色侧栏搭配浅色编辑区。
    public var sidebarBackground: String {
        switch self {
        case .paper: "#F5F5F7"
        case .redGraphite: "#2C2C2E"
        case .blueGraphite: "#2C2C2E"
        case .forest: "#F1F5F2"
        case .solarizedLight: "#EEE8D5"
        case .glacier: "#E5E9F0"
        case .sepia: "#EFE8DB"
        case .roseDawn: "#FFFAF3"
        case .latte: "#E6E9EF"
        case .wheat: "#F2E5BC"
        case .charcoal: "#18191B"
        case .midnight: "#0A0A0A"
        case .solarizedDark: "#00212B"
        case .dracula: "#21222C"
        case .nord: "#272C36"
        case .cobalt: "#15232D"
        case .tokyoNight: "#16161E"
        case .oneDark: "#21252B"
        case .mocha: "#181825"
        case .rosePine: "#13111E"
        }
    }

    public var sidebarIsDark: Bool {
        isDark || self == .redGraphite || self == .blueGraphite
    }

    /// 与主题明暗相反的界面（例如浅色主题的深色侧栏）使用的颜色，强调色沿用主题色系。
    public var contrastColors: ThemeColors {
        let accent = colors.accent
        if isDark {
            return ThemeColors(accent: accent, accentSubtle: "#E5E7EB", background: "#FFFFFF", foreground: "#1F2937", heading: "#111827", secondary: "#6B7280", tertiary: "#9CA3AF", surface: "#F3F4F6", border: "#E5E7EB", highlight: "#FEF3C7")
        }
        switch self {
        case .redGraphite:
            return ThemeColors(accent: "#FF6B63", accentSubtle: "#5A3431", background: "#2C2C2E", foreground: "#E5E5EA", heading: "#F2F2F7", secondary: "#AEAEB2", tertiary: "#8E8E93", surface: "#3A3A3C", border: "#48484A", highlight: "#5C4A12")
        case .blueGraphite:
            return ThemeColors(accent: "#5AA2F0", accentSubtle: "#1F3F66", background: "#2C2C2E", foreground: "#E5E5EA", heading: "#F2F2F7", secondary: "#AEAEB2", tertiary: "#8E8E93", surface: "#3A3A3C", border: "#48484A", highlight: "#5C4A12")
        default:
            return ThemeColors(accent: accent, accentSubtle: "#374151", background: "#1E1F22", foreground: "#D4D4D8", heading: "#F4F4F5", secondary: "#A1A1AA", tertiary: "#71717A", surface: "#2A2B2F", border: "#38393E", highlight: "#5C4813")
        }
    }

    public static let defaultLight: ColorTheme = .paper
    public static let defaultDark: ColorTheme = .charcoal

    /// 旧版本只有四个强调色主题（graphite / green / blue / red），迁移为浅色主题。
    public static func migrated(legacy rawValue: String) -> ColorTheme? {
        switch rawValue {
        case "blue", "graphite": .paper
        case "green": .forest
        case "red": .redGraphite
        default: nil
        }
    }
}

/// 可选的应用图标。
public enum AppIconOption: String, CaseIterable, Identifiable, Sendable {
    case graphite
    case green
    case blue
    case red

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .graphite: "Graphite"
        case .green: "Green"
        case .blue: "Blue"
        case .red: "Red"
        }
    }

    /// 应用包内的图标资源名（不含扩展名）。
    public var resourceName: String {
        "AppIcon-\(displayName)"
    }

    public static let `default`: AppIconOption = .blue
}
