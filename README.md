<div align="center">

# LiteMD

**A lightweight Markdown editor, native to macOS.**

[litemd.app](https://litemd.app) · [中文说明](README.zh-CN.md)

[![Download](https://img.shields.io/badge/download-0.1.1-2563EB)](https://litemd.app)
[![Platform](https://img.shields.io/badge/macOS-15%2B-111827)](https://litemd.app)
[![Universal](https://img.shields.io/badge/binary-universal-111827)](https://litemd.app)
[![License](https://img.shields.io/badge/license-MIT-12853C)](LICENSE)

</div>

LiteMD renders as you write, ships with 20 color themes, and converts other
document formats in and out of Markdown without asking you to install anything
else. It is written in Swift and AppKit — no Electron, no bundled Python
runtime, 18 MB installed.

Your files stay as plain `.md` in a folder you choose. No proprietary format,
no database, nothing to export when you want to leave.

## Features

**Live preview.** Headings, links, code and formulas take shape right in the
editor. Split the window when you want source and rendered output side by side.
KaTeX, syntax highlighting (highlight.js) and Mermaid diagrams ship inside the
app and render offline.

**20 color themes.** Ten light, ten dark. Pick one for light mode and one for
dark, and the app's own appearance follows. Separate fonts for body, headings
and code, with sliders for size, line height, line width, paragraph spacing and
indent.

**Bring your own fonts.** Import a font file (`.ttf`, `.otf`, `.ttc`, `.woff`,
`.woff2`), or paste a family name or Google Fonts address and LiteMD fetches it.
Imported fonts are registered to the app's own process — never installed
system-wide — and the preview uses them too.

**A folder is the workspace.** Open any folder and start writing. The sidebar is
the real directory tree, with `[[wiki links]]`, an outline, full-text search and
a command palette.

**History and backup.** Earlier versions are kept locally so you can always go
back. Backup points at your own S3-compatible storage, with credentials in the
system keychain and nothing in between.

**Conversion, built in.**

| Into Markdown | Out of Markdown |
| --- | --- |
| Word `.docx` `.doc` · PowerPoint `.pptx` · Excel `.xlsx` | HTML · PDF · Word `.docx` |
| EPUB · PDF · HTML · OpenDocument · Rich Text | EPUB · Rich Text · OpenDocument |
| CSV / TSV · JSON / XML | LaTeX · Plain text |

Text inside images is extracted with the system's on-device recognition
(Chinese, English, Japanese, Korean); recordings are transcribed locally. Audio
and documents never leave your Mac.

**Details that add up.** Focus mode, typewriter scrolling, a formatting bar,
pasted images saved next to the document with relative links, four app icons,
and an interface in English and Simplified Chinese.

## Install

With [Homebrew](https://brew.sh):

```bash
brew tap gentpan/tap
brew install --cask litemd
```

Or download the signed and notarized disk image from
[litemd.app](https://litemd.app) or the
[releases page](https://github.com/gentpan/LiteMD/releases), open it and drag
LiteMD to Applications.

Requires macOS 15 or later. Universal binary — Apple silicon and Intel.

## Build from source

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated from `project.yml` and
is not checked in.

```bash
git clone https://github.com/gentpan/LiteMD.git
cd LiteMD
xcodegen generate
xcodebuild -project LiteMD.xcodeproj -scheme LiteMD -configuration Debug build
```

Or open `LiteMD.xcodeproj` after generating it and run from Xcode.

Packaging a signed release is documented in [docs/RELEASING.md](docs/RELEASING.md).

## Project layout

```
Apps/macOS/LiteMD      macOS app: windows, editor, preview, settings
Packages/LiteMDKit     Shared core, one target per concern:
  LiteMDDomain           documents, themes, settings
  LiteMDEditor           text engine and syntax highlighting
  LiteMDMarkdown         parsing (swift-markdown, CommonMark + GFM)
  LiteMDConversion       import and export
  LiteMDBackup           S3-compatible backup
  LiteMDUpdates          signed in-app updates
  LiteMDInfrastructure   file system, persistence
  LiteMDApplication      services shared by the UI layer
site/                  The litemd.app website
scripts/               Release, signing and asset scripts
```

## In-app updates

Update manifests are signed with Ed25519 and verified before anything is
installed. LiteMD only downloads from the address in its own manifest, and after
unpacking it re-checks the bundle identifier, version, code signature and team
identifier against the running app. Builds without an update feed configured
(local debug builds, for instance) never check for updates.

## Third-party components

| Component | License |
| --- | --- |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Apache-2.0 |
| [KaTeX](https://katex.org) | MIT |
| [highlight.js](https://highlightjs.org) | BSD-3-Clause |
| [Mermaid](https://mermaid.js.org) | MIT |
| [Philosopher](https://fonts.google.com/specimen/Philosopher) (wordmark) | SIL OFL 1.1 |

The preview libraries are bundled with the app so that math, syntax
highlighting and diagrams render without a network connection. Their license
files sit next to them in `Apps/macOS/LiteMD/Resources/PreviewLibraries/`.

## License

[MIT](LICENSE)
