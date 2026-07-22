#!/usr/bin/env python3
"""Validate the SherlockEQ Sparkle appcast before a release goes out.

Catches the failure modes that silently break the update a user receives —
a malformed feed, a missing/short signature, the releaseNotesLink precedence
trap, a stale or misordered entry, or (with --dmg/--sign-update) a hosted
binary that doesn't match its advertised signature.

Usage:
  dist/validate-appcast.py <appcast.xml>
      [--expect-version X.Y.Z]        assert the newest item is this version
      [--dmg PATH --sign-update PATH] re-sign the DMG and assert its signature
                                      + length match the newest enclosure
                                      (Ed25519 is deterministic, so an intact
                                      DMG signed with the right key reproduces
                                      the appcast signature exactly)

Exit status: 0 if every check passes, 1 on any error. Warnings never fail the
run. Structural checks need only the Python standard library; the signature
cross-check additionally runs Sparkle's sign_update against the local DMG.

Wired into dist/ship.sh PUBLISH, right after dist/appcast-publish.sh rewrites
the feed, so a bad appcast can never be tagged and pushed.
"""
import argparse
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = {"sparkle": SPARKLE}


def short_to_build(short: str) -> str | None:
    """'0.9.7' -> '00907'. None if not a 3-part numeric version."""
    parts = short.split(".")
    if len(parts) == 3 and all(p.isdigit() for p in parts):
        return f"{int(parts[0]):01d}{int(parts[1]):02d}{int(parts[2]):02d}"
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Validate the SherlockEQ Sparkle appcast.")
    ap.add_argument("appcast", help="path to appcast.xml")
    ap.add_argument("--expect-version", help="assert newest item's shortVersionString equals this")
    ap.add_argument("--dmg", help="DMG to re-sign and cross-check against the newest enclosure")
    ap.add_argument("--sign-update", help="path to Sparkle's sign_update tool (required with --dmg)")
    args = ap.parse_args()

    errors: list[str] = []
    warnings: list[str] = []

    try:
        raw = open(args.appcast, encoding="utf-8").read()
    except OSError as e:
        print(f"FATAL: cannot read {args.appcast}: {e}")
        return 1

    try:
        root = ET.fromstring(raw)
    except ET.ParseError as e:
        print(f"FATAL: {args.appcast} is not well-formed XML: {e}")
        return 1

    channel = root.find("channel")
    if channel is None:
        print("FATAL: no <channel> element")
        return 1

    items = channel.findall("item")
    if not items:
        print("FATAL: no <item> entries")
        return 1

    builds: list[tuple[int, str, int]] = []  # (index, title, build)
    newest_enclosure: dict | None = None

    for idx, item in enumerate(items):
        title = (item.findtext("title") or "?").strip()
        tag = f"[{title}]"
        ver = item.find("sparkle:version", NS)
        short = item.find("sparkle:shortVersionString", NS)
        minos = item.find("sparkle:minimumSystemVersion", NS)
        desc = item.findtext("description")
        noteslink = item.find("sparkle:releaseNotesLink", NS)
        enc = item.find("enclosure")

        vt = (ver.text or "").strip() if ver is not None else ""
        st = (short.text or "").strip() if short is not None else ""

        if not vt:
            errors.append(f"{tag} missing sparkle:version")
        if not st:
            errors.append(f"{tag} missing sparkle:shortVersionString")
        if minos is None or not (minos.text or "").strip():
            errors.append(f"{tag} missing sparkle:minimumSystemVersion")

        # The precedence trap: both a notes link AND inline HTML. Sparkle loads
        # the link's web page and ignores the <description>.
        if noteslink is not None and desc and desc.strip():
            errors.append(f"{tag} has BOTH <sparkle:releaseNotesLink> and inline "
                          f"<description> — Sparkle shows the link, HTML ignored")
        if noteslink is None:
            if not desc or not desc.strip():
                errors.append(f"{tag} has neither releaseNotesLink nor inline description")
            elif not desc.strip().startswith("<h2"):
                warnings.append(f"{tag} description doesn't start with <h2> "
                                f"(starts {desc.strip()[:30]!r})")

        # build <-> short consistency
        if vt and st:
            expected = short_to_build(st)
            if expected and vt != expected:
                warnings.append(f"{tag} build {vt!r} != {expected!r} expected from {st!r}")

        # enclosure
        if enc is None:
            errors.append(f"{tag} missing <enclosure>")
        else:
            url = enc.get("url")
            sig = enc.get(f"{{{SPARKLE}}}edSignature")
            length = enc.get("length")
            if not url:
                errors.append(f"{tag} enclosure missing url")
            elif not url.endswith(".dmg"):
                warnings.append(f"{tag} enclosure url is not a .dmg: {url}")
            if not sig:
                errors.append(f"{tag} enclosure missing sparkle:edSignature")
            elif len(sig) < 80:
                errors.append(f"{tag} edSignature looks truncated ({len(sig)} chars)")
            if not length or not length.isdigit() or int(length) <= 0:
                errors.append(f"{tag} enclosure length invalid: {length!r}")
            if idx == 0:
                newest_enclosure = {"url": url, "sig": sig, "length": length,
                                    "short": st, "title": title}

        if vt.isdigit():
            builds.append((idx, title, int(vt)))

    # Ordering: strictly decreasing build numbers, newest first; no duplicates.
    for i in range(1, len(builds)):
        if builds[i][2] >= builds[i - 1][2]:
            errors.append(f"build order not strictly decreasing newest->oldest: "
                          f"{builds[i-1][1]}({builds[i-1][2]}) then {builds[i][1]}({builds[i][2]})")
    seen: dict[int, str] = {}
    for _, title, b in builds:
        if b in seen:
            errors.append(f"duplicate sparkle:version {b}: {seen[b]} and {title}")
        seen[b] = title

    newest = builds[0] if builds else None

    # --expect-version: the newest item must be the version being shipped.
    if args.expect_version:
        got = newest_enclosure["short"] if newest_enclosure else "?"
        if got != args.expect_version:
            errors.append(f"newest item is {got!r}, expected {args.expect_version!r} "
                          f"— did appcast-publish.sh insert this release at the top?")

    # --dmg: re-sign the local DMG and assert it matches the newest enclosure.
    if args.dmg:
        if not args.sign_update:
            errors.append("--dmg requires --sign-update PATH")
        elif newest_enclosure is None:
            errors.append("--dmg given but newest item has no enclosure to compare")
        else:
            try:
                out = subprocess.run([args.sign_update, args.dmg],
                                     capture_output=True, text=True, timeout=120)
            except (OSError, subprocess.TimeoutExpired) as e:
                errors.append(f"sign_update failed to run: {e}")
                out = None
            if out is not None:
                if out.returncode != 0:
                    errors.append(f"sign_update exited {out.returncode}: {out.stderr.strip()}")
                else:
                    m_sig = re.search(r'edSignature="([^"]+)"', out.stdout)
                    m_len = re.search(r'length="([^"]+)"', out.stdout)
                    got_sig = m_sig.group(1) if m_sig else None
                    got_len = m_len.group(1) if m_len else None
                    if got_sig != newest_enclosure["sig"]:
                        errors.append("re-signed DMG signature does NOT match the appcast — "
                                      "wrong signing key, or the hosted/advertised DMG differs "
                                      "from this one (updates would be rejected in-app)")
                    if got_len != newest_enclosure["length"]:
                        errors.append(f"DMG length {got_len} != appcast length "
                                      f"{newest_enclosure['length']}")

    # Report.
    print(f"appcast: {len(items)} items"
          + (f", newest {newest[1]} (build {newest[2]})" if newest else ""))
    if args.dmg and not any("sign_update" in e or "match the appcast" in e or "DMG length" in e
                            for e in errors):
        print("signature cross-check: re-signed DMG matches the appcast enclosure")
    print(f"=== {len(errors)} error(s), {len(warnings)} warning(s) ===")
    for e in errors:
        print(f"  ERROR:   {e}")
    for w in warnings:
        print(f"  warning: {w}")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
