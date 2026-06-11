---
title: "Command-Line Tool"
slug: "command-line-tool"
category: "Reference"
summary: "Drive the running app from the shell with the sherlockeq command — profiles, gain, balance, bypass, and JSON output for scripting."
keywords:
  - cli
  - command line
  - terminal
  - sherlockeq
  - scripting
  - automation
  - json
related:
  - profiles
  - output-devices
  - gain-volume
  - troubleshooting
---

# Command-Line Tool

`sherlockeq` is a small command-line front end to the running app. It talks to
the live app over local IPC, so every change it makes is reflected in the GUI
immediately and there is no separate state to keep in sync. Everything is
local — no network, no telemetry.

## Install

The binary ships inside the app bundle at
`SherlockEQ.app/Contents/Helpers/sherlockeq`. Symlink it onto your `PATH`:

```bash
/Applications/SherlockEQ.app/Contents/Helpers/sherlockeq install
```

`install` links into `/usr/local/bin` by default; pass `--prefix ~/.local/bin`
(or any writable dir) to choose another. `uninstall` removes the link.

After that, invoke it as `sherlockeq`. Add `--json` to most commands for
machine-readable output, and `--version` to print the tool version.

## The app must be running

Commands that read or change audio state need the app running and exit with
**code 3** if it isn't. `sherlockeq launch` starts it; `sherlockeq status`
always exits 0 and simply reports whether it's up. Other exit codes worth
scripting against: **4** (profile/device not found), **5** (value out of range
or bad arguments).

## Commands

### State & lifecycle

| Command | Does |
| --- | --- |
| `status` | Running state, active profile, device, bypass, gain, balance, simple EQ |
| `diagnostics` | Structured JSON snapshot for bug reports |
| `launch` / `quit` | Start or stop the app |

### Audio adjustments

| Command | Does |
| --- | --- |
| `bypass on\|off\|toggle` | Reference Mode (bypass all EQ) |
| `gain get` / `gain set <dB>` | Master gain, −60…+12 dB |
| `balance get` / `balance set <v>` | Stereo balance, −1 (L) … 0 … 1 (R) |
| `simple-eq get` / `simple-eq set` | Bass/Mid/Treble via `--bass`/`--mid`/`--treble`, −24…+24 dB |

### Profiles & devices

| Command | Does |
| --- | --- |
| `profiles list\|active\|activate <name>` | Inspect and switch [profiles](help:profiles) |
| `profiles import <file>` | Import a profile from JSON |
| `profiles export <name> <file>` / `export --all <file>` | Export one profile or all |
| `devices list\|current` | List or show [output devices](help:output-devices) |

### Maintenance

| Command | Does |
| --- | --- |
| `reset --settings [--yes]` | Reset app settings to defaults (profiles kept) |
| `install` / `uninstall` | Manage the `PATH` symlink |

Run `sherlockeq <command> --help` for the full options on any command.

## Example workflows

### Switch to a call profile when a meeting starts

Wrap your meeting app so SherlockEQ flips to a dialogue-tuned profile and a
gentler level while you're in the call, then reverts on exit:

```bash
#!/usr/bin/env bash
sherlockeq profiles activate "Voice Call"
sherlockeq gain set -4
open -W -a "zoom.us"          # blocks until the call app quits
sherlockeq profiles activate "Headphones — evening"
sherlockeq gain set 0
```

### Back up every profile on a schedule

Export all profiles to a dated JSON file — drop this in `cron` or a launchd
job for an automatic nightly backup you can re-import on any machine:

```bash
sherlockeq profiles export --all "$HOME/Backups/sherlockeq-$(date +%F).json"
```

Re-seeding a fresh install is the inverse: `sherlockeq profiles import <file>`.

### Bind a bypass toggle to a hotkey, with a status check

Point a hotkey tool (skhd, Raycast, a Stream Deck) at a one-liner to A/B your
EQ against the untouched signal from anywhere:

```bash
sherlockeq bypass toggle
```

For dashboards or scripts, read state as JSON and pull fields with `jq`:

```bash
sherlockeq status --json | jq -r '.profile.name, .bypass, .gainDB'
```

## See also

If a command reports the app as unreachable, see
[Troubleshooting](help:troubleshooting).
