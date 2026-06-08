#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# SherlockEQ release pipeline.
#
# Builds a Release archive with Developer ID signing, exports a .app, packages
# it into a drag-to-Applications .dmg, signs the .dmg, notarizes via notarytool,
# staples the ticket, verifies with spctl, and prints the sha256 line ready to
# paste into dist/homebrew/sherlockeq.rb.
#
# Usage:
#   dist/release.sh <version>
# e.g.:
#   dist/release.sh 1.0.0
#
# Required environment:
#   DEVELOPER_ID    Full identity string, e.g.
#                   "Developer ID Application: Shawn Brown (XXXXXXXXXX)"
#   TEAM_ID         10-char Apple team id, e.g. "XXXXXXXXXX"
#   NOTARY_PROFILE  notarytool keychain profile name (created once, see below).
#
# One-time setup (run interactively, stores credentials in the login keychain):
#   xcrun notarytool store-credentials SherlockEQ-Notary \
#     --apple-id you@example.com \
#     --team-id XXXXXXXXXX \
#     --password APP_SPECIFIC_PASSWORD     # appleid.apple.com → app-specific
#
# Then in your shell rc:
#   export DEVELOPER_ID="Developer ID Application: Shawn Brown (XXXXXXXXXX)"
#   export TEAM_ID="XXXXXXXXXX"
#   export NOTARY_PROFILE="SherlockEQ-Notary"
#
# Outputs (relative to repo root):
#   dist/build/SherlockEQ-<version>.dmg
#   dist/build/SherlockEQ-<version>.dmg.sha256
# -----------------------------------------------------------------------------
set -euo pipefail

# ---- args + env --------------------------------------------------------------

if [[ $# -ne 1 ]]; then
  echo "usage: $(basename "$0") <version>" >&2
  exit 2
fi
VERSION="$1"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
  echo "error: version must look like 1.0.0 or 1.0.0-beta.1, got: $VERSION" >&2
  exit 2
fi

: "${DEVELOPER_ID:?set DEVELOPER_ID, e.g. 'Developer ID Application: ... (XXXXXXXXXX)'}"
: "${TEAM_ID:?set TEAM_ID, the 10-char Apple team id}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE, the name passed to notarytool store-credentials}"

# ---- paths -------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="SherlockEQ.xcodeproj"
SCHEME="SherlockEQ"
APP_NAME="SherlockEQ.app"

BUILD_DIR="$REPO_ROOT/dist/build"
ARCHIVE="$BUILD_DIR/SherlockEQ.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTS="$BUILD_DIR/ExportOptions.plist"
DMG_STAGE="$BUILD_DIR/dmg-stage"
DMG="$BUILD_DIR/SherlockEQ-$VERSION.dmg"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DMG_STAGE"

# ---- ExportOptions.plist (generated; never edit by hand) ---------------------

cat > "$EXPORT_OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
PLIST

# ---- 1. archive --------------------------------------------------------------

# Compute a monotonically increasing CFBundleVersion from the marketing
# version, using the same formula as dist/appcast-publish.sh so the
# installed app's build number matches what the appcast advertises.
# 0.1.0 -> 100, 0.1.1 -> 101, 1.0.0 -> 10000.
BUILD_NUMBER=$(printf "%d%02d%02d" \
  "$(echo "$VERSION" | cut -d. -f1)" \
  "$(echo "$VERSION" | cut -d. -f2 | sed 's/[^0-9].*//')" \
  "$(echo "$VERSION" | cut -d. -f3 | sed 's/[^0-9].*//')")

echo "==> archiving Release configuration (build $BUILD_NUMBER)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=$DEVELOPER_ID" \
  "DEVELOPMENT_TEAM=$TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  | xcpretty --no-color 2>/dev/null || true

if [[ ! -d "$ARCHIVE" ]]; then
  echo "error: archive failed; $ARCHIVE not produced" >&2
  exit 1
fi

# ---- 2. export ---------------------------------------------------------------

echo "==> exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS"

APP="$EXPORT_DIR/$APP_NAME"
if [[ ! -d "$APP" ]]; then
  echo "error: export did not produce $APP" >&2
  exit 1
fi

echo "==> verifying app signature + hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "flags=.*runtime" \
  || { echo "error: app is not built with hardened runtime"; exit 1; }

# ---- 3. dmg ------------------------------------------------------------------

echo "==> staging dmg contents"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

echo "==> creating $DMG"
hdiutil create \
  -volname "SherlockEQ" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

# ---- 4. sign dmg -------------------------------------------------------------

echo "==> signing dmg"
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"

# ---- 5. notarize -------------------------------------------------------------

echo "==> submitting to notary service (this can take several minutes)"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

# ---- 6. staple ---------------------------------------------------------------

echo "==> stapling notarization ticket"
xcrun stapler staple "$DMG"

# ---- 7. verify ---------------------------------------------------------------

echo "==> gatekeeper assessment"
spctl -a -t open --context context:primary-signature -vv "$DMG"

# ---- 8. checksum + summary ---------------------------------------------------

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "$SHA  $(basename "$DMG")" > "${DMG}.sha256"

SIZE=$(stat -f%z "$DMG")
SIZE_MB=$(awk "BEGIN { printf \"%.1f\", $SIZE / 1024 / 1024 }")

cat <<SUMMARY

  released:  $(basename "$DMG")
  size:      ${SIZE_MB} MB
  sha256:    $SHA

  cask patch — paste into dist/homebrew/sherlockeq.rb:

    version "$VERSION"
    sha256 "$SHA"

  next:
    1. write release notes:        dist/release-notes/$VERSION.md
    2. publish appcast entry:      dist/appcast-publish.sh $VERSION dist/release-notes/$VERSION.md
    3. upload dmg:                 gh release create v$VERSION "$DMG" \\
                                     --title "SherlockEQ $VERSION" \\
                                     --notes-file dist/release-notes/$VERSION.md
    4. upload dist/appcast.xml to https://snxt.ai/appcast.xml
    5. bump version + sha256 in dist/homebrew/sherlockeq.rb and push the tap repo

SUMMARY
