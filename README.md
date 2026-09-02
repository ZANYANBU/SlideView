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

## Tabs

Decks open in tabs across the top of the window, Chrome-style, always visible —
the library acts as the new-tab page.

`⌘T` open another deck · `⌘W` close tab · `⌘1`…`⌘9` switch · `⌃⇥` next tab
`⌘`-click or middle-click a deck in the library to open it in a background tab.

Two macOS details worth knowing if you touch this code:

- Tabs sit in the titlebar strip. Clicks *do* reach the web view there, but the
  window then loses its drag area — so the shell puts a real `NSView` with
  `mouseDownCanMoveWindow` in the empty space right of the tabs, and the page
  reports where that space begins (`dragZone`).
- In full screen the strip folds into the toolbar row instead of keeping a row
  of its own, which would cost ~42px of slide for nothing.

Each tab keeps its own page, zoom, stars, search index and notes. Render caches
are keyed per document, so switching back to a tab is instant.

## Zen mode

`H` hides the tab strip, toolbar, thumbnail rail, notes and footer — the slide
fills the screen with no chrome at all. Nudge the pointer to the top edge to
peek at the toolbar; `H` or `Esc` brings everything back. Leaving full screen
drops zen automatically, so you can never get stranded without controls.

## Notes

`N` opens a notes panel docked to the right, holding one note **per slide**.
Notes are saved on the server as JSON — one file per deck under
`~/Library/Application Support/SlideView/notes/` — rather than in `localStorage`,
so clearing a cache cannot take your revision notes with it. Each file records
the deck's name and path, so it still makes sense on its own:

    { "name": "Unit 1",
      "path": "…/CN/Unit 1.pptx",
      "notes": { "71": "OFC = optical fibre cable…" } }

Writes are debounced and always flushed before the slide or tab changes.
Slides carrying a note are dotted in the thumbnail rail and on the scrubber, and
the deck's note count shows on its library card. `⧉` in the panel header copies
every note in the deck as Markdown; `↑` `↓` jump between annotated slides.

Notes are keyed by page only — editing and re-converting a deck keeps them.

## Keyboard

`→ ␣ J` next · `← ⇧␣ K` prev · `Home/End` first/last · digits jump to a slide
`D` appearance · `F` full screen · `H` zen · `T` thumbnail rail · `+ −` zoom · `0` fit · `W` fit width
`S` star slide · `[ ]` prev/next starred · `⇧S` starred list · `N` notes
`⌘F` or `/` search · `⌘T` `⌘W` `⌘1`-`⌘9` tabs · `?` help
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
