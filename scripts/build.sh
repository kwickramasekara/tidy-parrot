#!/usr/bin/env bash
# Builds build/TidyParrot.app. Pass --verbatim to keep fillers (clean mode off).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/TidyParrot.app"
PLIST="$APP/Contents/Info.plist"

VERBATIM=false
case "${1:-}" in
  --verbatim) VERBATIM=true ;;
  "") ;;
  *) echo "usage: $0 [--verbatim]" >&2; exit 2 ;;
esac

if [[ ! -x "$ROOT/helper/.venv/bin/python" ]]; then
  echo "Helper venv missing: run make setup first" >&2
  exit 1
fi

swift build -c release --package-path "$ROOT/app"
BIN="$(swift build -c release --package-path "$ROOT/app" --show-bin-path)/TidyParrot"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TidyParrot"
cp "$ROOT/app/Resources/Info.plist" "$PLIST"

# The app finds the helper through these absolute paths, so moving the project folder needs a rebuild.
plutil -insert TPHelperPython -string "$ROOT/helper/.venv/bin/python" "$PLIST"
plutil -insert TPHelperScript -string "$ROOT/helper/tidy_parrot_helper.py" "$PLIST"
plutil -insert TPHelperArguments -array "$PLIST"
if $VERBATIM; then
  plutil -insert TPHelperArguments.0 -string --verbatim "$PLIST"
fi
plutil -lint "$PLIST" >/dev/null

# Ad-hoc signature. macOS ties the Accessibility grant to it, so after a rebuild you may need to
# remove and re-add Tidy Parrot under Privacy & Security → Accessibility.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run: open \"$APP\""
