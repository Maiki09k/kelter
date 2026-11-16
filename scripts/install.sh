#!/bin/zsh

# Builds Kelter, installs it to ~/Applications, puts a link to it on the Desktop and starts it.
# Running it again replaces the installed copy; engine, bottle and Steam stay where they are
# (~/Library/Application Support/Kelter).

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_NAME="Kelter"
TARGET_DIR="$HOME/Applications"
TARGET="$TARGET_DIR/$APP_NAME.app"

cd "$PROJECT_DIR"

# The web helper shim is a Windows program; rebuild it when its source is newer.
SHIM="$PROJECT_DIR/Resources/steamwebhelper-shim.exe"
if [[ ! -f "$SHIM" || "$PROJECT_DIR/shim/webhelper-shim.c" -nt "$SHIM" ]]; then
  "$SCRIPT_DIR/build-shim.sh"
fi

swift build --configuration release
BIN_DIR="$(swift build --configuration release --show-bin-path)"

BUNDLE="$PROJECT_DIR/.build/$APP_NAME.app"
rm -rf -- "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$SHIM" "$BUNDLE/Contents/Resources/steamwebhelper-shim.exe"
# Kelter's MoltenVK for id Tech games (scripts/build-moltenvk.sh). Without it DOOM Eternal won't start.
if [[ -f "$PROJECT_DIR/Resources/libMoltenVK-kelter.dylib" ]]; then
  cp "$PROJECT_DIR/Resources/libMoltenVK-kelter.dylib" "$BUNDLE/Contents/Resources/"
else
  echo "Hinweis: Resources/libMoltenVK-kelter.dylib fehlt (scripts/build-moltenvk.sh)." >&2
fi

# App icon, drawn by the app itself, in every size macOS asks for.
ICON_SOURCE="$PROJECT_DIR/.build/icon-1024.png"
ICONSET="$PROJECT_DIR/.build/AppIcon.iconset"
rm -rf -- "$ICONSET"
mkdir -p "$ICONSET"
"$BIN_DIR/$APP_NAME" --icon "$ICON_SOURCE"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"

# A fixed requirement on the bundle id keeps macOS from asking for permissions again after updates.
codesign --force --sign - --requirements '=designated => identifier "io.github.maiki09k.kelter"' "$BUNDLE"

# Stop the running copy by its own process id, never by pattern.
for pid in $(pgrep -x "$APP_NAME" 2>/dev/null); do
  if [[ "$(ps -p "$pid" -o comm=)" == "$TARGET/Contents/MacOS/$APP_NAME" ]]; then
    kill "$pid" 2>/dev/null || true
  fi
done
mkdir -p "$TARGET_DIR"
rm -rf -- "$TARGET"
cp -R "$BUNDLE" "$TARGET"

# Desktop icon: a link, so every update reaches it. A real copy someone put there stays untouched.
DESKTOP_LINK="$HOME/Desktop/$APP_NAME.app"
if [[ -L "$DESKTOP_LINK" || ! -e "$DESKTOP_LINK" ]]; then
  ln -sfn "$TARGET" "$DESKTOP_LINK"
fi
if [[ "${1:-}" != "--no-open" ]]; then
  open "$TARGET"
fi

echo "$TARGET"
