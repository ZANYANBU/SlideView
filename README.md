# SlideView

A native macOS viewer for lecture slides. Opens `.pptx` / `.ppt` / `.pdf` / `.docx`
full-screen with a smart dark mode, built for long revision sessions.

**Install:** `./build.sh` → `~/Applications/SlideView.app` (drag it to the Dock).

## How it works

- PowerPoint files are converted to PDF once by LibreOffice in the background,
  then cached in `~/Library/Application Support/SlideView/pdf`. Re-opening is
  instant; editing the source re-converts automatically.
- Everything runs **fully offline**. PDF.js is vendored into the app bundle and
  the HTTP server binds to `127.0.0.1` only.
- Conversion uses an isolated LibreOffice profile, so it works even while the
  LibreOffice app is open with the same file.

## Appearance modes  (`D` cycles)

| Mode | What it does |
|---|---|
| **Smart** | Inverts text and vector art, leaves photographs in true colour |
| **Invert** | Inverts the whole slide |
| **Dim** | Keeps colours, lowers the light output — for already-dark decks |
| **Light** | Original |

Inversion is per-channel invert plus a 180° hue rotation, so a red heading stays
red rather than turning cyan, and the result is compressed into a soft
near-black / near-white range instead of harsh `#000` / `#fff`.

## Keyboard

`→ ␣ J` next · `← ⇧␣ K` prev · `Home/End` first/last · digits jump to a slide
`D` appearance · `F` full screen · `T` thumbnail rail · `+ −` zoom · `0` fit · `W` fit width
`S` star slide · `[ ]` prev/next starred · `⇧S` starred list · `⌘F` or `/` search · `?` help
`Esc` back to library · `⌘R` rescan

Reading position, stars and appearance are remembered per deck.

## Right-click a slide

Copy as image · copy text · **Google Lens** · **Ask Gemini** · search on Google ·
open PDF in Chrome · reveal original in Finder.

Chrome cannot be embedded inside another app, and Google Lens cannot reach a
`127.0.0.1` URL — so these put the slide (image or text) on the clipboard and
open your real Chrome, where you are already signed in. Press `⌘V` there.

## Library

The **+** in the sidebar adds folders; each is scanned recursively and grouped by
subfolder. Hover a folder to remove it.

## Requirements

- macOS 13+ (Apple Silicon; change `-target` in `build.sh` for Intel)
- Xcode command line tools (`swiftc`)
- [LibreOffice](https://www.libreoffice.org) in `/Applications` — only needed to
  convert PowerPoint files. PDFs open without it.

## Layout

    Sources/    Swift — HTTP server, library scan, LibreOffice, PDFKit, AppKit shell
    web/        UI — index.html, app.css, app.js, vendored pdf.js
    Tools/      icon generator
    build.sh    compile + assemble the .app

## Licence

MIT — see [LICENSE](LICENSE). Bundled PDF.js is Apache 2.0; see
[web/vendor/NOTICE.md](web/vendor/NOTICE.md).
