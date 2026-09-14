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
#
# ggml loads its compute backends (Metal, CPU variants, BLAS) at runtime as
# plugins. The Homebrew build bakes its own Cellar directory in as the first
# place to look, then falls back to the directory holding the executable. A
# bundle without the plugins therefore works only until `brew upgrade` deletes
# that Cellar directory, after which whisper aborts before reading any audio.
# So the plugins ship inside the bundle next to whisper-cli.
BIN="$APP/Contents/Resources/bin"
cp /opt/homebrew/bin/whisper-cli "$BIN/"
cp /opt/homebrew/opt/whisper-cpp/lib/libwhisper.1.dylib "$BIN/"
cp /opt/homebrew/opt/ggml/lib/libggml.0.dylib "$BIN/"
cp /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib "$BIN/"
cp /opt/homebrew/opt/libomp/lib/libomp.dylib "$BIN/"
cp /opt/homebrew/opt/ggml/libexec/libggml-*.so "$BIN/"
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
    *.dylib|*.so) install_name_tool -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null ;;
  esac
  codesign --force --sign - "$f"
done
if otool -L "$BIN"/* | grep -q "/opt/homebrew"; then
  echo "ERROR: bundled whisper still references /opt/homebrew" >&2
  exit 1
fi
if ! ls "$BIN"/libggml-metal.so "$BIN"/libggml-cpu-*.so >/dev/null 2>&1; then
  echo "ERROR: ggml backend plugins were not bundled" >&2
  exit 1
fi

# Smoke test: the bundled whisper must start and load a backend. This catches
# a broken bundle at build time rather than as silent empty transcripts.
if ! "$BIN/whisper-cli" --help >/dev/null 2>&1; then
  echo "ERROR: bundled whisper-cli does not run" >&2
  exit 1
fi

codesign --force --sign - "$APP"
du -sh "$APP"
echo "Built $APP"
