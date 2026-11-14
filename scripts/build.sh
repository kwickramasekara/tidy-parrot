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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TidyParrot"
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/app/Resources/Info.plist" "$PLIST"

# The app finds the helper through these absolute paths, so moving the project folder needs a rebuild.
plutil -insert TPHelperPython -string "$ROOT/helper/.venv/bin/python" "$PLIST"
plutil -insert TPHelperScript -string "$ROOT/helper/tidy_parrot_helper.py" "$PLIST"
plutil -insert TPHelperArguments -array "$PLIST"
if $VERBATIM; then
  plutil -insert TPHelperArguments.0 -string --verbatim "$PLIST"
fi
plutil -lint "$PLIST" >/dev/null

# macOS ties the Accessibility grant to the signature's designated requirement. An ad-hoc signature's requirement is
# the build's hash, so every rebuild loses the grant; a certificate's requirement is the same from build to build.
IDENTITY="${SIGN_IDENTITY:-Tidy Parrot Dev}"
if [[ "$(security find-identity -v -p codesigning)" == *"\"$IDENTITY\""* ]]; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "warning: no trusted \"$IDENTITY\" code-signing certificate, so signing ad hoc. You'll need to re-grant" >&2
  echo "         Accessibility after every rebuild. See \"Signing\" in README.md." >&2
  codesign --force --sign - "$APP"
fi

echo "Built $APP"
echo "Run: open \"$APP\""
