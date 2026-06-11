#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# SherlockEQ release driver.
#
# One-shot release flow with a hand-off in the middle for PR review. State is
# detected from git, so the same command runs prep before the PR and publish
# after the merge:
#
#   dist/ship.sh <version>                # default editor for release notes
#   dist/ship.sh <version> --notes <file> # use a prewritten markdown file
#   dist/ship.sh <version> --notes -      # read from stdin
#
# Phases
#   PREP    (no release/<version> branch on origin)
#     write notes → sync in-app Help notes → regen web changelog → bump
#     versions → commit → push branch → open PR → exit. Re-run after merge.
#
#   PUBLISH (release/<version> branch exists on origin, PR is merged)
#     dist/release.sh → dist/appcast-publish.sh → tag → GitHub release →
#     push appcast to snxt.ai repo (if configured) → print cask update steps.
#
# Required env (inherited by dist/release.sh):
#   DEVELOPER_ID    Full identity, e.g. "Developer ID Application: Shawn Brown (X)"
#   TEAM_ID         10-char Apple team id
#   NOTARY_PROFILE  notarytool keychain profile name
#
# Optional env:
#   SNXT_REPO_PATH         Local checkout of smbrownai/next (appcast host).
#                          Default below. Unset → script prints the commands.
#   SHERLOCKEQ_CASK_PATH   Local checkout of smbrownai/homebrew-sherlockeq.
#                          Default below. Unset or path missing → script
#                          prints the manual update commands instead of
#                          pushing.
#
# Safety
#   set -euo pipefail; every irreversible step asks for confirmation; phase
#   detection means re-running mid-flow doesn't redo a step that already landed.
# -----------------------------------------------------------------------------
set -euo pipefail

# ---- args + env --------------------------------------------------------------

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") <version> [--notes <file|-->]

  <version>             semver like 1.0.0 or 1.0.0-beta.1
  --notes <file>        use prewritten release notes from <file>
  --notes -             read release notes from stdin
  (no --notes flag)     open \$EDITOR with a template

env:
  DEVELOPER_ID, TEAM_ID, NOTARY_PROFILE   passed through to dist/release.sh
  SNXT_REPO_PATH                          local smbrownai/next checkout
  SHERLOCKEQ_CASK_PATH                    local smbrownai/homebrew-sherlockeq
EOF
  exit 2
}

VERSION=""
NOTES_INPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --notes)
      [[ $# -ge 2 ]] || { echo "error: --notes needs an argument" >&2; usage; }
      NOTES_INPUT="$2"; shift 2 ;;
    -*)
      echo "error: unknown flag $1" >&2; usage ;;
    *)
      if [[ -z "$VERSION" ]]; then VERSION="$1"; shift
      else echo "error: unexpected arg $1" >&2; usage; fi ;;
  esac
done

[[ -n "$VERSION" ]] || usage

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
  echo "error: version must look like 1.0.0 or 1.0.0-beta.1, got: $VERSION" >&2
  exit 2
fi

: "${SNXT_REPO_PATH:=$HOME/code/next}"
: "${SHERLOCKEQ_CASK_PATH:=$HOME/code/homebrew-sherlockeq}"

# ---- paths -------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BRANCH="release/$VERSION"
TAG="v$VERSION"
NOTES_FILE="$REPO_ROOT/dist/release-notes/$VERSION.md"
HELP_NOTES_DOC="$REPO_ROOT/SherlockEQ/Documentation/release-notes.md"
PBXPROJ="$REPO_ROOT/SherlockEQ.xcodeproj/project.pbxproj"
WEB_INDEX="$REPO_ROOT/web/index.html"
DMG="$REPO_ROOT/dist/build/SherlockEQ-$VERSION.dmg"
APPCAST="$REPO_ROOT/dist/appcast.xml"
CASK_FILE="$REPO_ROOT/dist/homebrew/sherlockeq.rb"

# ---- helpers -----------------------------------------------------------------

bold()    { printf "\033[1m%s\033[0m\n" "$*"; }
ok()      { printf "  \033[32m✓\033[0m %s\n" "$*"; }
info()    { printf "  \033[36m·\033[0m %s\n" "$*"; }
warn()    { printf "  \033[33m!\033[0m %s\n" "$*" >&2; }
die()     { printf "  \033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }

step()    { printf "\n"; bold "==> $*"; }

confirm() {
  # confirm "prompt" — return 0 on yes, exit on no.
  local prompt="$1" reply
  read -r -p "    $prompt [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) die "aborted" ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null || die "missing required command: $1"
}

# Look for `prev_version <new_version>` in a tracked file. Returns 0 if the
# new version is present (already bumped), 1 if it is not.
file_has_version() {
  local file="$1" version="$2"
  grep -qF "$version" "$file"
}

# ---- preflight ---------------------------------------------------------------

step "Preflight"

require_cmd git
require_cmd gh
require_cmd xcodebuild
require_cmd shasum

git rev-parse --is-inside-work-tree >/dev/null || die "not a git repo"
git fetch --quiet --tags origin

# Reject re-shipping a tagged version. The script flow is one-version-per-run.
if git rev-parse "$TAG" >/dev/null 2>&1; then
  die "tag $TAG already exists locally — version was already shipped"
fi
if git ls-remote --tags origin "$TAG" | grep -q .; then
  die "tag $TAG already exists on origin — version was already shipped"
fi

ok "git, gh, xcodebuild present"
ok "tag $TAG not yet shipped"

# ---- phase detection ---------------------------------------------------------
#
# Decide PREP vs PUBLISH from the release PR, not just the branch. A repo
# with "auto-delete branch on merge" enabled removes release/<version> the
# instant the PR merges, so keying purely on the remote branch sends every
# post-merge re-run back into PREP (it then dies at "no changes to commit").
# `gh pr view <ref>` keeps resolving the PR by its head-ref name even after
# the branch is gone, so a MERGED PR is the authoritative PUBLISH signal:
#
#   merged PR for release/<version>        → PUBLISH  (branch may be gone)
#   no branch on origin, no merged PR      → PREP
#   branch on origin, PR open              → exit, tell user to merge
#   branch on origin, PR closed unmerged   → exit, tell user to investigate
#
# Preflight already aborted if the tag existed, so reaching here with a
# merged PR guarantees the tag isn't shipped yet — the release content is on
# main and ready to publish.

step "Detecting phase"

REMOTE_BRANCH_EXISTS=0
if git ls-remote --heads origin "$BRANCH" | grep -q .; then
  REMOTE_BRANCH_EXISTS=1
fi

# Resolve the PR tied to this release branch's head ref. `gh pr view` works
# by ref name even after the branch is auto-deleted post-merge; an empty
# PR_STATE means gh found no PR for the ref at all.
PR_NUMBER=""
PR_STATE=""
PR_URL=""
if PR_JSON=$(gh pr view "$BRANCH" --json number,state,mergedAt,url 2>/dev/null); then
  PR_NUMBER=$(echo "$PR_JSON" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["number"])')
  PR_STATE=$(echo "$PR_JSON" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["state"])')
  PR_URL=$(echo "$PR_JSON" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["url"])')
fi

PHASE=""

if [[ "$PR_STATE" == "MERGED" ]]; then
  # Merged PR is authoritative whether or not the branch still exists.
  PHASE="publish"
  if (( REMOTE_BRANCH_EXISTS == 1 )); then
    info "PR #$PR_NUMBER is merged — running PUBLISH"
  else
    info "PR #$PR_NUMBER is merged (branch auto-deleted on merge) — running PUBLISH"
  fi
elif (( REMOTE_BRANCH_EXISTS == 0 )); then
  # No branch on origin and no merged PR for it → this version isn't prepped.
  PHASE="prep"
  info "no $BRANCH on origin, no merged PR — running PREP"
else
  # Branch is live on origin; act on the current PR state.
  case "$PR_STATE" in
    OPEN)
      warn "PR #$PR_NUMBER is OPEN. Merge it first, then re-run this script."
      echo "      $PR_URL" >&2
      exit 0
      ;;
    CLOSED)
      die "PR #$PR_NUMBER is CLOSED without merge ($PR_URL). Reopen + merge, or delete branch."
      ;;
    "")
      die "branch $BRANCH exists on origin but no PR is open for it. Investigate manually."
      ;;
    *)
      die "branch $BRANCH exists on origin but PR state is '$PR_STATE'. Investigate manually."
      ;;
  esac
fi

# =============================================================================
# PREP PHASE
# =============================================================================

if [[ "$PHASE" == "prep" ]]; then

  step "Prep sanity"
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [[ "$CURRENT_BRANCH" != "main" ]]; then
    warn "currently on '$CURRENT_BRANCH', expected 'main'"
    confirm "continue anyway?"
  fi

  PREV_VERSION=$(git tag --list 'v*' --sort=-v:refname | head -n1 | sed 's/^v//')
  [[ -n "$PREV_VERSION" ]] || PREV_VERSION="(none)"
  info "previous shipped version: $PREV_VERSION"
  info "shipping:                 $VERSION"

  # ---- step 1: release notes ------------------------------------------------
  #
  # Notes first per "highest-friction artifact deserves first attention".
  # Three input modes; all converge to NOTES_FILE on disk before we touch
  # anything else.

  step "Release notes"

  if [[ -f "$NOTES_FILE" ]]; then
    info "$NOTES_FILE already exists"
    confirm "use existing file (no = abort and edit by hand)?"
  else
    case "$NOTES_INPUT" in
      "")
        # No --notes flag → open editor with template.
        TEMPLATE=$(mktemp -t sherlockeq-notes.XXXXXX.md)
        {
          cat <<EOF
<!--
  Release notes for SherlockEQ $VERSION.
  Lines starting with "<!--" are stripped before commit.
  Markdown is fine; first paragraph becomes the git commit body.
-->

<h2>SherlockEQ $VERSION</h2>

<!-- WRITE THE USER-FACING SUMMARY HERE. 1–3 sentences. -->

<h3>Changes</h3>

<ul>
  <li><!-- one bullet per user-visible change --></li>
</ul>
EOF
          if [[ "$PREV_VERSION" != "(none)" ]] \
             && [[ -f "$REPO_ROOT/dist/release-notes/$PREV_VERSION.md" ]]; then
            echo
            echo "<!-- ===== Previous version ($PREV_VERSION) for reference (will be stripped) ====="
            cat "$REPO_ROOT/dist/release-notes/$PREV_VERSION.md"
            echo "===== end previous version ===== -->"
          fi
        } > "$TEMPLATE"

        EDITOR_CMD="${EDITOR:-vi}"
        info "opening \$EDITOR ($EDITOR_CMD)..."
        "$EDITOR_CMD" "$TEMPLATE"

        # Strip HTML comments before saving — the only HTML comments in the
        # template are the instructional ones; legitimate content uses Sparkle
        # release-note tags like <h2>, not comments.
        python3 - "$TEMPLATE" "$NOTES_FILE" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
text = re.sub(r'<!--.*?-->', '', text, flags=re.DOTALL)
text = re.sub(r'\n{3,}', '\n\n', text).strip() + '\n'
open(dst, 'w').write(text)
PY
        rm -f "$TEMPLATE"
        ;;
      "-")
        info "reading notes from stdin (Ctrl-D to end)"
        mkdir -p "$(dirname "$NOTES_FILE")"
        cat > "$NOTES_FILE"
        ;;
      *)
        [[ -f "$NOTES_INPUT" ]] || die "--notes file not found: $NOTES_INPUT"
        mkdir -p "$(dirname "$NOTES_FILE")"
        cp "$NOTES_INPUT" "$NOTES_FILE"
        ;;
    esac
  fi

  # Reject empty / template-only notes — a forgotten edit shouldn't produce
  # an empty release announcement.
  if ! grep -qE '\S' "$NOTES_FILE"; then
    die "release notes are empty: $NOTES_FILE"
  fi
  WORD_COUNT=$(wc -w < "$NOTES_FILE")
  if (( WORD_COUNT < 10 )); then
    warn "release notes are very short ($WORD_COUNT words)"
    confirm "ship with this?"
  fi
  ok "release notes saved to $NOTES_FILE"

  # ---- step 2: sync in-app Help release notes (idempotent) ------------------
  #
  # The HTML notes above ship via Sparkle/GitHub; the in-app Help article
  # (bundled into the app) is Markdown and used to be hand-updated, so it
  # drifted. Convert + insert here in PREP so the updated article rides along
  # in the release commit/PR and is present at build time in PUBLISH.
  # Non-fatal: a hiccup converting the in-app changelog shouldn't block a
  # release — the maintainer can fix the article by hand and re-run.

  step "Help release notes"

  if python3 "$REPO_ROOT/dist/help-release-notes.py" \
       "$VERSION" "$NOTES_FILE" "$HELP_NOTES_DOC"; then
    ok "in-app Help release notes synced ($HELP_NOTES_DOC)"
  else
    warn "could not sync in-app Help release notes — update $HELP_NOTES_DOC by hand"
    confirm "continue the release without the in-app changelog update?"
  fi

  # Regenerate the website changelog page (web/release-notes.html) from all
  # dist/release-notes/*.md. Lands in the release commit/PR here; the PUBLISH
  # web-sync step mirrors it to snxt.ai. Non-fatal, same as above.
  if python3 "$REPO_ROOT/dist/web-release-notes.py"; then
    ok "website release-notes page regenerated (web/release-notes.html)"
  else
    warn "could not regenerate web/release-notes.html — check it by hand"
    confirm "continue the release without the website changelog update?"
  fi

  # ---- step 3: version bumps (idempotent) -----------------------------------

  step "Version bumps"

  if grep -qE "MARKETING_VERSION = $VERSION;" "$PBXPROJ"; then
    info "pbxproj already at $VERSION"
  else
    # Two MARKETING_VERSION lines (Debug + Release configs); both bumped.
    /usr/bin/sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
    ok "pbxproj bumped to $VERSION"
  fi

  # web/index.html: two known references — meta-row badge "v<X>" and install
  # card filename "SherlockEQ-<X>.dmg". The PREV_VERSION sniff makes this
  # idempotent (re-running won't re-replace).
  if file_has_version "$WEB_INDEX" "v$VERSION " \
     && file_has_version "$WEB_INDEX" "SherlockEQ-$VERSION.dmg"; then
    info "web/index.html already at $VERSION"
  elif [[ "$PREV_VERSION" != "(none)" ]]; then
    /usr/bin/sed -i '' \
      -e "s/v$PREV_VERSION /v$VERSION /g" \
      -e "s/SherlockEQ-$PREV_VERSION\.dmg/SherlockEQ-$VERSION.dmg/g" \
      "$WEB_INDEX"
    ok "web/index.html bumped from $PREV_VERSION to $VERSION"
  else
    warn "no previous version to derive substitution from; web/index.html left alone"
    info "edit web/index.html by hand if it has stale version strings"
  fi

  # ---- step 4: confirm working tree -----------------------------------------

  step "Working tree to be committed"

  git status --short
  echo
  if [[ -z "$(git status --porcelain)" ]]; then
    die "no changes to commit — nothing to release"
  fi

  warn "the above files will all go into the '$VERSION' commit"
  confirm "include them?"

  # ---- step 5: branch + commit + push + PR ----------------------------------

  step "Branch, commit, push, PR"

  if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    info "local branch $BRANCH already exists — switching to it"
    git switch "$BRANCH"
  else
    git switch -c "$BRANCH"
    ok "created $BRANCH"
  fi

  # Commit subject = "Release <version>". Body = first paragraph of notes.
  COMMIT_BODY=$(python3 - "$NOTES_FILE" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
# Strip HTML tags for the commit body; the markdown / Sparkle markup is for the
# release note and PR description, not the git log.
text = re.sub(r'<[^>]+>', '', text)
paras = [p.strip() for p in re.split(r'\n\s*\n', text) if p.strip()]
print(paras[0] if paras else '')
PY
)

  git add -A
  git commit -m "Release $VERSION" -m "$COMMIT_BODY"
  ok "committed Release $VERSION"

  git push -u origin "$BRANCH"
  ok "pushed $BRANCH"

  PR_URL=$(gh pr create \
    --base main \
    --head "$BRANCH" \
    --title "Release $VERSION" \
    --body-file "$NOTES_FILE")
  ok "PR opened: $PR_URL"

  cat <<EOF

  Next:
    1. Review the PR and merge it.
    2. Re-run: dist/ship.sh $VERSION
       (no flags needed — same command picks up the publish phase
        once it sees the PR is merged.)

EOF
  exit 0
fi

# =============================================================================
# PUBLISH PHASE
# =============================================================================

if [[ "$PHASE" == "publish" ]]; then

  step "Publish sanity"

  : "${DEVELOPER_ID:?set DEVELOPER_ID for dist/release.sh}"
  : "${TEAM_ID:?set TEAM_ID for dist/release.sh}"
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE for dist/release.sh}"

  # Working tree must be clean before any branch movement.
  [[ -z "$(git status --porcelain)" ]] || die "working tree dirty — clean before publish"

  # Auto-switch to main: the PR is already merged (we checked in phase
  # detection), so the release branch we're sitting on is fully reflected
  # in origin/main. Switching + fast-forward pull is the safe move.
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [[ "$CURRENT_BRANCH" != "main" ]]; then
    info "currently on '$CURRENT_BRANCH'; switching to main (PR is merged)"
    git checkout main
  fi

  git fetch --quiet origin main
  git pull --ff-only origin main
  ok "on main, clean, up to date with origin"

  [[ -f "$NOTES_FILE" ]] || die "release notes missing: $NOTES_FILE (was the PR merged into main?)"
  ok "release notes present"

  # ---- step 1: build, notarize, dmg ------------------------------------------

  step "Build + notarize (dist/release.sh)"
  info "this can take several minutes (notary wait)"
  bash "$REPO_ROOT/dist/release.sh" "$VERSION"
  [[ -f "$DMG" ]] || die "release.sh did not produce $DMG"
  DMG_SHA=$(awk '{print $1}' "${DMG}.sha256")

  # ---- step 2: appcast -------------------------------------------------------

  step "Appcast (dist/appcast-publish.sh)"
  if [[ -x "$REPO_ROOT/dist/appcast-publish.sh" ]]; then
    bash "$REPO_ROOT/dist/appcast-publish.sh" "$VERSION" "$NOTES_FILE"
    ok "appcast.xml updated"
  else
    warn "dist/appcast-publish.sh not found or not executable — skipping appcast regen"
  fi

  # ---- step 3: bump local cask ----------------------------------------------
  #
  # The cask `version` + `sha256` are the only two values that change per
  # release. Bumping the in-repo reference here so it never drifts from the
  # tap (a prior release shipped only after we noticed the local file was
  # stale). Idempotent: a re-run sees the new values already in place.

  step "Bump local cask"
  if grep -qE "^  version \"$VERSION\"\$" "$CASK_FILE" \
     && grep -qE "^  sha256 \"$DMG_SHA\"\$" "$CASK_FILE"; then
    info "cask already at $VERSION / matching sha256"
  else
    /usr/bin/sed -i '' -E \
      -e "s/^  version \"[^\"]+\"/  version \"$VERSION\"/" \
      -e "s/^  sha256 \"[^\"]+\"/  sha256 \"$DMG_SHA\"/" \
      "$CASK_FILE"
    ok "cask bumped to $VERSION / $DMG_SHA"
  fi

  # ---- step 4: commit bookkeeping to main -----------------------------------
  #
  # Single combined commit for the two release-bookkeeping artifacts: appcast
  # (changelog entry) and cask (version + sha256). Tagging happens AFTER this
  # so the tag points at a tree that includes both — keeping `git checkout
  # v$VERSION` self-consistent with what users actually got.

  step "Commit bookkeeping → main"
  git add "$APPCAST" "$CASK_FILE"
  if [[ -n "$(git diff --cached --name-only)" ]]; then
    git commit -m "Release $VERSION bookkeeping: appcast + cask"
    git push origin main
    ok "bookkeeping commit pushed to main"
  else
    info "appcast + cask unchanged — nothing to commit"
  fi

  # ---- step 5: tag + push ---------------------------------------------------

  step "Tag + push"
  git tag -a "$TAG" -m "Release $VERSION"
  git push origin "$TAG"
  ok "tag $TAG pushed"

  # ---- step 6: GitHub release ------------------------------------------------

  step "GitHub release"
  gh release create "$TAG" "$DMG" \
    --title "SherlockEQ $VERSION" \
    --notes-file "$NOTES_FILE"
  ok "GitHub release created"

  # ---- step 7: appcast to snxt.ai repo --------------------------------------

  step "Appcast → smbrownai/next"
  if [[ -d "$SNXT_REPO_PATH/.git" ]]; then
    info "pushing appcast.xml to $SNXT_REPO_PATH"
    (
      cd "$SNXT_REPO_PATH"
      git fetch --quiet origin
      git checkout main 2>/dev/null || git checkout master
      git pull --ff-only
      cp "$APPCAST" appcast.xml
      git add appcast.xml
      if [[ -n "$(git status --porcelain)" ]]; then
        git commit -m "SherlockEQ $VERSION appcast"
        git push
        echo "    ✓ appcast pushed to smbrownai/next"
      else
        echo "    · appcast unchanged — nothing to push"
      fi
    )
  else
    warn "SNXT_REPO_PATH ($SNXT_REPO_PATH) is not a git repo — skipping auto-push"
    info "manual commands:"
    cat <<EOF
        cp $APPCAST <snxt-next-repo>/appcast.xml
        cd <snxt-next-repo>
        git add appcast.xml
        git commit -m "SherlockEQ $VERSION appcast"
        git push
EOF
  fi

  # ---- step 8: cask to tap repo ---------------------------------------------
  #
  # Mirrors the snxt.ai push pattern. The tap repo's Casks/sherlockeq.rb is
  # what `brew upgrade` actually consults — pushing here is what makes the
  # release visible to Homebrew users.

  step "Cask → smbrownai/homebrew-sherlockeq"
  if [[ -d "$SHERLOCKEQ_CASK_PATH/.git" ]]; then
    info "pushing Casks/sherlockeq.rb to $SHERLOCKEQ_CASK_PATH"
    (
      cd "$SHERLOCKEQ_CASK_PATH"
      git fetch --quiet origin
      git checkout main 2>/dev/null || git checkout master
      git pull --ff-only
      mkdir -p Casks
      cp "$CASK_FILE" Casks/sherlockeq.rb
      git add Casks/sherlockeq.rb
      if [[ -n "$(git status --porcelain)" ]]; then
        git commit -m "sherlockeq $VERSION"
        git push
        echo "    ✓ cask pushed to smbrownai/homebrew-sherlockeq"
      else
        echo "    · cask unchanged — nothing to push"
      fi
    )
  else
    warn "SHERLOCKEQ_CASK_PATH ($SHERLOCKEQ_CASK_PATH) is not a git repo — skipping auto-push"
    info "manual update:"
    cat <<EOF
        cp $CASK_FILE <tap-repo>/Casks/sherlockeq.rb
        cd <tap-repo>
        git add Casks/sherlockeq.rb
        git commit -m "sherlockeq $VERSION"
        git push
EOF
  fi

  # ---- step 9: web → smbrownai/next (PR, not direct push) -------------------
  #
  # The landing page at snxt.ai/SherlockEQ/ is sourced from this repo's web/
  # dir. Mirror it into next/SherlockEQ/ on a release branch and open a PR —
  # not a direct push, because page content (vs. mechanically-regenerated
  # data like appcast.xml) deserves a review window before going live.
  #
  # rsync excludes .DS_Store so macOS Finder noise doesn't slip into commits.
  # Skips cleanly if there's no diff after the sync — most releases don't
  # touch web/.

  step "Web → smbrownai/next (PR)"
  WEB_BRANCH="sherlockeq/$VERSION"
  if [[ -d "$SNXT_REPO_PATH/.git" ]]; then
    info "syncing web/ to $SNXT_REPO_PATH/SherlockEQ/"
    (
      cd "$SNXT_REPO_PATH"
      git fetch --quiet origin
      git checkout main 2>/dev/null || git checkout master
      git pull --ff-only

      # Make a clean branch from main. If a prior run already created one
      # for this version, refuse rather than clobber half-finished work.
      if git ls-remote --heads origin "$WEB_BRANCH" | grep -q .; then
        echo "    · branch $WEB_BRANCH already exists on origin — skipping (assume PR is open)"
        EXIT_CODE=0
        exit 0
      fi
      git checkout -b "$WEB_BRANCH"

      mkdir -p SherlockEQ
      rsync -a --exclude='.DS_Store' "$REPO_ROOT/web/" SherlockEQ/

      if [[ -z "$(git status --porcelain)" ]]; then
        echo "    · web/ unchanged since last release — no PR needed"
        git checkout main 2>/dev/null || git checkout master
        git branch -D "$WEB_BRANCH"
        exit 0
      fi

      git add SherlockEQ
      git commit -m "SherlockEQ $VERSION web update"
      git push -u origin "$WEB_BRANCH"

      PR_URL=$(gh pr create \
        --base main \
        --head "$WEB_BRANCH" \
        --title "SherlockEQ $VERSION — web update" \
        --body "Mirror of \`web/\` from smbrownai/SherlockEQ at v$VERSION. Source: https://github.com/smbrownai/SherlockEQ/blob/v$VERSION/web/index.html")
      echo "    ✓ web PR opened: $PR_URL"

      # Auto-merge: web/ changes for a typical release are just the
      # two version-bump strings (sed'd in PREP from web/index.html),
      # which the maintainer already reviewed in the SherlockEQ release
      # PR. Keeping the PR as a paper trail but landing it immediately
      # so snxt.ai picks up the new version without a manual step.
      if gh pr merge "$PR_URL" --squash --delete-branch; then
        echo "    ✓ web PR merged: $PR_URL"
      else
        warn "auto-merge of $PR_URL failed — merge it manually"
      fi
    )
  else
    warn "SNXT_REPO_PATH ($SNXT_REPO_PATH) is not a git repo — skipping web sync"
    info "manual web sync:"
    cat <<EOF
        cd <next-repo>
        git checkout -b sherlockeq/$VERSION
        rsync -a --exclude='.DS_Store' $REPO_ROOT/web/ SherlockEQ/
        git add SherlockEQ && git commit -m "SherlockEQ $VERSION web update"
        git push -u origin sherlockeq/$VERSION
        gh pr create --base main --title "SherlockEQ $VERSION — web update"
        gh pr merge --squash --delete-branch
EOF
  fi

  # ---- done ------------------------------------------------------------------

  cat <<EOF

  $(bold "released: SherlockEQ $VERSION")
    dmg:     $DMG
    sha256:  $DMG_SHA
    notes:   $NOTES_FILE
    tag:     $TAG
    release: https://github.com/smbrownai/SherlockEQ/releases/tag/$TAG

  Verify Sparkle pickup: open SherlockEQ → check for updates.

EOF
  exit 0
fi

die "unreachable: phase=$PHASE"
