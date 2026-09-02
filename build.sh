#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/SlideView.app"
echo "▸ compiling…"
mkdir -p build
swiftc -O -o build/SlideView Sources/*.swift \
  -framework AppKit -framework WebKit -framework PDFKit -framework Network \
  -target arm64-apple-macos13.0

echo "▸ assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/SlideView "$APP/Contents/MacOS/SlideView"
cp -R web "$APP/Contents/Resources/web"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SlideView</string>
  <key>CFBundleDisplayName</key><string>SlideView</string>
  <key>CFBundleExecutable</key><string>SlideView</string>
  <key>CFBundleIdentifier</key><string>com.raja.slideview</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSExceptionDomains</key>
    <dict>
      <key>127.0.0.1</key>
      <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
      <key>localhost</key>
      <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
    </dict>
  </dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "▸ built  $APP"
