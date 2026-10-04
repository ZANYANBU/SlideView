# Vendored third-party code

`pdf.min.mjs` and `pdf.worker.min.mjs` are [PDF.js](https://github.com/mozilla/pdf.js)
(version in `VERSION`), © Mozilla Foundation, licensed under the Apache License 2.0:
<https://www.apache.org/licenses/LICENSE-2.0>

They are committed rather than fetched at build time so that SlideView works
completely offline, with no network access at runtime.

## Excalidraw

`excalidraw/` is [Excalidraw](https://github.com/excalidraw/excalidraw) (version in
`excalidraw/VERSION`), © Excalidraw, MIT — see `excalidraw/LICENSE`. It is bundled
with the packages it depends on (React, roughjs, Mermaid and others); every one is
under a permissive licence (MIT, ISC, BSD, Apache 2.0 or similar), listed with
versions in `excalidraw/THIRD-PARTY.md`.

`excalidraw/fonts/` holds the typefaces Excalidraw ships: Excalifont, Virgil,
Cascadia Code, Nunito, Lilita One, Liberation Sans and Assistant (SIL Open Font
License 1.1) and Comic Shanns (MIT).

The bundle is produced by `Tools/vendor-excalidraw.sh` and committed, for the same
reason as PDF.js: the app must run with no network access.
