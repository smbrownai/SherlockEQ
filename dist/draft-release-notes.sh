#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Draft user-facing release notes for SherlockEQ <version> from the changes
# shipped since the previous tag, using the `claude` CLI. Prints HTML notes to
# stdout in the house format (see dist/release-notes/*.md).
#
#   dist/draft-release-notes.sh <version> [--since <tag>] [--head <ref>]
#
#   <version>        the version being released, e.g. 0.5.0
#   --since <tag>    diff base (default: highest v* tag). Useful to regenerate
#                    old notes or preview, e.g. --since v0.3.3.
#   --head <ref>     diff tip (default: HEAD). Pair with --since to scope a
#                    historical range, e.g. --since v0.3.3 --head v0.4.0.
#
# Data source = the commits actually in <since>..<head>: merged-PR titles +
# bodies (exact, from the merge commits in range) plus a no-merge commit
# shortlog and a diffstat so squash-merged or direct-to-main changes aren't
# lost. The previous version's notes file is passed as a style exemplar so the
# draft matches structure, tone, and the trailing boilerplate exactly.
#
# ship.sh PREP seeds the release-notes editor with this draft; you review and
# polish before it ships. Runnable standalone to preview or regenerate:
#   dist/draft-release-notes.sh 0.5.0 > dist/release-notes/0.5.0.md
#
# Fallback: if `claude` is not on PATH (or the draft call fails), emits a
# mechanical scaffold (PR/commit titles in the house skeleton) instead, so a
# release is never blocked on the LLM being available.
# -----------------------------------------------------------------------------
set -euo pipefail

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: $(basename "$0") <version> [--since <tag>] [--head <ref>]" >&2; exit 2; }
shift

SINCE_TAG=""
HEAD_REF="HEAD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE_TAG="${2:?--since needs a tag}"; shift 2 ;;
    --head)  HEAD_REF="${2:?--head needs a ref}"; shift 2 ;;
    *) echo "error: unknown arg $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

[[ -n "$SINCE_TAG" ]] || SINCE_TAG=$(git tag --list 'v*' --sort=-v:refname | head -n1)
[[ -n "$SINCE_TAG" ]] || { echo "error: no previous v* tag found; pass --since" >&2; exit 1; }
PREV_VERSION="${SINCE_TAG#v}"
REPO_URL="https://github.com/smbrownai/SherlockEQ"

# ---- gather the change set in <since>..<head> -------------------------------

# Exact PR numbers from merge commits in the range; filter out release-plumbing
# PRs (titled "Release ...") which carry no user-facing change.
PR_NUMS=$(git log "$SINCE_TAG..$HEAD_REF" --merges --pretty=%s \
  | sed -nE 's/^Merge pull request #([0-9]+) .*/\1/p')

PR_CONTEXT=""
if [[ -n "$PR_NUMS" ]] && command -v gh >/dev/null; then
  while read -r n; do
    [[ -n "$n" ]] || continue
    pr=$(gh pr view "$n" --json number,title,body 2>/dev/null) || continue
    title=$(echo "$pr" | jq -r '.title')
    [[ "$title" =~ ^[Rr]elease ]] && continue
    body=$(echo "$pr" | jq -r '.body // "" | gsub("\r";"")' | head -c 2000)
    PR_CONTEXT+=$'\n'"## PR #$n: $title"$'\n'"$body"$'\n'
  done <<< "$PR_NUMS"
fi

COMMIT_SHORTLOG=$(git log "$SINCE_TAG..$HEAD_REF" --no-merges --pretty='- %s' | head -n 60)
DIFFSTAT=$(git diff --stat "$SINCE_TAG..$HEAD_REF" | tail -n 40)

EXEMPLAR_FILE="$REPO_ROOT/dist/release-notes/$PREV_VERSION.md"
EXEMPLAR=""
[[ -f "$EXEMPLAR_FILE" ]] && EXEMPLAR=$(cat "$EXEMPLAR_FILE")

# ---- mechanical scaffold (fallback) -----------------------------------------

emit_scaffold() {
  local body
  if [[ -n "$PR_CONTEXT" ]]; then
    body=$(echo "$PR_CONTEXT" | sed -nE 's/^## PR #[0-9]+: (.*)/  <li>\1<\/li>/p')
  else
    body=$(echo "$COMMIT_SHORTLOG" | sed -E 's/^- (.*)/  <li>\1<\/li>/')
  fi
  [[ -n "$body" ]] || body="  <li><!-- no changes detected since $SINCE_TAG --></li>"
  cat <<EOF
<h2>SherlockEQ $VERSION</h2>

<p>
  <!-- WRITE THE USER-FACING SUMMARY HERE. 1–3 sentences. -->
</p>

<h3>Changes</h3>

<ul>
$body
</ul>

<h3>Not a medical device</h3>

<p>
  SherlockEQ is not a healthcare or medical application. It does not diagnose,
  treat, measure, or monitor any hearing condition, tinnitus, or disability.
  For concerns about your hearing, consult a doctor, audiologist, or licensed
  healthcare professional.
</p>

<h3>Previous release</h3>

<p>
  See the
  <a href="$REPO_URL/releases/tag/$SINCE_TAG">$PREV_VERSION release notes</a>
  for what shipped in the prior version.
</p>
EOF
}

if ! command -v claude >/dev/null; then
  echo "draft-release-notes: claude CLI not found — emitting mechanical scaffold" >&2
  emit_scaffold
  exit 0
fi

# ---- LLM draft --------------------------------------------------------------

PROMPT=$(cat <<EOF
You are writing the user-facing release notes for SherlockEQ, a macOS menu-bar
app that applies a personal equalizer / hearing-comfort correction to all
system audio and tracks listening dose. It is NOT a medical device — never
imply it diagnoses, treats, or measures any hearing condition.

Write the release notes for version $VERSION. The previous shipped version was
$PREV_VERSION.

Output requirements — follow EXACTLY:
- Output ONLY the notes as HTML. No markdown code fences, no preamble, no
  trailing commentary. The very first characters must be "<h2>".
- Start with: <h2>SherlockEQ $VERSION</h2>
- Then a <p> intro of 1–3 sentences summarizing the release for an end user.
- Then one or more of <h3>Added</h3>, <h3>Changed</h3>, <h3>Fixed</h3> (only
  the ones that apply, in that order), each followed by a <ul> of <li> items.
- Each <li> starts with a bold <strong>short title.</strong> then a sentence or
  two in plain, user-facing language describing the benefit — NOT the
  implementation. Translate engineering descriptions into what the user gets.
- End with EXACTLY these two sections, verbatim structure, matching the
  exemplar below:
    <h3>Not a medical device</h3> ... (the standard disclaimer paragraph)
    <h3>Previous release</h3> ... linking to
    $REPO_URL/releases/tag/$SINCE_TAG with link text "$PREV_VERSION release notes".
- Group related changes; omit purely internal/CI/release-plumbing changes.

Here is the previous version notes file as the STYLE EXEMPLAR to match (tone,
structure, and the two trailing boilerplate sections verbatim):
-----
$EXEMPLAR
-----

Here are the changes shipped since $PREV_VERSION.

Merged pull requests (title + description):
$PR_CONTEXT

Commit shortlog (no-merge commits in range):
$COMMIT_SHORTLOG

Files changed (diffstat):
$DIFFSTAT
EOF
)

DRAFT=$(claude -p "$PROMPT" 2>/dev/null) || {
  echo "draft-release-notes: claude draft failed — emitting mechanical scaffold" >&2
  emit_scaffold
  exit 0
}

# Sanitize: strip any code fences and drop anything before the first <h2>.
CLEANED=$(printf '%s\n' "$DRAFT" | python3 -c '
import re, sys
t = sys.stdin.read()
t = re.sub(r"\x60{3}[a-zA-Z]*", "", t)
i = t.find("<h2")
if i == -1:
    sys.exit(1)
sys.stdout.write(t[i:].strip() + "\n")
') || {
  echo "draft-release-notes: draft had no <h2> — emitting mechanical scaffold" >&2
  emit_scaffold
  exit 0
}

printf '%s\n' "$CLEANED"
