#!/bin/bash
# Builds the native Viva.app bundle from the Swift package.
set -euo pipefail
cd "$(dirname "$0")"

# Command Line Tools 27.0 and later ship without the SwiftUI macro plugin, so
# @State and friends fail to compile against their SDK ("plugin for module
# 'SwiftUIMacros' not found"). Full Xcode carries it; use Xcode's toolchain
# when it is installed and no toolchain was chosen explicitly.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release

APP="dist/Viva.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts" "$APP/Contents/Resources/bin"
cp .build/release/Viva "$APP/Contents/MacOS/Viva"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/icon.icns "$APP/Contents/Resources/icon.icns"
cp scripts/*.py "$APP/Contents/Resources/scripts/"

# Bundle whisper-cli and its dylibs so recipients need no Homebrew. Every
# /opt/homebrew or @rpath reference is rewritten to @loader_path and we fail
# the build if any external reference survives.
BIN="$APP/Contents/Resources/bin"
cp /opt/homebrew/bin/whisper-cli "$BIN/"
cp /opt/homebrew/opt/whisper-cpp/lib/libwhisper.1.dylib "$BIN/"
cp /opt/homebrew/opt/ggml/lib/libggml.0.dylib "$BIN/"
cp /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib "$BIN/"
cp /opt/homebrew/opt/libomp/lib/libomp.dylib "$BIN/"
chmod +w "$BIN"/*
for f in "$BIN"/*; do
  otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    case "$dep" in
      /opt/homebrew/*|@rpath/*)
        install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f" 2>/dev/null
        ;;
    esac
  done
  case "$f" in
    *.dylib) install_name_tool -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null ;;
  esac
  codesign --force --sign - "$f"
done
if otool -L "$BIN"/* | grep -q "/opt/homebrew"; then
  echo "ERROR: bundled whisper still references /opt/homebrew" >&2
  exit 1
fi

codesign --force --sign - "$APP"
du -sh "$APP"
echo "Built $APP"
