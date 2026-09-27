import AppKit
import CoreText
import CryptoKit
import Foundation
import LiteMDDomain
import LiteMDInfrastructure
import Observation

/// 用户导入的字体。
///
/// 字体文件复制到 `Application Support/LiteMD/Fonts/`，并且只注册到**本进程**
/// （`CTFontManagerScope.process`）：不写进系统字体库，不影响别的应用，删掉文件就失效。
///
/// 支持 ttf / otf / ttc / woff / woff2 —— woff2 也能直接用，品牌字标就是从 woff2 加载的
/// （见 `BrandFont`）。
@MainActor
@Observable
final class CustomFontStore {
    struct ImportedFont: Identifiable, Hashable, Sendable {
        /// 磁盘上的文件名，同时用作 id 和预览里的资源路径。
        let fileName: String
        let familyName: String
        let byteCount: Int

        var id: String { fileName }
    }

    enum ImportError: LocalizedError {
        case unsupportedFormat(String)
        case notAFont
        case badAddress
        case downloadFailed(Int)
        case noFontInStylesheet

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                String(localized: "“\(ext)” isn’t a font format LiteMD can read. Use .ttf, .otf, .ttc, .woff or .woff2.")
            case .notAFont:
                String(localized: "This file doesn’t contain a font LiteMD can read.")
            case .badAddress:
                String(localized: "Enter a font family name, a Google Fonts address, or a direct link to a font file.")
            case .downloadFailed(let status):
                String(localized: "The download failed (HTTP \(status)).")
            case .noFontInStylesheet:
                String(localized: "No font file was found at that address.")
            }
        }
    }

    nonisolated static let allowedExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "woff", "woff2"]

    /// 预览通过 `litemd-resource://fonts/<文件名>` 读取这个目录。
    nonisolated static let directory: URL = AppDirectories.applicationSupport()
        .appendingPathComponent("Fonts", isDirectory: true)

    private(set) var fonts: [ImportedFont] = []
    /// 正在从网络导入。
    private(set) var isDownloading = false

    /// 已注册的描述符，删除时用来反注册。
    @ObservationIgnored private var registered: [String: [CTFontDescriptor]] = [:]

    /// 字体集合变化时通知外部（刷新字体列表、重新渲染预览）。
    @ObservationIgnored var onChange: (() -> Void)?

    static func url(forFileName fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    func url(for font: ImportedFont) -> URL { Self.url(forFileName: font.fileName) }

    /// 按字体族名找导入的字体（预览需要据此生成 `@font-face`）。
    func font(forFamily family: String) -> ImportedFont? {
        fonts.first { $0.familyName == family }
    }

    // MARK: - 启动加载

    /// 启动时把目录里的字体注册进本进程。
    func loadInstalled() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []

        var loaded: [ImportedFont] = []
        for file in files where Self.allowedExtensions.contains(file.pathExtension.lowercased()) {
            guard let data = try? Data(contentsOf: file),
                  let font = register(data: data, fileURL: file) else { continue }
            loaded.append(font)
        }
        fonts = loaded.sorted { $0.familyName.localizedStandardCompare($1.familyName) == .orderedAscending }
    }

    // MARK: - 从文件导入

    @discardableResult
    func importFont(from source: URL) throws -> ImportedFont {
        let ext = source.pathExtension.lowercased()
        guard Self.allowedExtensions.contains(ext) else { throw ImportError.unsupportedFormat(ext) }

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: source) else { throw ImportError.notAFont }
        return try install(data: data, fileExtension: ext)
    }

    // MARK: - 从网络导入

    /// 接受三种输入：字体族名（如 `Inter`）、Google Fonts 页面或样式表地址、字体文件直链。
    @discardableResult
    func importFont(fromWebAddress input: String) async throws -> [ImportedFont] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.badAddress }

        isDownloading = true
        defer { isDownloading = false }

        let downloads = try await Self.fetchFontFiles(for: trimmed)
        guard !downloads.isEmpty else { throw ImportError.noFontInStylesheet }

        var imported: [ImportedFont] = []
        for download in downloads {
            if let font = try? install(data: download.data, fileExtension: download.fileExtension) {
                imported.append(font)
            }
        }
        guard !imported.isEmpty else { throw ImportError.notAFont }
        return imported
    }

    // MARK: - 删除

    func remove(_ font: ImportedFont) {
        let url = url(for: font)
        if let descriptors = registered.removeValue(forKey: font.fileName) {
            CTFontManagerUnregisterFontDescriptors(descriptors as CFArray, .process, nil)
        }
        var error: Unmanaged<CFError>?
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &error)
        try? FileManager.default.removeItem(at: url)
        fonts.removeAll { $0.id == font.id }
        onChange?()
    }

    // MARK: - 安装与注册

    private func install(data: Data, fileExtension: String) throws -> ImportedFont {
        guard let familyName = Self.familyName(in: data) else { throw ImportError.notAFont }

        // 同一份文件重复导入时不再写一遍。
        let digest = SHA256.hash(data: data).prefix(4).hexString
        let fileName = "\(Self.sanitize(familyName))-\(digest).\(fileExtension)"
        if let existing = fonts.first(where: { $0.fileName == fileName }) { return existing }

        let destination = Self.url(forFileName: fileName)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)

        guard let font = register(data: data, fileURL: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.notAFont
        }

        fonts.removeAll { $0.id == font.id }
        fonts.append(font)
        fonts.sort { $0.familyName.localizedStandardCompare($1.familyName) == .orderedAscending }
        onChange?()
        return font
    }

    /// 注册到本进程。常规字体文件走 URL 注册（字体族随即出现在 `NSFontManager` 里），
    /// woff / woff2 走描述符注册。
    private func register(data: Data, fileURL: URL) -> ImportedFont? {
        guard let familyName = Self.familyName(in: data) else { return nil }
        let byteCount = data.count

        if !Self.allowedExtensions.contains(fileURL.pathExtension.lowercased()) { return nil }

        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error) {
            return ImportedFont(fileName: fileURL.lastPathComponent, familyName: familyName, byteCount: byteCount)
        }
        // 已经注册过不算失败。
        if let cfError = error?.takeRetainedValue(),
           CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue {
            return ImportedFont(fileName: fileURL.lastPathComponent, familyName: familyName, byteCount: byteCount)
        }

        // URL 注册不接受的格式（woff / woff2）：从数据建描述符再注册。
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              !descriptors.isEmpty else { return nil }
        CTFontManagerRegisterFontDescriptors(descriptors as CFArray, .process, true, nil)
        registered[fileURL.lastPathComponent] = descriptors
        return ImportedFont(fileName: fileURL.lastPathComponent, familyName: familyName, byteCount: byteCount)
    }

    private nonisolated static func familyName(in data: Data) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
    }

    private nonisolated static func sanitize(_ name: String) -> String {
        let allowed = name.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        return String(allowed).replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - 网络

    private struct Download: Sendable {
        let data: Data
        let fileExtension: String
    }

    /// Google Fonts 有两套接口：`css2` 按 unicode-range 切片投递（中日韩字体会切成上百片，
    /// 桌面端拿到的每一片都只有部分字形），`css`（v1）在非浏览器 UA 下返回整份 TTF。
    /// 所以这里走 v1。
    private nonisolated static func fetchFontFiles(for input: String) async throws -> [Download] {
        let stylesheet: URL
        if let url = URL(string: input), url.scheme == "http" || url.scheme == "https" {
            if Self.allowedExtensions.contains(url.pathExtension.lowercased()) {
                return [try await download(url)]
            } else if let family = googleFamily(in: url) {
                stylesheet = try googleStylesheetURL(family: family)
            } else if url.host()?.contains("fonts.googleapis.com") == true {
                stylesheet = url
            } else {
                throw ImportError.badAddress
            }
        } else if input.contains("/") || input.contains(":") {
            throw ImportError.badAddress
        } else {
            // 直接写字体族名，例如 “Inter”。
            stylesheet = try googleStylesheetURL(family: input)
        }

        let css = try await downloadText(stylesheet)
        var results: [Download] = []
        for url in fontURLs(inStylesheet: css) {
            if let file = try? await download(url) { results.append(file) }
        }
        return results
    }

    private nonisolated static func googleFamily(in url: URL) -> String? {
        guard url.host()?.contains("fonts.google.com") == true else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let index = parts.firstIndex(of: "specimen"), index + 1 < parts.count else { return nil }
        return parts[index + 1].replacingOccurrences(of: "+", with: " ")
    }

    private nonisolated static func googleStylesheetURL(family: String) throws -> URL {
        var components = URLComponents(string: "https://fonts.googleapis.com/css")
        // `:400,700` 同时取常规与粗体；字重不存在时 Google 会忽略多余的那个。
        components?.queryItems = [URLQueryItem(name: "family", value: "\(family):400,700")]
        guard let url = components?.url else { throw ImportError.badAddress }
        return url
    }

    private nonisolated static func fontURLs(inStylesheet css: String) -> [URL] {
        // src: url(https://fonts.gstatic.com/....ttf) format('truetype');
        let pattern = /url\((?<link>https?:\/\/[^)"']+)\)/
        var seen = Set<String>()
        var urls: [URL] = []
        for match in css.matches(of: pattern) {
            let link = String(match.link)
            guard seen.insert(link).inserted, let url = URL(string: link) else { continue }
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            urls.append(url)
        }
        return urls
    }

    private nonisolated static func download(_ url: URL) async throws -> Download {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ImportError.downloadFailed(http.statusCode)
        }
        let ext = url.pathExtension.lowercased()
        return Download(data: data, fileExtension: allowedExtensions.contains(ext) ? ext : "ttf")
    }

    private nonisolated static func downloadText(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ImportError.downloadFailed(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ImportError.noFontInStylesheet }
        return text
    }
}
