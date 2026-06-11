# sherlockeq — command-line interface

A power-user / automation surface for the SherlockEQ macOS app. It is **not** a
replacement for the GUI: the running app stays the single source of truth. The
CLI sends a command to the app over a local `CFMessagePort`; the app reads or
changes its own state through the same code paths the GUI uses, so the GUI
updates live. No telemetry, no network, nothing medical.

## Install

The binary ships inside the app at `SherlockEQ.app/Contents/Helpers/sherlockeq`.

- **Homebrew:** `brew install --cask sherlockeq` puts `sherlockeq` on your PATH.
- **Otherwise:** run it once from the bundle and symlink it:
  `"/Applications/SherlockEQ.app/Contents/Helpers/sherlockeq" install`
  (defaults to `/usr/local/bin`; `--prefix ~/.local/bin` to choose another dir;
  `uninstall` removes the link).

## Commands

```
sherlockeq status                         # running? processing? profile, device, bypass, gain, balance, EQ
sherlockeq launch                         # launch the app if not running
sherlockeq quit                           # quit the running app
sherlockeq bypass on|off|toggle           # Reference Mode (bypass)
sherlockeq profiles list                  # list profiles (* = active)
sherlockeq profiles active                # active profile
sherlockeq profiles activate <name>       # switch profile
sherlockeq profiles import <file>         # import a profile JSON
sherlockeq profiles export <name> <file>  # export one profile
sherlockeq profiles export --all <file>   # export all profiles (JSON array)
sherlockeq devices list                   # output devices (* = current)
sherlockeq devices current                # current output device
sherlockeq gain get | set <db>            # master gain, -60…+12 dB
sherlockeq balance get | set <value>      # stereo balance, -1…1
sherlockeq simple-eq get                  # bass / mid / treble
sherlockeq simple-eq set --bass <db> --mid <db> --treble <db>
sherlockeq diagnostics                    # structured JSON snapshot for bug reports
sherlockeq reset --settings [--yes]       # reset app settings to defaults (keeps profiles)
```

Global flags: `--help`, `--version`, `--json` (machine-readable output on most
commands; `diagnostics` is always JSON).

## Exit codes

| code | meaning                                        |
|------|------------------------------------------------|
| 0    | success (incl. `status` when app isn't running)|
| 1    | generic failure                                |
| 2    | usage error (bad arguments)                    |
| 3    | SherlockEQ not running / unreachable           |
| 4    | not found (profile / device / no active profile)|
| 5    | invalid argument value                         |

## Building

`dist/build-cli.sh` builds a universal release binary; `dist/release.sh` embeds
and signs it into the app bundle. For local dev: `swift build` then
`.build/debug/sherlockeq`.
