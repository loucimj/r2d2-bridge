#!/bin/sh
# Builds dist/R2 Bridge.app: a SwiftUI menu bar app (macos/R2Menu) that launches and
# supervises the node daemon. The bundle declares NSBluetoothAlwaysUsageDescription, so
# macOS attributes the daemon's Bluetooth use to it instead of killing node, which is what
# happens when the daemon is started from Terminal or Warp.
set -e
project="$(cd "$(dirname "$0")/.." && pwd)"
node_bin="$(dirname "$(node -p 'process.execPath')")"
claude_bin="$(command -v claude || echo /opt/homebrew/bin/claude)"
app="$project/dist/R2 Bridge.app"

build_log="$(mktemp)"
if ! (cd "$project/macos/R2Menu" && swift build -c release > "$build_log" 2>&1); then
  grep -E "error" "$build_log" | head -20
  echo "swift build failed; the old app bundle was left untouched" >&2
  exit 1
fi
grep -E "Build complete" "$build_log" | tail -1

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$project/macos/R2Menu/.build/release/R2Menu" "$app/Contents/MacOS/R2 Bridge"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>R2 Bridge</string>
  <key>CFBundleDisplayName</key><string>R2 Bridge</string>
  <key>CFBundleIdentifier</key><string>com.loucimj.r2d2-bridge</string>
  <key>CFBundleExecutable</key><string>R2 Bridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>R2 Bridge talks to your Sphero R2-D2 over Bluetooth.</string>
  <key>NSMicrophoneUsageDescription</key><string>R2 Bridge listens for “R2” and “Artu” voice commands.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>R2 Bridge turns your voice commands into text on this Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>R2 Bridge controls Spotify, Calendar and Safari for voice commands.</string>
</dict></plist>
PLIST

printf '{"projectDir":"%s","nodeBin":"%s","claudeBin":"%s","url":"http://127.0.0.1:4242"}\n' "$project" "$node_bin" "$claude_bin" > "$app/Contents/Resources/bridge.json"
# A stable signing identity keeps the Bluetooth permission across rebuilds; an ad-hoc
# signature changes every build and macOS asks again. Override with R2_SIGN_IDENTITY.
identity="${R2_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Developer ID Application|Apple Development): [^"]+"' | head -1 | tr -d '"')}"
codesign --force --sign "${identity:--}" "$app" >/dev/null 2>&1
echo "built $app (signed: ${identity:-ad-hoc})"
