<p align="right">
  <strong>English</strong> · <a href="README.ko.md">Korean</a>
</p>

# mdair — Markdown Air Previewer

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13.0+-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 13.0+">
  <a href="https://github.com/tykimos/mdair/releases"><img src="https://img.shields.io/github/v/release/tykimos/mdair?style=for-the-badge" alt="GitHub release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/Swift-5.9-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/Objective--C-blue?style=for-the-badge" alt="Objective-C">
</p>

<p align="center">
  <strong>Breathe life into your Markdown files — preview them instantly in Finder.</strong>
</p>

<p align="center">
  <a href="#features">Features</a> · <a href="#installation">Installation</a> · <a href="#build-from-source">Build</a> · <a href="#how-it-works">How it works</a> · <a href="#license">License</a>
</p>

---

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/mdair-preview-dark.png">
    <img src="docs/assets/mdair-preview.png" alt="mdair preview" width="700">
  </picture>
</p>

**mdair** is a lightweight macOS app that brings native QuickLook preview to Markdown files. Just press `Space` on any `.md` file in Finder to see a beautifully rendered preview — no extra app needed.

## Features

| Feature | Description |
|---------|-------------|
| **QuickLook Integration** | Press `Space` in Finder to preview `.md` files instantly |
| **Standalone Viewer** | Double-click or drag `.md` files to open in a dedicated window |
| **Window Tabs** | Open multiple documents as native macOS tabs in a single window |
| **Dark Mode** | Automatic light/dark theme matching your system preference |
| **Rich Markdown** | Headings, lists, tables, code blocks, blockquotes, checkboxes, images, links |
| **Zero Dependencies** | Pure native macOS — no Electron, no Node.js, no frameworks |
| **Small Footprint** | About 8MB installed, mostly the bundled Mermaid library |
| **Zoom** | Zoom in/out with `⌘+`/`⌘-` or trackpad pinch gestures |
| **Copy** | Select text and `⌘C` to copy — a toast confirms the action |
| **Edit Menu** | Standard Cut/Copy/Paste/Undo/Redo shortcuts |
| **Export** | Export to `.mdair` or PDF from the File menu |
| **Image Inlining** | Local images embedded as data URIs when opened with mdair.app |

### Window Tabs

<p align="center">
  <img src="docs/assets/mdair-tabs.png" alt="Multiple documents open as window tabs" width="700">
</p>

Open several documents at once and they group into a single window as native macOS tabs. Switch with `⌘⇧[` / `⌘⇧]`, and use the **Window** menu to *Merge All Windows* or *Move Tab to New Window*. `⌘W` closes just the active tab.

### Zoom In / Out

<p align="center">
  <img src="docs/assets/mdair-zoom.gif" alt="Zoom in/out demo" width="700">
</p>

### Copy with Toast Feedback

<p align="center">
  <img src="images/copy_function.jpg" alt="Copy text with cmd+C" width="700">
</p>

Select any text in a preview window and press `⌘C` to copy. A subtle toast appears in the top-right corner to confirm the copy action.

### Export to .mdair or PDF

Open **File** → **Export as .mdair…** to bundle the current Markdown document together with all referenced images into a single `.mdair` archive.

Open **File** → **Export as PDF…** to render the current view as a PDF using WebKit's native PDF engine — preserves dark/light theme and zoom level.

## Installation

### Download

Grab the latest release from the [Releases](https://github.com/tykimos/mdair/releases) page:

- **`mdair.pkg`** — Double-click to install (recommended)
- **`mdair.dmg`** — Open and run the PKG installer inside

### Bypassing Gatekeeper

Since mdair is not signed with an Apple Developer ID, macOS may block the installer. To open it:

1. **Right-click** `mdair.pkg` → select **Open** → click **Open** in the dialog
2. Or go to **System Settings → Privacy & Security** → click **Open Anyway**

### After Installation

The QuickLook extension activates automatically. Navigate to any `.md` file in Finder and press `Space` to preview.

### macOS Configuration

#### Enable Single-Click QuickLook (Finder Settings)

By default, you need to press `Space` to trigger QuickLook. To show previews automatically when selecting a file:

1. Open **Finder** → **Settings** (or press `⌘,`)
2. Go to the **General** tab
3. Check **"Show preview in Quick Look"** (available on macOS Ventura and later)

Alternatively, enable it via Terminal:

```bash
defaults write com.apple.finder QLEnableTextSelection -bool true
defaults write com.apple.finder QLInlinePreviewMinimumSupportedSize -int 0
killall Finder
```

#### Set mdair as the Default App for `.md` Files

To open all Markdown files with mdair by default:

1. **Right-click** any `.md` file in Finder
2. Select **Get Info** (or press `⌘I`)
3. Under **Open with**, select **mdair** from the dropdown
4. Click **Change All...** → confirm with **Continue**

This makes mdair the default viewer for all `.md` files.

#### Verify QuickLook Extension is Active

If QuickLook preview doesn't work after installation:

1. Go to **System Settings → Extensions → Quick Look**
2. Make sure **QLMarkdownPreview** is checked
3. If it doesn't appear, try restarting Finder:

```bash
killall Finder
```

## Build from Source

Requires Xcode Command Line Tools on macOS 13.0+.

```bash
# Build the app
./scripts/build.sh

# Create installer (optional)
./scripts/create-pkg.sh
./scripts/create-dmg.sh
```

The built app is at `build/mdair.app`. Copy it to `/Applications/` to install manually.

## How it works

mdair consists of two components:

1. **mdair.app** — A standalone Markdown viewer built with Cocoa + WebKit
2. **QLMarkdownPreview.appex** — A QuickLook Preview Extension bundled inside the app

The Markdown-to-HTML rendering is implemented natively in Objective-C and Swift — no external libraries required. Styling adapts to macOS light/dark mode using CSS `prefers-color-scheme`.

## Supported Formats

`.md` `.markdown` `.mdown` `.mkd` `.mkdn` `.mdwn` `.mdtxt` `.mdtext`

## License

[MIT](LICENSE) &copy; 2026 tykimos

Bundles [Mermaid](https://github.com/mermaid-js/mermaid) 11.17.2 (MIT) so diagrams render offline and in QuickLook. See [`resources/mermaid-LICENSE.txt`](resources/mermaid-LICENSE.txt).
