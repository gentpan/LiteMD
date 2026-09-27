import AppKit
import SwiftUI

/// 设置 → 格式：正文 / 标题 / 代码字体，字号、行高、行宽、段落间距与缩进。
struct FormatSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                FontPickerRow(title: "Text font", selection: $settings.textFont, kind: .text)
                FontPickerRow(title: "Heading font", selection: $settings.headingFont, kind: .heading)
                FontPickerRow(title: "Code font", selection: $settings.codeFontFamily, kind: .code)
            }

            CustomFontsSection()

            Section {
                SliderRow(title: "Font size", value: $settings.fontSize, range: 10...32, step: 1) { "\(Int($0)) pt" }
                SliderRow(title: "Line height", value: $settings.lineHeight, range: 1...2.4, step: 0.1) { String(format: "%.1f em", $0) }
                SliderRow(title: "Line width", value: lineWidth, range: 30...100, step: 2) { value in
                    value >= 100 ? String(localized: "Full") : "\(Int(value)) em"
                }
                SliderRow(title: "Paragraph spacing", value: $settings.paragraphSpacing, range: 0...2, step: 0.25) { Self.em($0) }
                SliderRow(title: "Paragraph indent", value: $settings.paragraphIndent, range: 0...4, step: 0.5) { Self.em($0) }
                HStack {
                    Spacer()
                    Button("Restore Editor Defaults") { settings.resetFormat() }
                    Spacer()
                }
            }

            Section {
                Toggle("Wrap lines", isOn: $settings.wordWrap)
                Toggle("Show formatting toolbar", isOn: $settings.showFormattingToolbar)
                Toggle("Focus mode", isOn: $settings.focusMode)
                Toggle("Typewriter scrolling", isOn: $settings.typewriterMode)
                Picker("Indent with", selection: $settings.indentUnit) {
                    Text("2 spaces").tag("  ")
                    Text("4 spaces").tag("    ")
                    Text("Tab").tag("\t")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 滑块最右端表示铺满（存储为 0）。
    private var lineWidth: Binding<Double> {
        Binding(
            get: { model.settings.lineWidth == 0 ? 100 : model.settings.lineWidth },
            set: { model.settings.lineWidth = $0 >= 100 ? 0 : $0 }
        )
    }

    private static func em(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) em" : String(format: "%g em", value)
    }
}

/// 设置 → 格式 → 自定义字体：从文件导入，或给一个字体族名 / Google Fonts 地址。
private struct CustomFontsSection: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var failure: String?

    var body: some View {
        let store = model.customFonts

        Section {
            ForEach(store.fonts) { font in
                LabeledContent {
                    Button {
                        store.remove(font)
                    } label: {
                        Image.interfaceSymbol("trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Remove \(font.familyName)"))
                } label: {
                    HStack(spacing: Space.s3) {
                        Text(verbatim: font.familyName)
                            .font(Font(AppSettings.font(family: font.familyName, size: TextSize.base)))
                        Text(verbatim: Self.fileSize(font.byteCount))
                            .font(.system(size: TextSize.sm))
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }

            HStack(spacing: Space.s2) {
                TextField("Font family or address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { download() }
                Button("Get", action: download)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || store.isDownloading)
                if store.isDownloading {
                    ProgressView().controlSize(.small)
                }
            }

            HStack {
                Spacer()
                Button("Import Font File…", action: importFromFile)
                Spacer()
            }

            if let failure {
                Text(verbatim: failure)
                    .font(.system(size: TextSize.sm))
                    .foregroundStyle(Color.statusError)
            }
        } header: {
            Text("Custom fonts")
        } footer: {
            Text("Imported fonts are available to LiteMD only — they are not installed system-wide. For Chinese, Japanese and Korean families, import the font file itself: web font services only deliver the Latin part.")
                .font(.system(size: TextSize.sm))
                .foregroundStyle(Color.textSecondary)
        }
    }

    private func importFromFile() {
        let urls = SystemIntegration.chooseFonts()
        guard !urls.isEmpty else { return }

        failure = nil
        for url in urls {
            do {
                try model.customFonts.importFont(from: url)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func download() {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        failure = nil
        Task {
            do {
                try await model.customFonts.importFont(fromWebAddress: input)
                address = ""
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private static func fileSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct SliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: Space.s3) {
                Slider(value: $value, in: range, step: step)
                    .labelsHidden()
                Text(verbatim: label(value))
                    .font(.system(size: TextSize.sm).monospacedDigit())
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: Space.s16, alignment: .leading)
            }
            .frame(maxWidth: Layout.formatSliderWidth)
        }
    }
}

private struct FontPickerRow: View {
    enum Kind {
        case text
        case heading
        case code
    }

    @Environment(AppModel.self) private var model

    let title: LocalizedStringKey
    @Binding var selection: String
    let kind: Kind

    var body: some View {
        // 读一下导入的字体：导入或删除后这一行要跟着刷新。
        let imported = model.customFonts.fonts.map(\.familyName)

        LabeledContent(title) {
            Menu {
                switch kind {
                case .heading:
                    fontButton(String(localized: "Same as Text"), family: "")
                case .text:
                    fontButton(String(localized: "System Font"), family: "")
                    fontButton(String(localized: "System Serif"), family: "serif")
                    fontButton(String(localized: "System Monospaced"), family: "mono")
                case .code:
                    fontButton(String(localized: "System Monospaced"), family: "")
                }
                if !imported.isEmpty {
                    Divider()
                    Section(String(localized: "Custom fonts")) {
                        ForEach(imported, id: \.self) { family in
                            fontButton(family, family: family)
                        }
                    }
                }
                Divider()
                ForEach(kind == .code ? FontCatalog.monospacedFamilies : FontCatalog.families, id: \.self) { family in
                    fontButton(family, family: family)
                }
            } label: {
                Text(verbatim: displayName)
                    .font(Font(previewFont))
                    .lineLimit(1)
            }
            .fixedSize()
        }
    }

    private func fontButton(_ title: String, family: String) -> some View {
        Button {
            selection = family
        } label: {
            if selection == family {
                Label(title, systemImage: "checkmark")
            } else {
                Text(verbatim: title)
            }
        }
    }

    private var displayName: String {
        switch (kind, selection) {
        case (.heading, ""): String(localized: "Same as Text")
        case (.code, ""): String(localized: "System Monospaced")
        case (_, ""): String(localized: "System Font")
        case (_, "serif"): String(localized: "System Serif")
        case (_, "mono"): String(localized: "System Monospaced")
        default: selection
        }
    }

    private var previewFont: NSFont {
        let size = TextSize.sm
        switch kind {
        case .code:
            return selection.isEmpty
                ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                : AppSettings.font(family: selection, size: size)
        case .heading:
            let base = AppSettings.font(family: selection, size: size)
            return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        case .text:
            return AppSettings.font(family: selection, size: size)
        }
    }
}

/// 可用字体族（按名称排序）。导入字体会注册进本进程，因此缓存要能失效。
@MainActor
enum FontCatalog {
    private static var cachedFamilies: [String]?
    private static var cachedMonospaced: [String]?

    static var families: [String] {
        if let cachedFamilies { return cachedFamilies }
        let all = NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        cachedFamilies = all
        return all
    }

    static var monospacedFamilies: [String] {
        if let cachedMonospaced { return cachedMonospaced }
        let mono = families.filter { family in
            guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
            return font.isFixedPitch || NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask)
        }
        cachedMonospaced = mono
        return mono
    }

    /// 导入或删除字体后调用：`NSFontManager` 的字体族列表变了。
    static func invalidate() {
        cachedFamilies = nil
        cachedMonospaced = nil
    }
}
