---
title: "Release Notes"
slug: "release-notes"
category: "Reference"
summary: "What changed in this version of SherlockEQ, and where to find the full history."
keywords:
  - release notes
  - changelog
  - version
  - updates
  - whats new
related:
  - feature-guide
  - getting-started
  - troubleshooting
---

# Release Notes

The version this documentation corresponds to is shown at the bottom of the
help sidebar. Use **SherlockEQ → Check for Updates…** to get the latest build.

## 0.6.2

A bug-fix release focused on audio output reliability — especially when you use an audio interface or mixer, or switch between output devices.

**Fixed**

- **Audio interfaces and mixers now play correctly.** When the output device was an interface with its own inputs (for example a RØDECaster Pro II), SherlockEQ could play static or sound in only one ear. It now reads the correct audio channels regardless of the device's input layout.
- **Switching output devices is seamless.** Changing your output — speakers to an interface to headphones, and back — while audio is playing no longer leaves sound in a broken state that required relaunching the app. The audio engine now rebuilds cleanly on every device change.
- **Profiles survive an unavailable custom folder.** If you moved your profiles to a custom folder that later became unreachable (an unmounted drive, or a temporary location cleared on restart), SherlockEQ now falls back to the default folder and keeps your profiles instead of showing an empty list.

## 0.6.1

A visual refresh: SherlockEQ has a brand-new app icon, an updated onboarding video, and now follows your system accent colour.

**Changed**

- **New app icon.** A glassy lens over a glowing teal-to-blue waveform on a dark field, rendered cleanly at every size from the Dock down to the menu bar.
- **Refreshed onboarding video.** The intro that plays the first time you launch SherlockEQ has been re-recorded.
- **Follows your system accent colour.** SherlockEQ no longer forces its own gold accent — highlights, toggles, and sliders now use whatever accent colour you've chosen in System Settings.

## 0.6.0

This release sharpens the two parts of SherlockEQ that turn your input into sound: the audiogram-based personal correction now uses a real, citable prescription instead of a rough rule of thumb, and dragging EQ bands now produces clear, named undo steps so you can walk back individual tweaks without losing the rest of your edits.

**Added**

- **Descriptive undo for EQ band drags.** Adjusting a band in any of the EQ views now records an undo entry labeled with the band you actually changed — "Adjust Bass", "Adjust 1 kHz", and so on — instead of a generic "Edit". Quick back-to-back drags still coalesce into a single step, so one undo cleanly reverses one gesture.

**Changed**

- **More accurate audiogram-to-EQ correction.** The audiogram screen now derives your per-ear EQ from a well-established hearing-aid fitting prescription that is frequency-aware: it eases off in the low end where extra boost only muddies speech, and emphasizes the ranges where added clarity actually helps. The strength slider scales the whole prescription up or down so you can dial in what sounds best to you. If you already use an audiogram-based profile, it keeps its current correction until the next time you edit your audiogram — at which point it's recomputed with the new prescription.
- **Closely-spaced bands no longer over-boost.** At higher frequencies the audiogram's measurement points sit close together, and neighboring EQ bands overlap. SherlockEQ now compensates for that overlap when fitting the curve, so the sound you hear matches the target instead of stacking up into an exaggerated treble.

## 0.5.0

This release reworks the first-launch experience and the menu-bar popover. Onboarding now opens with a short intro video and ends with a clear "here's where SherlockEQ lives" wayfinding step, and the popover gains an obvious button for opening the main window.

**Added**

- **Intro video on the welcome screen.** Onboarding now opens with a short branded clip that plays once and holds on its final frame, giving new installs a proper first impression before the setup cards.
- **"You're all set" wayfinding step.** Onboarding now ends with a step that points at the menu-bar icon and the main window, so it's obvious where SherlockEQ went after the setup window closes — no more wondering whether it quit.
- **Explicit "Open Main Window" button in the popover.** The menu-bar popover now has a clearly labeled button at the bottom for opening the full main window, paired with Quit. The hard-to-spot arrow glyph in the header is gone.
- **Tagline, copyright, and license in the About panel.** Choosing "About SherlockEQ" from the app menu now shows "Find your sound.", a copyright line, and the MIT license notice under the version number.

**Changed**

- **Personalization step is now informational.** The audiogram, tinnitus, and calibration rows in onboarding used to deep-link out, which cut the walkthrough short. They now describe where each adjustment lives in the main window so you actually reach the final step.
- **Cleaner profile sidebar.** The tag pills (voice, music, clarity…) have been removed from the profile list rows so more profiles fit at a glance. The same tags still appear on the profile detail view.
- **Tidier popover footer.** "Open Main Window" and "Quit SherlockEQ" now share a single aligned layout and consistent text color, so the two actions read as a matched pair.
- **Updated acknowledgments.** Settings → Acknowledgments now credits Sparkle (the in-app updater), Swift Argument Parser (the bundled `sherlockeq` command-line tool), and App Intents (Shortcuts and Siri actions), and refreshes the copyright line.
- **Welcome tour replay moved out of Settings.** The "Replay intro" row in Settings → About has been removed; replay is still available from the Debug screen.

## 0.4.0

The biggest update since launch. A first-launch guide walks you through setup, four ready-to-use listening presets replace the old starter profiles, and SherlockEQ now plugs into Shortcuts, Siri, and Spotlight so you can drive it hands-free or from your own automations.

**Added**

- **A first-launch walkthrough.** New installs now open a short three-step guide: a welcome that explains how SherlockEQ sits in your audio chain, a plain-language primer on the permissions it needs before the system asks for them, and a pick from the new built-in presets to get you listening right away. You can replay it any time from Settings → About.
- **Four built-in listening presets.** **Voice Clarity**, **Music Balanced**, **Gentle Listening**, and **Presence Boost** replace the old Default and Voice Clarity profiles. Each is a comfort and clarity shape on the 10-band equalizer — not a medical correction — and Music Balanced is the starting point for new installs. Existing presets are brought up to date automatically when you upgrade.
- **Shortcuts, Siri, and Spotlight support.** SherlockEQ now offers a full set of actions you can use in the Shortcuts app, ask Siri to run, or trigger from Spotlight: toggle Reference Mode, set or nudge the master volume, set balance, switch the active profile, read the current profile and status, and adjust the Simple equalizer. If the app is closed, the action launches it quietly in the background so your EQ actually takes effect.

**Changed**

- **Built-in presets are now yours to edit.** The built-in presets are no longer locked — tweak any of them in place to taste. A new **Reset to Default** button restores a single preset to its factory shape, and you can bring back any you've removed from the Profiles toolbar. Edited built-ins are marked with a star so you can tell them apart at a glance.

## 0.3.3

A maintenance release that polishes the Analog Control Unit. The OUTPUT row now lists only real speakers instead of macOS's internal audio plumbing, the menu-bar popover is easier to read, and there's a new in-app guide for the `sherlockeq` command-line tool added in 0.3.2.

**Added**

- **A Command-Line Tool help article.** The in-app Help (and the website) now has a full guide to `sherlockeq` — how to install it, every command at a glance, and a few ready-to-use scripting workflows.

**Changed**

- **The menu-bar popover is easier to read.** The output-device label and the Quit button are larger and clearer.
- **Debug is now opt-in.** The Debug screen is hidden from the main window's sidebar by default; turn it on under Settings → Diagnostics if you want it. When enabled, it now shows a live dynamics readout, per-stage signal-chain bypass switches, and a tidier layout.

**Fixed**

- **The OUTPUT row only shows real speakers now.** macOS quietly creates temporary internal devices to route the default output; these were leaking into the panel as a stray button with a question mark. They're now filtered out, so you only see devices you can actually pick. Any device that isn't recognised shows a generic speaker icon instead of a question mark, and the row is capped at six buttons so it can't overrun the panel.
- **The spectrum analyzer panel opens and closes cleanly.** Toggling it quickly could leave the window and the arrow out of sync — the panel showing while the window stayed short, or vice versa. It now stays in step no matter how fast you click.
- **Tables render properly in Help.** Markdown tables (including the ones on the Keyboard Shortcuts page) were showing as raw `| a | b |` text; they're now laid out as real tables.

## 0.3.2

This release adds a command-line interface. `sherlockeq` is a power-user and automation surface for the app — check status, switch profiles, toggle Reference Mode, nudge gain, balance, and the simple EQ, list output devices, import or export profiles, and dump diagnostics for a bug report. The running app stays in charge: the CLI just asks it to report or change state, so anything you do on the command line shows up in the window and the menu bar right away.

**Added**

- **The `sherlockeq` command-line tool.** `sherlockeq status` for a one-glance summary; `profiles list / active / activate / import / export`; `bypass on|off|toggle`; `gain`, `balance`, and `simple-eq` get/set; `devices list / current`; `diagnostics` for a structured snapshot to attach to a bug report; plus `launch` and `quit`. Most commands take `--json` for scripting, return meaningful exit codes, and fail cleanly with a clear message when the app isn't running. Everything is local — no telemetry, no network.
- **It installs with the app.** Homebrew (`brew install --cask sherlockeq`) now puts `sherlockeq` on your PATH automatically. If you installed the app directly, the tool ships inside the bundle — run `"/Applications/SherlockEQ.app/Contents/Helpers/sherlockeq" install` once to symlink it onto your PATH.

## 0.3.1

A focused follow-up to 0.3.0. The Analog Control Unit's OUTPUT row now actually switches your Mac's audio output instead of just labelling it, its COLOR control matches the panel's other switches, and you can quit SherlockEQ straight from the menu-bar popover.

**Added**

- **Switch audio output from the Analog Control Unit.** The OUTPUT buttons now scan for your Mac's available output devices and let you switch between them — built-in speakers, headphones, an external DAC — right from the panel. It sets the system output (the same selection as the menu-bar sound control), and SherlockEQ follows the new device automatically. The lit button is the current output.
- **Quit from the menu bar.** A *Quit SherlockEQ* option now sits at the bottom of the menu-bar popover, so you can quit without opening the main window or hunting through the app menu.

**Changed**

- **The spectrum analyzer's COLOR control is now a normal switch.** It no longer paints the palette onto the switch itself — off is green, on is the colourful palette, matching the PEAK switch beside it.

## 0.3.0

A big optional addition plus a round of polish. The headline is the **Analog Control Unit** — a vintage hi-fi front panel you can leave open on the desktop for the five adjustments people understand immediately: volume, balance, bass, mid, and treble. There's also a new in-app Help system, a quick Listening Comfort toggle in the menu bar, and a more readable accent colour in light mode.

**Added**

- **Analog Control Unit.** Open it from *Window → Analog Control Unit*: warm stereo VU meters, a system-volume knob, balance, and a simple bass / mid / treble tone on a dark brushed-metal faceplate. It runs on its own isolated profile, so casual knob-twiddling never touches your carefully tuned EQ. The VOLUME knob drives the macOS output level directly; balance and tone map to SherlockEQ's simple EQ.
- **Built-in spectrum analyzer.** Click the chevron at the bottom of the Analog Control Unit to slide out a classic rack spectrum analyzer — 31 third-octave bars with a frequency label under each. Switch between a green and a colourful palette, dim the display, dial in sensitivity, and flip between full bars and a moving peak tick.
- **In-app Help.** A proper Help menu and contextual *?* buttons throughout the app open a searchable help window covering every feature — what it does, how to use it, and the safety boundaries.
- **Listening Comfort toggle in the menu bar.** Turn the comfort processors on or off from the menu-bar popover without opening the full window — right next to the Tinnitus Notch toggle.

**Changed**

- **Accent colour reads better in light mode.** The gold accent is now appearance-aware — a deeper gold on light backgrounds so sliders, toggles, and the active sidebar item meet contrast guidelines, with the brighter gold kept for dark mode.
- **Equalizer moved to the top of the sidebar.** Audio Processing now lists Equalizer first, then Audiogram, Tinnitus Notch, Listening Comfort, and Safe Listening.
- **Expert EQ shows the spectrum only.** The Spectrum / Bars switch is hidden for now; the Expert canvas always shows the live spectrum behind your curve. Bars will return.

**Fixed**

- **The updater shows real release notes again.** "Check for Updates" now renders these formatted notes in the update window instead of loading the GitHub release web page.

## 0.2.0 — Listening Comfort

The first feature release since 0.1: **Listening Comfort** — level-dependent
processing that shapes sound only while it needs it, instead of permanently
re-tuning the curve. Soften a harsh "sss," ease shouty midrange, or lift
dialogue over a score — each engages when the triggering sound is present and
relaxes when it's gone. Per ear, zero added latency, with the peak limiter as
the ceiling over any boost.

**Added**

- **Listening Comfort panel** — three named processors (Speech Presence, Harshness Control, Sibilance Tamer), each an on/off plus Strength and Sensitivity sliders with a live activity meter. Independent per ear.
- **Adaptive, level-independent triggering** — each processor reacts relative to a slow rolling average of its target band, so it behaves the same on a quiet podcast and a loud movie, no SPL calibration required.
- **Dynamics overlay on the Expert canvas** — a Dynamics layer chip draws each active processor's response live against the spectrum.

**Changed**

- **Reference Mode and chain bypass now cover the comfort tools** — ⌘B drops the comfort stage with the rest of the chain for a true A/B; a per-stage toggle disables comfort while keeping EQ, correction, and notch active.

**Fixed**

- The menu-bar popover no longer lingers in front of the main window after opening the full app.

**Not a medical device** — SherlockEQ does not diagnose, treat, measure, or
monitor any hearing condition or tinnitus. The Listening Comfort tools shape
audio for comfort and clarity; they are not a hearing aid. See
[Safety, Limits & Listening Responsibility](help:safety-limits).

## Earlier versions

Full release notes for every version are published with each release. See
**Check for Updates…** in the app menu, or the project's releases page online.
