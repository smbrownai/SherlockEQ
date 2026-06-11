---
title: "Troubleshooting"
slug: "troubleshooting"
category: "Reference"
summary: "Fixes for no audio, distortion, dead meters, missing devices, Bluetooth delay, permissions, and updates."
keywords:
  - troubleshooting
  - no audio
  - distortion
  - permissions
  - bluetooth
  - reset
  - uninstall
related:
  - getting-started
  - output-devices
  - privacy-local-data
  - safety-limits
---

# Troubleshooting

## No audio is being processed / meters don't move

This is almost always a **permissions** issue.

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording** (on macOS 14 it's grouped under **Screen Recording**).
2. Enable **SherlockEQ**.
3. **Quit and relaunch** the app — the grant takes effect on restart.

Without this grant SherlockEQ receives silence, so the meters stay flat. Also
confirm the correct [output device](help:output-devices) is selected and your
system volume isn't muted.

## Distorted audio

Distortion usually means **clipping** from too much boost.

- Reduce EQ boosts; prefer **cuts** plus modest make-up [gain](help:gain-volume).
- Lower the master gain.
- Remove or reduce a [headphone correction](help:headphone-correction-autoeq) preamp that's been deleted (the preamp leaves headroom for the correction's boosts).

See [Safety](help:safety-limits).

## VU meters not moving

- Check the system-audio permission above.
- Make sure audio is actually playing to the device SherlockEQ is processing.
- Confirm SherlockEQ isn't in a state where the output device disappeared (re-select it).

## Output device not appearing

- Reconnect the device, then re-open the device picker.
- For Bluetooth, make sure it's connected in **System Settings → Bluetooth** first.
- Some input-only or aggregate devices are intentionally filtered out of the output list.

## Bluetooth delay (audio lags video)

Bluetooth adds inherent **latency**. For tight A/V sync, use wired output. See
[Output Devices](help:output-devices).

## App isn't affecting system audio

- Re-check the system-audio permission.
- Confirm a [profile](help:profiles) is active and **Reference Mode** (bypass) is off.
- Try toggling the output device to force the chain to rebuild.

## macOS version requirements

SherlockEQ relies on Core Audio system-audio capture introduced in recent macOS.
If features are missing, update macOS to a supported version.

## "Unverified developer" / Gatekeeper warning

If macOS warns about an unidentified developer for a downloaded build, the app
may need to be opened via **right-click → Open** the first time, or allowed in
**Privacy & Security**. Official notarized releases shouldn't show this.

## Reset settings

- To reset a single setup, duplicate a built-in [profile](help:profiles) and start fresh.
- To clear everything, quit SherlockEQ and remove `~/Library/Application Support/SherlockEQ/` (this deletes your profiles — export first if you want backups). See [Privacy & Local Data](help:privacy-local-data).

## Uninstall

Quit SherlockEQ, move the app to the Trash, and (optionally) remove
`~/Library/Application Support/SherlockEQ/`. Revoke its entries under
**Privacy & Security** if you wish.

## Homebrew install / update issues

If installed via Homebrew Cask, update with `brew update` then
`brew upgrade --cask sherlockeq`. If a cask update fails, reinstalling the cask
usually resolves it.

## References

See [References](help:references).
