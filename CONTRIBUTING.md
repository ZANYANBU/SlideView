# Contributing to SlideView

Thanks for helping. Bug reports, format requests and pull requests are all welcome.

## Build and run

```bash
./build.sh          # compiles and assembles ~/Applications/SlideView.app
open ~/Applications/SlideView.app
```

You need macOS 13 or later and Xcode (or its command line tools). There is no
package manager step: PDF.js and Excalidraw are vendored in `web/vendor/`.
Slide decks and spreadsheets also need [LibreOffice](https://www.libreoffice.org)
in `/Applications`.

## Run the tests

```bash
swift test
```

The tests cover the parts with rules worth protecting: the Markdown renderer,
the CSV, notebook and code converters, which files count as credentials and are
never scanned, the links the map draws, and the local HTTP server. They run on
every push and pull request, along with a full build of the app.

`Package.swift` exists only for the tests. It compiles everything in `Sources/`
except `main.swift`, the AppKit entry point; the app itself is built by `build.sh`.

## Where things are

    Sources/    Swift: HTTP server, library scan, converters, AppKit shell
    web/        the UI (index.html, app.css, app.js) and the drawing board
    Tests/      XCTest suites
    Tools/      icon generator, and the script that re-vendors Excalidraw

The README explains why each part is built the way it is. It is worth reading
the section for the area you are changing first.

## Ground rules

- **Offline.** The app talks to `127.0.0.1` and nothing else.
- **Files stay files.** Notes, drawings and decks are ordinary files on disk.
  No database, no proprietary format.
- **Licences.** SlideView is MIT. Do not copy code from GPL or AGPL projects;
  see "Prior art" in the README. Credit new third-party code in
  `web/vendor/NOTICE.md`.
- **Add a test** when you change a converter, the scan rules or the server.

## Sending a change

1. Fork the repo and create a branch.
2. Make the change, then run `swift test` and `./build.sh`.
3. Open a pull request that says what changed and how you tried it.
