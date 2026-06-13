# Release tooling (`dist/`)

Everything needed to cut a SherlockEQ release. The entry point is
[`ship.sh`](ship.sh); the other scripts are steps it calls (or that you can run
standalone). Start here, then read the header comment in any script for detail.

## The one command

```bash
dist/ship.sh <version>                # e.g. dist/ship.sh 0.4.0
dist/ship.sh <version> --notes <file> # use prewritten release notes
dist/ship.sh <version> --notes -      # read notes from stdin
```

`ship.sh` is **two phases in one command**, auto-detected from git state — you
run the *same* command twice, with a PR review in between:

```
  PREP    ──►  open release PR  ──►  [you review + merge]  ──►  PUBLISH
  (1st run)                                                     (2nd run)
```

Phase is decided by the release PR, not the branch (the repo auto-deletes
merged branches):

- **no merged `release/<version>` PR** → PREP
- **`release/<version>` PR is merged** → PUBLISH

So a post-merge re-run of the identical command picks up PUBLISH automatically.

## Before you start (prerequisites)

1. **All feature PRs for this version are merged into `origin/main`.** A release
   ships whatever is on `main` — nothing else. Merge first, release second.
2. **Run from an interactive shell** (your normal terminal), not a
   non-interactive / CI / agent shell. The signing env vars below live in
   `~/.zshrc`, which non-interactive zsh does **not** source — PUBLISH will die
   at the signing step with a missing-variable error if they aren't set.
3. **`gh` is authenticated** (`gh auth status`) — PREP opens a PR, PUBLISH
   creates the GitHub release, and the notes drafter reads merged-PR bodies.
4. **`claude` CLI on PATH** (optional) — used to auto-draft release notes. If
   absent, PREP falls back to a mechanical PR/commit scaffold; the release
   still proceeds.

> **Note:** As of the fast-forward guard added after 0.4.0, PREP fetches and
> checks `main` against `origin/main` itself, fast-forwarding automatically when
> behind (and aborting if local `main` has unpushed commits). Before
> that, a stale local `main` (feature PRs merged on GitHub but never pulled)
> would silently cut a release with none of the new work in it. If you're on an
> older `ship.sh`, run `git checkout main && git pull --ff-only` first.

### Required environment (PUBLISH only — PREP doesn't need these)

| Variable | What it is |
|---|---|
| `DEVELOPER_ID` | Full signing identity, e.g. `Developer ID Application: Shawn Brown (TEAMID)` |
| `TEAM_ID` | 10-char Apple Team ID |
| `NOTARY_PROFILE` | `notarytool` keychain profile name (currently `SherlockEQ-Notary`) |
| `SNXT_REPO_PATH` | Local checkout of `smbrownai/next` (appcast + website host). Default `~/code/next` |
| `SHERLOCKEQ_CASK_PATH` | Local checkout of `smbrownai/homebrew-sherlockeq` (the tap). Default `~/code/homebrew-sherlockeq` |

If `SNXT_REPO_PATH` / `SHERLOCKEQ_CASK_PATH` aren't valid git repos, PUBLISH
prints the manual push commands instead of pushing.

## What each phase does

### PREP (first run)

1. **Sanity** — on `main`, and `main` is fast-forwarded to `origin/main`.
2. **Release notes** — uses `dist/release-notes/<version>.md` if it exists, or
   `--notes <file>`. Otherwise **auto-drafts** notes from the changes since the
   last tag (`draft-release-notes.sh`, below) and opens `$EDITOR` so you review
   and polish before they ship — the draft is a starting point, not the final
   word.
3. **Help + web changelogs** — regenerates the in-app Help article and the
   website changelog (see scripts below). These ride along in the release PR.
4. **Version bumps** — `project.pbxproj` (`MARKETING_VERSION`),
   `cli/.../Root.swift` (`cliVersion`), `web/index.html` (badge + DMG filename).
5. **Branch + commit + push + PR** — creates `release/<version>`, commits
   `Release <version>`, pushes, opens a PR against `main`. **Then stops.**

Review the PR and merge it before continuing.

### PUBLISH (re-run after merge)

1. **Sanity** — env vars present, clean tree, switch to `main`, ff-pull.
2. **Build + notarize + DMG** → `dist/release.sh`.
3. **Patch `web/index.html` DMG size** — the real size isn't known until the
   DMG is built, so PREP leaves the *previous* size as a placeholder and PUBLISH
   corrects it here. (This is why the size looks stale in the release PR — by
   design.)
4. **Appcast** → `dist/appcast-publish.sh`.
5. **Bump local cask** (`version` + `sha256`).
6. **Bookkeeping commit → `main`** (appcast + cask + web size).
7. **Tag + push** (`v<version>`).
8. **GitHub release** with the DMG attached.
9. **Mirror out** — appcast + cask pushed to their repos; `web/` synced to
   `smbrownai/next` as a **PR** (page content gets a review window; appcast/cask
   are mechanical and pushed directly).

## Scripts

| Script | Role |
|---|---|
| `ship.sh` | The driver. Run this. |
| `draft-release-notes.sh` | Draft user-facing HTML notes from the PRs/commits in `<prev-tag>..HEAD` via the `claude` CLI (mechanical scaffold fallback if absent). Seeds PREP's editor; runnable standalone: `dist/draft-release-notes.sh 0.5.0 > dist/release-notes/0.5.0.md`. Supports `--since <tag>` / `--head <ref>` to scope a range. |
| `release.sh` | Build → codesign → notarize → staple → DMG → sha256. Standalone-runnable. |
| `appcast-publish.sh` | Insert the new version into `appcast.xml` (Sparkle feed). |
| `help-release-notes.py` | Convert HTML notes → Markdown, insert into the in-app Help article newest-first. Idempotent. |
| `web-release-notes.py` | Regenerate `web/release-notes.html` from all `dist/release-notes/*.md`. |
| `build-cli.sh` | Build the `sherlockeq` CLI bundled into the app. Never edits sources. |
| `sparkle-keygen.sh` | One-time Sparkle EdDSA keypair generation. |

## Release-notes conventions

Files live in `dist/release-notes/<version>.md` and are HTML (embedded verbatim
in the appcast + GitHub release).

- **Start directly with `<h2>SherlockEQ <version></h2>`.** Do **not** lead with
  an `<!-- ... -->` comment block — when the file already exists on disk, PREP
  uses it verbatim and a leading comment leaks into the commit, PR, and appcast.
- Keep the trailing **"Not a medical device"** and **"Previous release"**
  `<h3>` sections — the Help/web converters strip exactly those two before
  embedding.
```
