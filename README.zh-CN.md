<div align="center">

# LiteMD

**为 macOS 而生的轻量 Markdown 编辑器。**

[litemd.app](https://litemd.app) · [English](README.md)

[![下载](https://img.shields.io/badge/%E4%B8%8B%E8%BD%BD-0.1.1-2563EB)](https://litemd.app)
[![系统](https://img.shields.io/badge/macOS-15%2B-111827)](https://litemd.app)
[![架构](https://img.shields.io/badge/%E9%80%9A%E7%94%A8%E4%BA%8C%E8%BF%9B%E5%88%B6-universal-111827)](https://litemd.app)
[![许可证](https://img.shields.io/badge/license-MIT-12853C)](LICENSE)

</div>

LiteMD 边写边渲染，自带 20 套配色，导入导出都内置，不需要你先去装别的工具。
用 Swift 和 AppKit 写成——没有 Electron，不捆绑 Python 运行时，整个应用 18 MB。

文件始终是你文件夹里的普通 `.md`。没有专有格式，没有数据库，想走随时可以拿走。

## 功能

**实时预览。** 标题、链接、代码、公式在编辑区里直接成形，要并排对照时切到分栏。
KaTeX 公式、代码高亮（highlight.js）和 Mermaid 图表随应用打包，断网也能渲染。

**20 套配色。** 10 套浅色、10 套深色，浅色模式和深色模式各挑一套，应用外观跟着走。
正文、标题、代码三种字体，字号、行高、行宽、段落间距与缩进逐项可调。

**自己的字体也能用。** 导入字体文件（`.ttf`、`.otf`、`.ttc`、`.woff`、`.woff2`），
或者填一个字体族名、Google Fonts 地址让 LiteMD 去取。导入的字体只注册到应用自己的进程，
不会安装到系统里，预览也会同步用上。

**文件夹就是工作区。** 打开任意文件夹就能开始写。侧栏是真实的目录树，
`[[Wiki 链接]]`、大纲、全文搜索和命令面板都在手边。

**版本历史与备份。** 本地保留历史版本，写错了随时翻回去。备份指向你自己的 S3 兼容存储，
访问凭据存在系统钥匙串里，不经过任何中间服务。

**格式转换内置。**

| 变成 Markdown | 从 Markdown 导出 |
| --- | --- |
| Word `.docx` `.doc` · PowerPoint `.pptx` · Excel `.xlsx` | HTML · PDF · Word `.docx` |
| EPUB · PDF · 网页 · OpenDocument · 富文本 | EPUB · 富文本 · OpenDocument |
| CSV / TSV · JSON / XML | LaTeX · 纯文本 |

图片里的文字用系统的本机文字识别提取（中英日韩），录音用本机语音识别转成文稿。
音频和文档都不会离开你的 Mac。

**还有一些小事。** 专注模式、打字机滚动、格式工具栏、粘贴的图片自动存到文档旁边并写成相对路径、
四个应用图标，界面支持英文与简体中文。

## 安装

用 [Homebrew](https://brew.sh)：

```bash
brew tap gentpan/tap
brew install --cask litemd
```

或者到 [litemd.app](https://litemd.app) 或
[发布页](https://github.com/gentpan/LiteMD/releases) 下载已签名并公证的磁盘映像，
打开后把 LiteMD 拖进「应用程序」。

需要 macOS 15 或更高版本。通用二进制，Apple 芯片与 Intel 都支持。

## 从源码构建

需要 Xcode 16 及以上和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)
（`brew install xcodegen`）。Xcode 工程由 `project.yml` 生成，不入库。

```bash
git clone https://github.com/gentpan/LiteMD.git
cd LiteMD
xcodegen generate
xcodebuild -project LiteMD.xcodeproj -scheme LiteMD -configuration Debug build
```

也可以生成工程后直接打开 `LiteMD.xcodeproj`，在 Xcode 里运行。

打包签名版本的流程见 [docs/RELEASING.md](docs/RELEASING.md)。

## 目录结构

```
Apps/macOS/LiteMD      macOS 应用：窗口、编辑器、预览、设置
Packages/LiteMDKit     共享核心，按职责分 target：
  LiteMDDomain           文档、主题、设置
  LiteMDEditor           文本引擎与语法高亮
  LiteMDMarkdown         解析（swift-markdown，CommonMark + GFM）
  LiteMDConversion       导入与导出
  LiteMDBackup           S3 兼容备份
  LiteMDUpdates          带签名的应用内更新
  LiteMDInfrastructure   文件系统与持久化
  LiteMDApplication      界面层共用的服务
site/                  litemd.app 官网
scripts/               发布、签名与资源脚本
```

## 应用内更新

更新清单带 Ed25519 签名，校验通过才会安装。LiteMD 只从自己清单里写明的地址下载，
解压后还会比对 Bundle ID、版本号、代码签名和开发者团队是否与当前应用一致。
没有配置更新源的构建（比如本地调试版）不会检查更新。

## 第三方组件

| 组件 | 许可证 |
| --- | --- |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Apache-2.0 |
| [KaTeX](https://katex.org) | MIT |
| [highlight.js](https://highlightjs.org) | BSD-3-Clause |
| [Mermaid](https://mermaid.js.org) | MIT |
| [Philosopher](https://fonts.google.com/specimen/Philosopher)（字标） | SIL OFL 1.1 |

预览用的库随应用打包，这样公式、代码高亮和图表不联网也能渲染。
各自的许可证文件就放在 `Apps/macOS/LiteMD/Resources/PreviewLibraries/` 旁边。

## 许可证

[MIT](LICENSE)
