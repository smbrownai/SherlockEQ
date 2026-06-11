#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# Sync the in-app Help "Release Notes" article with a release's notes.
#
# The Sparkle/GitHub release notes (dist/release-notes/<version>.md) are
# authored as HTML and embedded verbatim in the appcast. The in-app Help
# article (SherlockEQ/Documentation/release-notes.md) is Markdown that gets
# bundled into the app, and was previously updated by hand — so it drifted
# (it topped out at 0.2.0 while 0.3.0 shipped). This converts the HTML notes
# into a Markdown changelog section and inserts it, newest-first, at the top
# of the article's version list.
#
# Run from anywhere; paths are passed explicitly:
#   dist/help-release-notes.py <version> <notes-file> <help-doc>
# e.g.:
#   dist/help-release-notes.py 0.3.0 \
#       dist/release-notes/0.3.0.md \
#       SherlockEQ/Documentation/release-notes.md
#
# Behaviour:
#   • Converts <h2>/<h3>/<p>/<ul><li> + inline <strong>/<em>/<code>/<a> to
#     Markdown. Drops the boilerplate "Not a medical device" / "Previous
#     release" sections — the Help article already carries a standing safety
#     reference and an "Earlier versions" footer.
#   • Idempotent: if a "## <version>" heading already exists, it does nothing.
#   • Non-destructive: existing entries are left untouched; the new section is
#     inserted above the newest existing "## " heading.
#
# Exit codes: 0 on success or "already present"; non-zero only on a real
# error (bad args, missing file, no convertible content). ship.sh treats a
# non-zero result as a warning, not a release blocker.
# -----------------------------------------------------------------------------
import html
import re
import sys
from html.parser import HTMLParser

INLINE = {"strong": "**", "b": "**", "em": "*", "i": "*", "code": "`"}
# Section headings to omit from the in-app changelog — pure boilerplate that
# the Help article already covers elsewhere.
SKIP_SECTIONS = {"not a medical device", "previous release", "earlier versions"}


class NotesParser(HTMLParser):
    """Collect block-level content as (tag, markdown_text) pairs.

    Block tags (h2/h3/p/li) flush a buffer on close; inline tags inject the
    matching Markdown markers into the buffer as they open/close.
    """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.blocks = []
        self.cur = None
        self.buf = []
        self.href = None

    def handle_starttag(self, tag, attrs):
        if tag in ("h2", "h3", "p", "li"):
            self.cur = tag
            self.buf = []
        elif tag in INLINE:
            self.buf.append(INLINE[tag])
        elif tag == "a":
            self.href = dict(attrs).get("href")
            self.buf.append("[")

    def handle_endtag(self, tag):
        if tag in ("h2", "h3", "p", "li"):
            text = "".join(self.buf).replace("\xa0", " ")
            text = re.sub(r"\s+", " ", text).strip()
            if text:
                self.blocks.append((tag, text))
            self.cur = None
            self.buf = []
        elif tag in INLINE:
            self.buf.append(INLINE[tag])
        elif tag == "a":
            self.buf.append(f"]({self.href or ''})")
            self.href = None

    def handle_data(self, data):
        if self.cur is not None:
            self.buf.append(data)


def render_section(version, blocks):
    """Render parsed blocks as a Markdown "## <version>" changelog section."""
    out = []

    def ensure_blank():
        if out and out[-1] != "":
            out.append("")

    out.append(f"## {version}")
    out.append("")

    skipping = False
    saw_content = False
    for tag, text in blocks:
        if tag == "h2":
            continue  # version comes from the argument, not "SherlockEQ X.Y.Z"
        if tag == "h3":
            if text.lower() in SKIP_SECTIONS:
                skipping = True
                continue
            skipping = False
            ensure_blank()
            out.append(f"**{text}**")
            out.append("")
            saw_content = True
            continue
        if skipping:
            continue
        if tag == "p":
            ensure_blank()
            out.append(text)
            out.append("")
            saw_content = True
        elif tag == "li":
            out.append(f"- {text}")
            saw_content = True

    if not saw_content:
        return None

    section = "\n".join(out)
    section = re.sub(r"\n{3,}", "\n\n", section).strip() + "\n"
    return section


def main(argv):
    if len(argv) != 4:
        sys.stderr.write(
            "usage: help-release-notes.py <version> <notes-file> <help-doc>\n"
        )
        return 2

    version, notes_file, help_doc = argv[1], argv[2], argv[3]

    try:
        notes_html = open(notes_file, encoding="utf-8").read()
    except OSError as e:
        sys.stderr.write(f"error: cannot read notes file: {e}\n")
        return 1
    try:
        doc = open(help_doc, encoding="utf-8").read()
    except OSError as e:
        sys.stderr.write(f"error: cannot read help doc: {e}\n")
        return 1

    # Idempotent: a "## <version>" heading already present means we're done.
    if re.search(rf"^## {re.escape(version)}\b", doc, flags=re.MULTILINE):
        print(f"help release notes: {version} already present — nothing to do")
        return 0

    parser = NotesParser()
    parser.feed(notes_html)
    section = render_section(version, parser.blocks)
    if section is None:
        sys.stderr.write(
            f"warning: no convertible content in {notes_file} "
            "(expected HTML <h2>/<h3>/<ul>); help doc left unchanged\n"
        )
        return 1

    # Insert above the newest existing "## " heading (newest-first ordering).
    # Fall back to appending if the article has no version sections yet.
    m = re.search(r"^## ", doc, flags=re.MULTILINE)
    if m:
        idx = m.start()
        updated = doc[:idx] + section + "\n" + doc[idx:]
    else:
        updated = doc.rstrip() + "\n\n" + section

    open(help_doc, "w", encoding="utf-8").write(updated)
    print(f"help release notes: inserted {version} into {help_doc}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
