#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Build a new Sparkle <item> for a freshly notarized .dmg and prepend it
# to dist/appcast.xml.
#
# Run from the repo root after dist/release.sh succeeds.
#
# Usage:
#   dist/appcast-publish.sh <version> <release-notes-file>
# e.g.:
#   dist/appcast-publish.sh 1.0.0 dist/release-notes/1.0.0.md
#
# Inputs the script expects on disk:
#   dist/build/SherlockEQ-<version>.dmg     (from dist/release.sh)
#   <release-notes-file>                    (markdown or html; embedded
#                                            as CDATA)
#
# Output:
#   dist/appcast.xml is rewritten with the new <item> inserted at the top
#   of <channel>. Upload the resulting file to wherever SUFeedURL points
#   (probably https://sherlockeq.app/appcast.xml).
# -----------------------------------------------------------------------------
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $(basename "$0") <version> <release-notes-file>" >&2
  exit 2
fi

VERSION="$1"
NOTES_FILE="$2"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DMG="dist/build/SherlockEQ-$VERSION.dmg"
APPCAST="dist/appcast.xml"
DOWNLOAD_URL="https://github.com/smbrownai/SherlockEQ/releases/download/v$VERSION/SherlockEQ-$VERSION.dmg"
MIN_OS="14.6"

[[ -f "$DMG" ]]        || { echo "error: $DMG missing — run dist/release.sh first"; exit 1; }
[[ -f "$NOTES_FILE" ]] || { echo "error: $NOTES_FILE missing"; exit 1; }
[[ -f "$APPCAST" ]]    || { echo "error: $APPCAST missing — see template in repo"; exit 1; }

# ---- sign with Sparkle EdDSA -------------------------------------------------

SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*Sparkle*/bin/sign_update' -type f 2>/dev/null | head -1)"

if [[ -z "$SIGN_UPDATE" ]]; then
  echo "error: sign_update not found. Build the project once after adding"
  echo "       the Sparkle SPM dependency, then re-run."
  exit 1
fi

# sign_update prints `sparkle:edSignature="..." length="..."` on stdout.
SIG_LINE="$("$SIGN_UPDATE" "$DMG")"

# ---- build the new <item> ----------------------------------------------------

# Use a numeric build number derived from version — Sparkle compares these.
# Mapping: 1.0.0 → 100, 1.2.3 → 10203. Works for x < 100.
BUILD=$(printf "%d%02d%02d" \
  "$(echo "$VERSION" | cut -d. -f1)" \
  "$(echo "$VERSION" | cut -d. -f2 | sed 's/[^0-9].*//')" \
  "$(echo "$VERSION" | cut -d. -f3 | sed 's/[^0-9].*//')")

PUBDATE="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"
NOTES_BODY="$(cat "$NOTES_FILE")"

# Write the new item to its own temp file. BSD awk on macOS rejects
# multi-line strings via -v, so we splice with head/tail instead.
ITEM_FILE="$(mktemp)"
trap 'rm -f "$ITEM_FILE"' EXIT
cat > "$ITEM_FILE" <<XML
    <item>
      <title>SherlockEQ $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[
$NOTES_BODY
]]></description>
      <enclosure url="$DOWNLOAD_URL"
                 type="application/octet-stream"
                 $SIG_LINE />
    </item>
XML

# ---- splice into appcast.xml -------------------------------------------------

# Insert below the marker comment. Fall back to inserting just before
# </channel> if the marker has been edited away.
TMP="$(mktemp)"
if grep -q "<!-- NEW RELEASES GO BELOW THIS LINE -->" "$APPCAST"; then
  MARKER_LINE=$(grep -n "<!-- NEW RELEASES GO BELOW THIS LINE -->" "$APPCAST" | head -1 | cut -d: -f1)
  {
    head -n "$MARKER_LINE" "$APPCAST"
    echo ""
    cat "$ITEM_FILE"
    tail -n +$((MARKER_LINE + 1)) "$APPCAST"
  } > "$TMP"
else
  CHANNEL_LINE=$(grep -n "</channel>" "$APPCAST" | head -1 | cut -d: -f1)
  if [[ -z "$CHANNEL_LINE" ]]; then
    echo "error: appcast.xml has neither the insertion marker nor a </channel> tag" >&2
    rm -f "$TMP"
    exit 1
  fi
  {
    head -n $((CHANNEL_LINE - 1)) "$APPCAST"
    cat "$ITEM_FILE"
    tail -n +"$CHANNEL_LINE" "$APPCAST"
  } > "$TMP"
fi

mv "$TMP" "$APPCAST"

cat <<SUMMARY

  appended SherlockEQ $VERSION to $APPCAST

  next:
    1. git add $APPCAST && git commit -m "appcast: $VERSION"
    2. upload $APPCAST to https://snxt.ai/appcast.xml
       (or wherever SUFeedURL points)
    3. confirm via:
         curl -sI https://snxt.ai/appcast.xml
         curl -s  https://snxt.ai/appcast.xml | head -40

SUMMARY
