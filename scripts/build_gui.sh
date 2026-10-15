#!/usr/bin/env bash
# Build the standalone arm64 native GUI app. Never uses or installs the public CLI.
#
# Layout: all intermediates (PyInstaller work, spec, DMG staging) live in a temporary
# directory that is removed on exit, so the repository only gains dist/GUI with the
# deliverables (Mantis.app and the DMG). The Python distribution builds into
# dist/python. `--clean` invalidates PyInstaller's cache anyway, so keeping the work
# directory around would not make rebuilds faster.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -m)" == arm64 ]] || { printf 'Apple Silicon builder required\n' >&2; exit 1; }
PYTHON="${PYTHON:-$ROOT/.venv/bin/python}"
[[ -x "$PYTHON" ]] || { printf 'Run uv sync --locked --python 3.12 --all-extras first\n' >&2; exit 1; }
[[ "$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')" == "3.12" ]] || { printf 'Python 3.12 environment required\n' >&2; exit 1; }
uv sync --locked --python 3.12 --all-extras --check
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mantis-gui-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export MPLBACKEND=Agg
export PYTHONPATH="$ROOT"
export PYINSTALLER_CONFIG_DIR="$WORK/pyinstaller-cache"
mkdir -p "$ROOT/dist/GUI"
"$PYTHON" -m PyInstaller --noconfirm --clean --onedir --name mantis-engine \
  --distpath "$WORK/engine-dist" --workpath "$WORK/engine-work" \
  --specpath "$WORK" --paths "$ROOT" \
  --collect-all mantis_xray --collect-submodules scipy \
  --exclude-module PyQt5 --exclude-module PyQt6 --exclude-module PySide2 --exclude-module PySide6 \
  --exclude-module pyqtgraph --exclude-module tkinter --exclude-module pytest \
  --exclude-module mantis_xray.cli --exclude-module mantis_xray.batch \
  --hidden-import matplotlib.backends.backend_agg \
  --hidden-import matplotlib.backends.backend_pdf --hidden-import matplotlib.backends.backend_svg \
  --hidden-import olefile --hidden-import netCDF4 scripts/engine_entry.py
swift build --package-path GUI -c release --arch arm64
BIN_DIR="$(swift build --package-path GUI -c release --arch arm64 --show-bin-path)"
APP="$ROOT/dist/GUI/Mantis.app"
# Rebuild only this generated app, not any installed app or user data.
if [[ -e "$APP" ]]; then
  [[ -f "$APP/Contents/Info.plist" ]] || { printf 'Unexpected dist/GUI/Mantis.app; refusing replacement\n' >&2; exit 1; }
  rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/MantisNative" "$APP/Contents/MacOS/MantisNative"
cp "$BIN_DIR/MantisUpdater" "$APP/Contents/Helpers/MantisUpdater"
strip -x "$APP/Contents/MacOS/MantisNative" "$APP/Contents/Helpers/MantisUpdater"
cp GUI/Info.plist "$APP/Contents/Info.plist"
cp GUI/Resources/Mantis_logo.icns "$APP/Contents/Resources/Mantis_logo.icns"
cp GUI/Resources/Mantis_logo_about.png "$APP/Contents/Resources/Mantis_logo_about.png"
cp GUI/Resources/MantisMenuIcon.png "$APP/Contents/Resources/MantisMenuIcon.png"
cp LICENSE "$APP/Contents/Resources/LICENSE"
LOGIN_ITEM="$APP/Contents/Library/LoginItems/MantisLoginHelper.app"
mkdir -p "$LOGIN_ITEM/Contents/MacOS"
swiftc -O scripts/login-helper.swift -o "$LOGIN_ITEM/Contents/MacOS/MantisLoginHelper"
cp GUI/Resources/LoginHelperInfo.plist "$LOGIN_ITEM/Contents/Info.plist"
codesign --force --sign - "$LOGIN_ITEM"
codesign --force --sign - "$APP/Contents/Helpers/MantisUpdater"
# Bundle metadata and login item are in place before sealing the outer app.
ditto "$WORK/engine-dist/mantis-engine" "$APP/Contents/Resources/engine"
REVISION="$(git rev-parse --short HEAD)"
if [[ -n "$(git status --porcelain)" ]]; then REVISION="${REVISION}-dirty"; fi
/usr/libexec/PlistBuddy -c "Add :MantisRevision string $REVISION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :MantisProtocolVersion integer 1' "$APP/Contents/Info.plist"
ENGINE_VERSION="$("$PYTHON" -c 'from mantis_xray import __version__; print(__version__)')"
/usr/libexec/PlistBuddy -c "Add :MantisEngineVersion string $ENGINE_VERSION" "$APP/Contents/Info.plist"
# Ad-hoc local signature: integrity only, not Developer ID/notarization.
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$LOGIN_ITEM"
codesign --verify --strict "$APP/Contents/Helpers/MantisUpdater"
codesign --verify --deep --strict "$APP"
"$PYTHON" scripts/smoke_engine.py "$APP/Contents/Resources/engine/mantis-engine"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGE="$WORK/dmg-stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Mantis.app"
ln -sfn /Applications "$STAGE/Applications"
DMG="Mantis-${VERSION}-arm64.dmg"
OUT="$ROOT/dist/GUI"
hdiutil create -volname Mantis -srcfolder "$STAGE" -ov -format UDZO "$OUT/$DMG"
hdiutil verify "$OUT/$DMG"
(cd "$OUT" && shasum -a 256 "$DMG" > "$DMG.sha256" && shasum -a 256 -c "$DMG.sha256")
printf '\nBuilt %s (engine %s, source %s, ad-hoc signature)\n' "$OUT/$DMG" "$ENGINE_VERSION" "$REVISION"

