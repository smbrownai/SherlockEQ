#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-time Sparkle EdDSA key generation.
#
# Stores the private signing key in the login keychain under the
# "https://sparkle-project.org" service entry. Prints the base64 public
# key to stdout — paste it into the project's Info.plist as SUPublicEDKey
# (or as the INFOPLIST_KEY_SUPublicEDKey build setting on a project that
# uses GENERATE_INFOPLIST_FILE=YES).
#
# Run this exactly once per app. Do not commit the private key. Do not
# delete the keychain entry once releases are out — Sparkle clients
# refuse update payloads signed by any other key, and migrating keys
# orphans every existing installed copy.
#
# Usage:
#   dist/sparkle-keygen.sh
# -----------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Look for the Sparkle SPM artifacts. The exact path depends on Xcode's
# DerivedData hash, so glob and pick the first hit.
GEN_KEYS="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*Sparkle*/bin/generate_keys' -type f 2>/dev/null | head -1)"

if [[ -z "$GEN_KEYS" ]]; then
  cat >&2 <<'MSG'
error: generate_keys not found.

The Sparkle SPM package must be added to the Xcode project before this
script can run:

  Xcode → File → Add Package Dependencies →
    https://github.com/sparkle-project/Sparkle
    Up to Next Major Version → 2.0.0

Build the project once after adding it, then re-run this script.
MSG
  exit 1
fi

echo "==> using $GEN_KEYS" >&2

# generate_keys prints the public key on stdout and stores the private
# key in the login keychain. Idempotent: re-running prints the existing
# public key without overwriting the keychain entry.
"$GEN_KEYS"

cat >&2 <<MSG

Copy the public key printed above. In Xcode's target build settings,
add a custom user-defined build setting:

  INFOPLIST_KEY_SUPublicEDKey = <the base64 string>

Also add (one-time per project):

  INFOPLIST_KEY_SUFeedURL = https://snxt.ai/appcast.xml

Optional (defaults are sensible):

  INFOPLIST_KEY_SUEnableAutomaticChecks   = YES
  INFOPLIST_KEY_SUScheduledCheckInterval  = 86400

Rebuild. From now on, dist/appcast-publish.sh signs each release with
the private key in your keychain; clients verify against the public key
in Info.plist.
MSG
