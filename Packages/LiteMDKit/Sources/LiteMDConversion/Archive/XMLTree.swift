import Foundation
import LiteMDMarkdown

/// 轻量 XML 树（基于 XMLParser，iOS / macOS 通用）。元素名保留命名空间前缀，例如 `w:p`。
public final class XElement: @unchecked Sendable {
    public enum Child {
        case element(XElement)
        case text(String)
    }

    public let name: String
    public var attributes: [String: String]
    public private(set) var children: [Child] = []

    public init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    /// 去掉命名空间前缀后的名称（小写），HTML / XHTML 转换使用。
    public var localName: String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    public var elements: [XElement] {
        children.compactMap { child in
            if case .element(let element) = child { return element }
            return nil
        }
    }

    public func append(_ child: Child) {
        if case .text(let text) = child, case .text(let previous)? = children.last {
            children[children.count - 1] = .text(previous + text)
        } else {
            children.append(child)
        }
    }

    public subscript(attribute: String) -> String? {
        attributes[attribute]
    }

    /// 按名称（含前缀）查找直接子元素。
    public func child(_ name: String) -> XElement? {
        elements.first { $0.name == name }
    }

    public func children(_ name: String) -> [XElement] {
        elements.filter { $0.name == name }
    }

    /// 深度优先查找所有后代元素。
    public func descendants(_ name: String) -> [XElement] {
        var result: [XElement] = []
        var stack = elements.reversed() as [XElement]
        while let element = stack.popLast() {
            if element.name == name { result.append(element) }
            stack.append(contentsOf: element.elements.reversed())
        }
        return result
    }

    public func firstDescendant(_ name: String) -> XElement? {
        var stack = elements.reversed() as [XElement]
        while let element = stack.popLast() {
            if element.name == name { return element }
            stack.append(contentsOf: element.elements.reversed())
        }
        return nil
    }

    /// 所有后代文本拼接。
    public var textContent: String {
        children.map { child in
            switch child {
            case .text(let text): text
            case .element(let element): element.textContent
            }
        }.joined()
    }
}

public enum XMLTree {
    public static func parse(_ data: Data) throws(ConversionError) -> XElement {
        let delegate = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = delegate.root else {
            let message = parser.parserError?.localizedDescription ?? "Invalid XML"
            throw ConversionError.corrupted(message)
        }
        return root
    }

    /// XML 转义（元素内容与属性通用），与 HTML 输出共用同一份规则，包括丢弃 XML 不允许的控制字符。
    public static func escape(_ value: String) -> String {
        HTMLEscaping.attribute(value)
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: XElement?
    private var stack: [XElement] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let element = XElement(name: qualifiedName ?? elementName, attributes: attributes)
        if let parent = stack.last {
            parent.append(.element(element))
        } else {
            root = element
        }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.append(.text(string))
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.append(.text(String(decoding: CDATABlock, as: UTF8.self)))
    }
}

public enum ConversionError: Error, Equatable, Sendable {
    case unsupported(String)
    case corrupted(String)
    case missingPart(String)
    case empty

    public var details: String {
        switch self {
        case .unsupported(let detail): "Unsupported: \(detail)"
        case .corrupted(let detail): "Corrupted: \(detail)"
        case .missingPart(let part): "Missing part: \(part)"
        case .empty: "No convertible content"
        }
    }
}
