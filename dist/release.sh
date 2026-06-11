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

# ---- 2b. embed the sherlockeq CLI -------------------------------------------
#
# Build the command-line tool and drop it inside the bundle at
# Contents/Helpers/sherlockeq (not Contents/MacOS — `sherlockeq` and the main
# `SherlockEQ` executable would collide on case-insensitive APFS). Sign the
# helper with the hardened runtime, then re-seal the whole bundle so the outer
# signature covers the new file. Notarization (step 5) then includes it.

echo "==> building + embedding sherlockeq CLI"
bash "$REPO_ROOT/dist/build-cli.sh"
CLI_BIN="$REPO_ROOT/cli/.build/apple/Products/Release/sherlockeq"
[[ -f "$CLI_BIN" ]] || { echo "error: CLI binary missing at $CLI_BIN" >&2; exit 1; }

HELPERS="$APP/Contents/Helpers"
mkdir -p "$HELPERS"
cp "$CLI_BIN" "$HELPERS/sherlockeq"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$HELPERS/sherlockeq"
# Re-seal the bundle (deep, same identity) so CodeResources covers the helper.
codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"

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

# ---- 8. preserve archive + dSYMs for crash symbolication --------------------

# Apple-aggregated crash reports show up in Xcode Organizer → Crashes
# *only* if Organizer can match a symbolicated archive to the crashing
# binary. Organizer scans ~/Library/Developer/Xcode/Archives/<date>/,
# but `xcodebuild archive` writes to the path we passed in $BUILD_DIR
# — and the next release wipes that. So copy the archive into the
# Organizer-visible location with a version-tagged name so the various
# versions you ship don't collide.
#
# We also save a standalone dSYMs zip next to the dmg as belt-and-
# braces — if the Archives folder ever gets cleared (Time Machine
# restore, fresh machine, manual cleanup), the dSYMs survive in the
# build artifacts that go alongside the dmg.

ORG_ARCHIVES_DIR="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
ORG_ARCHIVE="$ORG_ARCHIVES_DIR/SherlockEQ-$VERSION.xcarchive"

mkdir -p "$ORG_ARCHIVES_DIR"
if [[ -e "$ORG_ARCHIVE" ]]; then
  # Don't silently overwrite — a re-run of the same version probably
  # means something went wrong; preserve the previous archive.
  ORG_ARCHIVE="$ORG_ARCHIVES_DIR/SherlockEQ-$VERSION-$(date +%H%M%S).xcarchive"
fi
echo "==> copying archive to Organizer-visible location"
cp -R "$ARCHIVE" "$ORG_ARCHIVE"

DSYM_ZIP="$BUILD_DIR/SherlockEQ-$VERSION-dSYMs.zip"
echo "==> zipping dSYMs to $DSYM_ZIP"
(cd "$ARCHIVE/dSYMs" && zip -qr "$DSYM_ZIP" .)

# Print dSYM UUIDs — handy for sanity-checking that a crashed .ips
# binary matches the symbols you have. Match against
# `dwarfdump --uuid /path/to/SherlockEQ.app.dSYM` or the UUID line in
# a `.ips`-style crash report header.
DSYM_UUIDS=$(dwarfdump --uuid "$ARCHIVE/dSYMs/SherlockEQ.app.dSYM" 2>/dev/null | awk '{print "    " $0}')

# ---- 9. checksum + summary ---------------------------------------------------

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "$SHA  $(basename "$DMG")" > "${DMG}.sha256"

SIZE=$(stat -f%z "$DMG")
SIZE_MB=$(awk "BEGIN { printf \"%.1f\", $SIZE / 1024 / 1024 }")

cat <<SUMMARY

  released:  $(basename "$DMG")
  size:      ${SIZE_MB} MB
  sha256:    $SHA

  archive:   $ORG_ARCHIVE
             (visible in Xcode → Window → Organizer → Archives)

  dsyms:     $DSYM_ZIP
$DSYM_UUIDS

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
    6. (one-time, then any time you want to re-check) open Xcode →
       Window → Organizer → Crashes. Apple-aggregated reports from users
       who opted into "Share with App Developers" arrive here, typically
       within 1–3 days of the crash, symbolicated against the dSYMs in
       the archive above.

SUMMARY
