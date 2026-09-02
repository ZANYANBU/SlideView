# Vendored third-party code

`pdf.min.mjs` and `pdf.worker.min.mjs` are [PDF.js](https://github.com/mozilla/pdf.js)
(version in `VERSION`), © Mozilla Foundation, licensed under the Apache License 2.0:
<https://www.apache.org/licenses/LICENSE-2.0>

They are committed rather than fetched at build time so that SlideView works
completely offline, with no network access at runtime.
