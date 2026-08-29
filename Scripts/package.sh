#!/usr/bin/env bash
# Build a self-contained, locally signed menu-bar app. `--install` replaces only this app in the
# current user's Applications directory and its matching per-user LaunchAgent; it never touches a
# system-wide location.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Resets Window.app"
OUTPUT="$ROOT/dist/$APP_NAME"
INSTALL=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "usage: $0 [--install]" >&2; exit 2 ;;
  esac
done

cd "$ROOT"
swift build -c release --disable-sandbox

# The output is a fixed, repository-local path and is ignored by Git.
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
cp Resources/Info.plist "$OUTPUT/Contents/Info.plist"
cp Resources/AppIcon.icns "$OUTPUT/Contents/Resources/AppIcon.icns"
cp .build/release/CodexResetsWindow "$OUTPUT/Contents/MacOS/CodexResetsWindow"
chmod 755 "$OUTPUT/Contents/MacOS/CodexResetsWindow"
codesign --force --sign - "$OUTPUT" >/dev/null

if [[ $INSTALL -eq 1 ]]; then
  TARGET_DIR="$HOME/Applications"
  TARGET="$TARGET_DIR/$APP_NAME"
  AGENT_DIR="$HOME/Library/LaunchAgents"
  AGENT_LABEL="com.codexresets.window"
  AGENT="$AGENT_DIR/$AGENT_LABEL.plist"
  USER_DOMAIN="gui/$(id -u)"
  mkdir -p "$TARGET_DIR" "$AGENT_DIR"
  STAGING="$(mktemp -d "$TARGET_DIR/.crw-install.XXXXXX")"
  trap 'rm -rf "$STAGING"' EXIT
  ditto "$OUTPUT" "$STAGING/$APP_NAME"
  codesign --verify --deep --strict "$STAGING/$APP_NAME"
  cp Resources/com.codexresets.window.plist "$STAGING/$AGENT_LABEL.plist"
  plutil -replace ProgramArguments.0 -string "$TARGET/Contents/MacOS/CodexResetsWindow" "$STAGING/$AGENT_LABEL.plist"
  plutil -lint "$STAGING/$AGENT_LABEL.plist" >/dev/null

  # Verify the complete replacement before moving the existing installation aside. A failed
  # build/sign check therefore never deletes the previously working app.
  BACKUP="$STAGING/previous.app"
  AGENT_BACKUP="$STAGING/previous-agent.plist"
  [[ -e "$AGENT" ]] && cp "$AGENT" "$AGENT_BACKUP"
  launchctl bootout "$USER_DOMAIN/$AGENT_LABEL" 2>/dev/null || true
  [[ -e "$TARGET" ]] && mv "$TARGET" "$BACKUP"
  mv "$STAGING/$APP_NAME" "$TARGET"
  mv "$STAGING/$AGENT_LABEL.plist" "$AGENT"
  if ! launchctl bootstrap "$USER_DOMAIN" "$AGENT"; then
    rm -rf "$TARGET"
    [[ -e "$BACKUP" ]] && mv "$BACKUP" "$TARGET"
    [[ -e "$AGENT_BACKUP" ]] && mv "$AGENT_BACKUP" "$AGENT"
    [[ -e "$AGENT" ]] && launchctl bootstrap "$USER_DOMAIN" "$AGENT" 2>/dev/null || true
    echo "LaunchAgent registration failed; restored the previous app." >&2
    exit 1
  fi
  launchctl kickstart -k "$USER_DOMAIN/$AGENT_LABEL"
  codesign --verify --deep --strict "$TARGET"
  launchctl print "$USER_DOMAIN/$AGENT_LABEL" >/dev/null
  echo "installed and running: $TARGET"
else
  codesign --verify --deep --strict "$OUTPUT"
  echo "built: $OUTPUT"
fi
