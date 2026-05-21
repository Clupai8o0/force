#!/bin/bash
# Builds Acknowledgement Force from source and installs it as a native macOS
# .app bundle. Safe to re-run — it replaces any previously installed copy.
#
# Usage:
#   ./install.sh                 Install to ~/Applications (no sudo needed)
#   ./install.sh --system        Install to /Applications (asks for sudo)
#   ./install.sh --prefix DIR    Install into a custom directory
#   ./install.sh --no-open       Don't launch the app after installing
#   ./install.sh --replace-others  Remove copies in other locations, no prompt
#   ./install.sh --keep-others   Leave copies in other locations in place
#
# Before installing, the script checks the common install locations (and any
# it has installed to before) for an existing "Acknowledgement Force.app"
# outside the current target and offers to remove it, so you don't end up with
# stale duplicate copies on disk.
#
# After install the app lives at <prefix>/Acknowledgement Force.app. Turn on
# auto-launch from the app's onboarding/Settings, or run ./uninstall.sh to
# remove it completely.

set -euo pipefail

APP_NAME="Acknowledgement Force"
BUNDLE_ID="com.acknowledgementforce.app"
EXEC_NAME="Force"
RESOURCE_BUNDLE="Force_Force.bundle"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(tr -d '[:space:]' < "$REPO_DIR/VERSION" 2>/dev/null || echo "0.0.0")"
ICON_SRC="$REPO_DIR/landing/assets/raw/icon.png"

PREFIX="$HOME/Applications"
OPEN_AFTER=1
USE_SUDO=""
REPLACE_OTHERS=0
KEEP_OTHERS=0
RECORD="$HOME/Library/Application Support/$EXEC_NAME/install-locations"

while [ $# -gt 0 ]; do
  case "$1" in
    --system) PREFIX="/Applications"; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --no-open) OPEN_AFTER=0; shift ;;
    --replace-others) REPLACE_OTHERS=1; shift ;;
    --keep-others) KEEP_OTHERS=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Normalize to an absolute path so duplicate detection and the sudo check below
# compare apples to apples.
case "$PREFIX" in /*) ;; *) PREFIX="$PWD/$PREFIX" ;; esac

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Error: Acknowledgement Force is a macOS app and only installs on macOS." >&2
  exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "Error: 'swift' not found. Install Xcode or the Command Line Tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

# Writing into /Applications needs root; everywhere under $HOME does not.
case "$PREFIX" in
  "$HOME"/*) USE_SUDO="" ;;
  *) [ -w "$PREFIX" ] || USE_SUDO="sudo" ;;
esac

echo "==> Building Acknowledgement Force $VERSION (release)..."
swift build -c release --package-path "$REPO_DIR"
BIN_DIR="$(swift build -c release --package-path "$REPO_DIR" --show-bin-path)"

BIN_PATH="$BIN_DIR/$EXEC_NAME"
BUNDLE_PATH="$BIN_DIR/$RESOURCE_BUNDLE"
[ -x "$BIN_PATH" ] || { echo "Error: built binary not found at $BIN_PATH" >&2; exit 1; }

echo "==> Assembling app bundle..."
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/$EXEC_NAME"
# Bundle.module resolves against Bundle.main.resourceURL (Contents/Resources).
[ -d "$BUNDLE_PATH" ] && cp -R "$BUNDLE_PATH" "$APP/Contents/Resources/"

# Build a multi-resolution .icns from the source PNG.
ICON_REF=""
if [ -f "$ICON_SRC" ] && command -v iconutil >/dev/null 2>&1; then
  ICONSET="$STAGE/AppIcon.iconset"
  mkdir -p "$ICONSET"
  # The source asset may be a JPEG with a .png name, so force real PNG output —
  # iconutil rejects anything that isn't a true PNG.
  for sz in 16 32 128 256 512; do
    sips -s format png -z "$sz" "$sz" "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
    d=$((sz * 2))
    sips -s format png -z "$d" "$d" "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 || true
  done
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1; then
    ICON_REF="AppIcon"
  fi
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$EXEC_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
$( [ -n "$ICON_REF" ] && printf '    <key>CFBundleIconFile</key><string>%s</string>\n' "$ICON_REF" )
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper trusts the locally built bundle and the launchd
# agent gets a stable executable path. Non-fatal if codesign is unavailable.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - --options runtime "$APP" >/dev/null 2>&1 || \
    echo "    (warning: ad-hoc code signing failed; app should still run)"
fi

DEST="$PREFIX/$APP_NAME.app"

# Look for copies installed somewhere other than the current target so a user
# who once ran `--system` and later the default (or vice versa) doesn't leave a
# stale duplicate behind. Scan the common locations plus anywhere we've
# installed before.
SCAN_DIRS=("$HOME/Applications" "/Applications")
if [ -f "$RECORD" ]; then
  while IFS= read -r line; do [ -n "$line" ] && SCAN_DIRS+=("$line"); done < "$RECORD"
fi

abs_app() {  # echoes the physical path of "<dir>/<APP_NAME>.app" if <dir> exists
  local dir="$1"
  [ -d "$dir" ] || { echo "$dir/$APP_NAME.app"; return; }
  echo "$(cd "$dir" && pwd -P)/$APP_NAME.app"
}
DEST_PHYS="$(abs_app "$PREFIX")"

STRAYS=()
for dir in "${SCAN_DIRS[@]}"; do
  cand="$dir/$APP_NAME.app"
  [ -d "$cand" ] || continue
  cphys="$(abs_app "$dir")"
  [ "$cphys" = "$DEST_PHYS" ] && continue
  case " ${STRAYS[*]-} " in *" $cphys "*) continue ;; esac
  STRAYS+=("$cphys")
done

if [ "${#STRAYS[@]}" -gt 0 ]; then
  echo "==> Found Acknowledgement Force installed in other location(s):"
  for s in "${STRAYS[@]}"; do echo "      $s"; done
  remove=0
  if [ "$KEEP_OTHERS" -eq 1 ]; then
    echo "    Keeping them (--keep-others)."
  elif [ "$REPLACE_OTHERS" -eq 1 ]; then
    remove=1
  elif [ -t 0 ]; then
    printf "    Remove these before installing to %s? [y/N] " "$PREFIX"
    read -r ans
    case "$ans" in [yY]*) remove=1 ;; esac
  else
    echo "    Non-interactive run — leaving them. Re-run with --replace-others to remove."
  fi
  if [ "$remove" -eq 1 ]; then
    for s in "${STRAYS[@]}"; do
      if [ -w "$(dirname "$s")" ]; then rm -rf "$s"; else sudo rm -rf "$s"; fi
      echo "    removed $s"
    done
  fi
fi

echo "==> Installing to $PREFIX..."
$USE_SUDO mkdir -p "$PREFIX"
# If a previous copy is running, ask it to quit so we can replace it.
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
$USE_SUDO rm -rf "$DEST"
$USE_SUDO cp -R "$APP" "$DEST"

# Remember where we installed so future runs can find duplicates here too.
mkdir -p "$(dirname "$RECORD")"
if ! { [ -f "$RECORD" ] && grep -qxF "$PREFIX" "$RECORD"; }; then
  echo "$PREFIX" >> "$RECORD"
fi

echo ""
echo "Installed: $DEST"
echo "Version:   $VERSION"
echo ""
echo "Launch it from Spotlight/Launchpad, or enable auto-launch in the app's"
echo "Settings. To remove everything later, run: ./uninstall.sh"

if [ "$OPEN_AFTER" -eq 1 ]; then
  echo ""
  echo "==> Opening Acknowledgement Force..."
  open "$DEST"
fi
