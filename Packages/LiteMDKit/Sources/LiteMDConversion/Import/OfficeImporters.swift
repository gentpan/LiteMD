import Foundation

/// PowerPoint（.pptx）→ Markdown：每页一个二级标题，正文为列表，含表格、图片与演讲者备注。
public struct PptxImporter: Sendable {
    public init() {}

    public func convert(_ data: Data, options: ImportOptions = ImportOptions()) throws(ConversionError) -> ConversionResult {
        let archive = try ZipArchive(data: data)
        let presentationPath = "ppt/presentation.xml"
        let presentation = try XMLTree.parse(try archive.data(for: presentationPath))
        let relationships = Relationships.load(for: presentationPath, in: archive)
        let assets = AssetCollector(options: options)

        var slidePaths: [String] = presentation.descendants("p:sldId").compactMap { slide in
            guard let id = slide["r:id"], let relationship = relationships.byID[id] else { return nil }
            return ZipArchive.resolve(relationship.target, relativeTo: presentationPath)
        }
        if slidePaths.isEmpty {
            slidePaths = archive.orderedPaths
                .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        var blocks: [String] = []
        for (index, slidePath) in slidePaths.enumerated() {
            guard let slideData = try? archive.data(for: slidePath), let slide = try? XMLTree.parse(slideData) else { continue }
            let slideRelationships = Relationships.load(for: slidePath, in: archive)
            blocks.append(contentsOf: convertSlide(slide, number: index + 1, path: slidePath, relationships: slideRelationships, archive: archive, assets: assets))
        }

        let markdown = MarkdownComposer.joinBlocks(blocks)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionError.empty }
        return ConversionResult(markdown: markdown, assets: assets.assets)
    }

    private func convertSlide(_ slide: XElement, number: Int, path: String, relationships: Relationships, archive: ZipArchive, assets: AssetCollector) -> [String] {
        guard let tree = slide.firstDescendant("p:spTree") else { return [] }
        var title: String?
        var body: [String] = []

        for shape in tree.descendants("p:sp") {
            let placeholder = shape.firstDescendant("p:ph")?["type"]
            let paragraphs = (shape.child("p:txBody")?.children("a:p") ?? []).map(paragraphText)
            let lines = paragraphs.filter { !$0.text.isEmpty }
            guard !lines.isEmpty else { continue }

            if title == nil, placeholder == "title" || placeholder == "ctrTitle" {
                title = lines.map(\.text).joined(separator: " ")
                continue
            }
            let isBulleted = placeholder == nil || placeholder == "body" || placeholder == "obj" || placeholder == "subTitle"
            let rendered = lines.map { line -> String in
                if isBulleted, lines.count > 1 || line.level > 0 {
                    return String(repeating: "    ", count: line.level) + "- " + line.text
                }
                return MarkdownComposer.escapeLineStart(line.text)
            }
            body.append(rendered.joined(separator: rendered.first?.hasPrefix("-") == true || rendered.first?.hasPrefix(" ") == true ? "\n" : "\n\n"))
        }

        for frame in tree.descendants("p:graphicFrame") {
            guard let table = frame.firstDescendant("a:tbl") else { continue }
            let rows = table.children("a:tr").map { row in
                row.children("a:tc").map { cell in
                    cell.descendants("a:p").map { paragraphText($0).text }.filter { !$0.isEmpty }.joined(separator: "<br>")
                }
            }
            body.append(MarkdownComposer.table(rows))
        }

        for picture in tree.descendants("p:pic") {
            guard let id = picture.firstDescendant("a:blip")?["r:embed"],
                  let relationship = relationships.byID[id], !relationship.isExternal else { continue }
            let mediaPath = ZipArchive.resolve(relationship.target, relativeTo: path)
            guard let data = try? archive.data(for: mediaPath) else { continue }
            let description = picture.firstDescendant("p:cNvPr")?["descr"] ?? ""
            let markdownPath = assets.add(data, originalName: mediaPath, key: mediaPath)
            body.append("![\(MarkdownComposer.escapeInline(description))](\(MarkdownComposer.destination(markdownPath)))")
        }

        var blocks = ["## " + (title ?? "Slide \(number)")]
        blocks.append(contentsOf: body)

        if let notes = relationships.byID.values.first(where: { $0.type.hasSuffix("/notesSlide") }) {
            let notesPath = ZipArchive.resolve(notes.target, relativeTo: path)
            if let data = try? archive.data(for: notesPath), let root = try? XMLTree.parse(data) {
                let text = root.descendants("p:sp")
                    .filter { $0.firstDescendant("p:ph")?["type"] == "body" }
                    .flatMap { $0.descendants("a:p").map { paragraphText($0).text } }
                    .filter { !$0.isEmpty }
                if !text.isEmpty {
                    blocks.append("> " + text.joined(separator: "\n> "))
                }
            }
        }
        return blocks
    }

    private func paragraphText(_ paragraph: XElement) -> (text: String, level: Int) {
        let level = Int(paragraph.child("a:pPr")?["lvl"] ?? "0") ?? 0
        var pieces: [InlinePiece] = []
        for element in paragraph.elements {
            switch element.name {
            case "a:r", "a:fld":
                let text = element.child("a:t")?.textContent ?? ""
                var piece = InlinePiece.text(text)
                let properties = element.child("a:rPr")
                piece.bold = properties?["b"] == "1"
                piece.italic = properties?["i"] == "1"
                piece.strikethrough = (properties?["strike"] ?? "noStrike") != "noStrike"
                pieces.append(piece)
            case "a:br":
                pieces.append(.markdown("<br>"))
            default:
                continue
            }
        }
        return (MarkdownComposer.render(pieces).trimmingCharacters(in: .whitespaces), level)
    }
}

/// Excel（.xlsx）→ Markdown：每个工作表一个二级标题与一张表格。
public struct XlsxImporter: Sendable {
    public init() {}

    public func convert(_ data: Data, options: ImportOptions = ImportOptions()) throws(ConversionError) -> ConversionResult {
        let archive = try ZipArchive(data: data)
        let workbookPath = "xl/workbook.xml"
        let workbook = try XMLTree.parse(try archive.data(for: workbookPath))
        let relationships = Relationships.load(for: workbookPath, in: archive)
        let sharedStrings = Self.loadSharedStrings(archive)

        var blocks: [String] = []
        for sheet in workbook.descendants("sheet") {
            guard let id = sheet["r:id"], let relationship = relationships.byID[id] else { continue }
            let sheetPath = ZipArchive.resolve(relationship.target, relativeTo: workbookPath)
            guard let sheetData = try? archive.data(for: sheetPath), let root = try? XMLTree.parse(sheetData) else { continue }
            let table = Self.rows(in: root, sharedStrings: sharedStrings)
            guard !table.rows.isEmpty else { continue }
            blocks.append("## " + MarkdownComposer.escapeInline(sheet["name"] ?? "Sheet"))
            blocks.append(MarkdownComposer.table(table.rows.map { $0.map(MarkdownComposer.escapeInline) }))
            if table.isTruncated {
                blocks.append("*Only the first \(table.rows.count) rows and \(table.rows[0].count) columns were imported.*")
            }
        }

        guard !blocks.isEmpty else { throw ConversionError.empty }
        return ConversionResult(markdown: MarkdownComposer.joinBlocks(blocks))
    }

    private static func loadSharedStrings(_ archive: ZipArchive) -> [String] {
        guard let data = try? archive.data(for: "xl/sharedStrings.xml"), let root = try? XMLTree.parse(data) else { return [] }
        return root.children("si").map(richText)
    }

    /// `<si>` / `<is>` 的文字：直接的 `<t>` 与各个 `<r><t>`。`<rPh>` 是注音（例如日文假名），不算正文。
    static func richText(_ element: XElement) -> String {
        var text = element.child("t")?.textContent ?? ""
        for run in element.children("r") {
            text += run.child("t")?.textContent ?? ""
        }
        return text
    }

    /// Excel 的上限：XFD 列、1 048 576 行。
    static let maximumColumnIndex = 16_383
    static let maximumRowIndex = 1_048_575
    /// Markdown 表格要逐格写出，超出这些范围的部分不导入。
    static let importedColumnLimit = 512
    static let importedCellLimit = 500_000

    static func rows(in sheet: XElement, sharedStrings: [String]) -> (rows: [[String]], isTruncated: Bool) {
        var grid: [Int: [Int: String]] = [:]
        for (rowOffset, row) in (sheet.firstDescendant("sheetData")?.children("row") ?? []).enumerated() {
            let declaredRow = Int(row["r"] ?? "").map { $0 - 1 }
            let rowIndex = declaredRow.flatMap { (0...maximumRowIndex).contains($0) ? $0 : nil } ?? rowOffset
            for (cellOffset, cell) in row.children("c").enumerated() {
                // 引用写错（列号超出 XFD、没有字母）的单元格跳过，不猜位置。
                let column: Int? = if let reference = cell["r"] { columnIndex(reference) } else { cellOffset }
                guard let column, column <= maximumColumnIndex else { continue }
                let raw = cell.child("v")?.textContent ?? ""
                let value: String
                switch cell["t"] {
                case "s": value = Int(raw).flatMap { sharedStrings.indices.contains($0) ? sharedStrings[$0] : nil } ?? ""
                case "inlineStr": value = cell.child("is").map(richText) ?? ""
                case "b": value = raw == "1" ? "TRUE" : "FALSE"
                default: value = raw
                }
                if !value.isEmpty {
                    grid[rowIndex, default: [:]][column] = value
                }
            }
        }
        guard let firstRow = grid.keys.min(), let lastRow = grid.keys.max(),
              let lastColumn = grid.values.flatMap(\.keys).max() else { return ([], false) }

        // 表格按行列铺满：A1 与 XFD1048576 各有一个值，也会得到 170 亿个格子，所以要限制范围。
        let columnCount = min(lastColumn + 1, importedColumnLimit)
        let rowCount = min(lastRow - firstRow + 1, max(1, importedCellLimit / columnCount))
        let isTruncated = columnCount <= lastColumn || firstRow + rowCount <= lastRow
        let rows = (firstRow..<(firstRow + rowCount)).map { row in
            (0..<columnCount).map { grid[row]?[$0] ?? "" }
        }
        return (rows, isTruncated)
    }

    /// `AB12` → 27。没有列字母或超出 XFD 时返回 nil。
    static func columnIndex(_ reference: String) -> Int? {
        var index = 0
        for scalar in reference.unicodeScalars {
            guard (65...90).contains(scalar.value) || (97...122).contains(scalar.value) else { break }
            index = index * 26 + Int((scalar.value & 0xDF) - 64)
            // 提前截断，超长的字母串不会让乘法溢出。
            guard index <= maximumColumnIndex + 1 else { return nil }
        }
        return index > 0 ? index - 1 : nil
    }
}

/// CSV / TSV → Markdown 表格。
public struct CsvImporter: Sendable {
    public init() {}

    public func convert(_ text: String) throws(ConversionError) -> ConversionResult {
        let delimiter = Self.detectDelimiter(text)
        let rows = Self.parse(text, delimiter: delimiter).filter { !$0.allSatisfy(\.isEmpty) }
        guard !rows.isEmpty else { throw ConversionError.empty }
        return ConversionResult(markdown: MarkdownComposer.table(rows.map { $0.map(MarkdownComposer.escapeInline) }) + "\n")
    }

    static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" }
        let candidates: [Character] = [",", "\t", ";"]
        return candidates.max { lhs, rhs in
            firstLine.filter { $0 == lhs }.count < firstLine.filter { $0 == rhs }.count
        } ?? ","
    }

    /// RFC 4180：支持引号、转义引号与字段内换行。
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil

        func next() -> Character? {
            if let value = pending {
                pending = nil
                return value
            }
            return iterator.next()
        }

        while let character = next() {
            if inQuotes {
                if character == "\"" {
                    if let following = next() {
                        if following == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = following
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case delimiter:
                row.append(field)
                field = ""
            case "\n", "\r\n", "\r":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
