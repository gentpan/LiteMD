// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LiteMDKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "LiteMDDomain", targets: ["LiteMDDomain"]),
        .library(name: "LiteMDEditor", targets: ["LiteMDEditor"]),
        .library(name: "LiteMDMarkdown", targets: ["LiteMDMarkdown"]),
        .library(name: "LiteMDInfrastructure", targets: ["LiteMDInfrastructure"]),
        .library(name: "LiteMDApplication", targets: ["LiteMDApplication"]),
        .library(name: "LiteMDConversion", targets: ["LiteMDConversion"]),
        .library(name: "LiteMDBackup", targets: ["LiteMDBackup"]),
        .library(name: "LiteMDUpdates", targets: ["LiteMDUpdates"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
    ],
    targets: [
        // 最纯净的一层：模型、状态、协议。不依赖任何 UI 框架。
        .target(name: "LiteMDDomain"),

        // TextBuffer、Selection、EditorCommand 与文本变换。
        .target(name: "LiteMDEditor", dependencies: ["LiteMDDomain"]),

        // Parser、统计、语法高亮区间、HTML 渲染。只做 Text -> Metadata。
        .target(
            name: "LiteMDMarkdown",
            dependencies: [
                "LiteMDDomain",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),

        // 本地文件系统、Recovery 存储、应用状态存储的具体实现。
        .target(name: "LiteMDInfrastructure", dependencies: ["LiteMDDomain"]),

        // DocumentService、SaveCoordinator、Autosave、Workspace、Search、Assets。
        // 只依赖 Domain 协议，具体实现由 App 注入。
        .target(name: "LiteMDApplication", dependencies: ["LiteMDDomain", "LiteMDEditor"]),

        // 内置格式转换：DOCX / PPTX / XLSX / EPUB / HTML / CSV → Markdown，Markdown → DOCX / EPUB / LaTeX。
        // 纯 Swift 实现（ZIP + XML），不依赖任何外部工具。
        .target(
            name: "LiteMDConversion",
            dependencies: [
                "LiteMDDomain",
                "LiteMDMarkdown",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),

        // 单向备份到 S3 兼容对象存储（SigV4 签名、增量上传）。
        .target(name: "LiteMDBackup", dependencies: ["LiteMDDomain"]),

        // 应用更新：更新源解析、版本比较、Ed25519 签名校验。
        .target(name: "LiteMDUpdates"),

        .testTarget(name: "LiteMDDomainTests", dependencies: ["LiteMDDomain"]),
        .testTarget(name: "LiteMDBackupTests", dependencies: ["LiteMDBackup", "LiteMDDomain"]),
        .testTarget(name: "LiteMDUpdatesTests", dependencies: ["LiteMDUpdates"]),
        .testTarget(
            name: "LiteMDConversionTests",
            dependencies: ["LiteMDConversion", "LiteMDMarkdown"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "LiteMDEditorTests", dependencies: ["LiteMDEditor"]),
        .testTarget(name: "LiteMDMarkdownTests", dependencies: ["LiteMDMarkdown"]),
        .testTarget(name: "LiteMDInfrastructureTests", dependencies: ["LiteMDInfrastructure"]),
        .testTarget(
            name: "LiteMDApplicationTests",
            dependencies: ["LiteMDApplication", "LiteMDInfrastructure", "LiteMDMarkdown"]
        ),
    ]
)
