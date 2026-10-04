#!/bin/bash
# Rebuilds web/vendor/excalidraw from npm. Only needed to change the Excalidraw
# version — the output is committed, so building the app itself needs no Node.
#
# Excalidraw's published build leaves ~30 dependencies (React, roughjs,
# mermaid…) as bare imports, so it cannot be served as-is; esbuild folds them
# into one ES module plus lazily loaded chunks.
set -euo pipefail
VERSION="${1:-0.18.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/web/vendor/excalidraw"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo '{ "name": "slideview-excalidraw-vendor", "private": true }' > package.json
npm install --no-audit --no-fund --loglevel=error \
  "@excalidraw/excalidraw@$VERSION" react@18.3.1 react-dom@18.3.1 esbuild@0.19.12

cat > entry.js <<'EOF'
import * as React from "react";
import { createRoot } from "react-dom/client";
import "@excalidraw/excalidraw/index.css";
export * from "@excalidraw/excalidraw";
export { React, createRoot };
EOF

./node_modules/.bin/esbuild entry.js --bundle --format=esm --splitting --minify \
  --outdir=out '--entry-names=excalidraw' '--chunk-names=chunks/[name]-[hash]' \
  '--asset-names=assets/[name]-[hash]' --loader:.woff2=file --loader:.woff=file --loader:.ttf=file \
  '--define:process.env.NODE_ENV="production"' '--define:process.env.IS_PREACT="false"' \
  --conditions=production --target=safari16 --legal-comments=none --log-level=warning

rm -rf "$OUT/excalidraw.js" "$OUT/excalidraw.css" "$OUT/chunks" "$OUT/assets" "$OUT/fonts"
mkdir -p "$OUT/fonts"
cp -R out/excalidraw.js out/excalidraw.css out/chunks out/assets "$OUT/"
# Xiaolai is 12 MB of CJK handwriting glyphs; left out to keep the app small.
# Those characters fall back to a system font.
for d in node_modules/@excalidraw/excalidraw/dist/prod/fonts/*; do
  [ "$(basename "$d")" = "Xiaolai" ] || cp -R "$d" "$OUT/fonts/"
done
echo "$VERSION" > "$OUT/VERSION"
echo "vendored Excalidraw $VERSION into $OUT"
