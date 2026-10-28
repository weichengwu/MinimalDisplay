#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=1.0.8
APP_NAME=MinimalDisplay
BUILD_ROOT="$PWD/build"
APP="$BUILD_ROOT/$VERSION/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SWIFT_FLAGS=(--disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security")

# This script only builds artifacts. It does not install, launch, or modify display settings.
swift build "${SWIFT_FLAGS[@]}" -c release --product MinimalDisplay
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" -c release --show-bin-path)"
if [[ ! -x "$BIN_DIR/MinimalDisplay" ]]; then
  print -u2 "找不到编译产物：$BIN_DIR/MinimalDisplay"
  exit 1
fi
mkdir -p "$BUILD_ROOT" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MinimalDisplay" "$APP/Contents/MacOS/MinimalDisplay"
cp "$BIN_DIR/MinimalDisplay" "$APP/Contents/MacOS/MinimalDisplayRecovery"
cp LICENSE THIRD_PARTY_LICENSES.txt "$APP/Contents/Resources/"
cp README.md TODO.md CHANGELOG.md CONTRIBUTING.md "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/docs"
cp docs/upstream-analysis.md docs/verification.md docs/architecture.md "$APP/Contents/Resources/docs/"

cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.waynewu.minimaldisplay</string>
  <key>CFBundleName</key><string>MinimalDisplay</string>
  <key>CFBundleDisplayName</key><string>屏幕切换</string>
  <key>CFBundleExecutable</key><string>MinimalDisplay</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>9</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 weichengwu. Includes MIT-licensed interface declarations from UUyc-companion (AoyamaShou).</string>
</dict></plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --identifier local.waynewu.minimaldisplay.recovery "$APP/Contents/MacOS/MinimalDisplayRecovery"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --identifier local.waynewu.minimaldisplay "$APP"
codesign --verify --strict --deep "$APP"
ARCH="$(uname -m)"
ZIP="$BUILD_ROOT/MinimalDisplay-$VERSION-$ARCH.zip"
# Remove only the previous archive at this exact, generated output path.
if [[ -f "$ZIP" ]]; then /bin/rm "$ZIP"; fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
# Use a relative archive name so downloads can be verified on any machine.
(cd "$BUILD_ROOT" && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256")
print "App: $APP"
print "ZIP: $ZIP"
