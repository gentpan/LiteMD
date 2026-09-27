import Foundation
@testable import LiteMDDomain
import Testing

@Suite("Themes")
struct ThemeTests {
    private func luminance(_ hex: String) -> Double {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        func channel(_ shift: UInt32) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private func contrast(_ a: String, _ b: String) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test func twentyThemesSplitEvenly() {
        #expect(ColorTheme.allCases.count == 20)
        #expect(ColorTheme.allCases.filter(\.isDark).count == 10)
        #expect(!ColorTheme.defaultLight.isDark)
        #expect(ColorTheme.defaultDark.isDark)
    }

    @Test func textIsReadableAndDarknessMatchesBackground() {
        for theme in ColorTheme.allCases {
            let colors = theme.colors
            // 正文与标题满足 WCAG AA（4.5:1）。
            #expect(contrast(colors.foreground, colors.background) >= 4.5, "\(theme) body")
            #expect(contrast(colors.heading, colors.background) >= 4.5, "\(theme) heading")
            // 强调色用于链接文字。
            #expect(contrast(colors.accent, colors.background) >= 4.5, "\(theme) accent")
            #expect((luminance(colors.background) < 0.2) == theme.isDark, "\(theme) darkness")
            #expect((luminance(theme.sidebarBackground) < 0.2) == theme.sidebarIsDark, "\(theme) sidebar")
            for hex in [colors.accent, colors.accentSubtle, colors.surface, colors.border, colors.highlight, colors.secondary, colors.tertiary] {
                #expect(hex.count == 7 && UInt32(hex.dropFirst(), radix: 16) != nil, "\(theme) \(hex)")
            }
        }
    }

    @Test func legacyThemesMigrate() {
        #expect(ColorTheme.migrated(legacy: "blue") == .paper)
        #expect(ColorTheme.migrated(legacy: "red") == .redGraphite)
        #expect(ColorTheme.migrated(legacy: "unknown") == nil)
    }
}
