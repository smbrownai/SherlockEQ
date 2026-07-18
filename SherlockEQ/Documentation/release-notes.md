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

## 0.9.1

A maintenance release. The one fix you might notice resolves a confusing "ghost" state on the Audiogram screen for hearing profiles carried over from an earlier version; the rest are reliability and build-tooling improvements under the hood. Nothing changes in how your EQ, presets, hearing adjustments, or listening-dose tracking sound or behave.

**Fixed**

- **"Ghost" audiograms carried over from earlier versions now read correctly.** If you'd entered an audiogram in an older version, the Audiogram screen could contradict itself: it showed your threshold values and applied a real hearing adjustment, yet also said no thresholds had been entered — and the *Clear Audiogram* option was hidden exactly when you'd want it. SherlockEQ now reconciles these on load: the screen states the adjustment honestly (with the date it was carried over from), the per-frequency readouts match, and *Clear Audiogram* is always available whenever there's an adjustment to remove. The sound you were already hearing is preserved — this only changes what the screen tells you, not the audio.

**Under the hood**

- **Reliability and diagnostics.** Fixed a small memory-management issue in the listening-dose tracker (no effect on dose tracking itself), and the audiogram-to-EQ derivation now records a diagnostic if its band-overlap solver ever fails to converge, where before it was silent.
- **Safer code signing.** Hardened the build's code-signing step so the app's auto-update components are always signed the way Apple and the Sparkle updater expect. This is a packaging change — it doesn't affect the app you run.

## 0.9.0

This is the largest SherlockEQ release so far, and it moves the app substantially closer to a 1.0. Rather than one headline feature, it's a broad step forward: a new way for your hearing adjustment to adapt to how loud you're listening, a simpler and more honest equalizer, an optional in-app listening check, and a top-to-bottom pass on wording, safety, privacy, and reliability. What follows is a summary by area, not an exhaustive list of every change.

**Hearing adjustment that adapts**

Your audiogram-derived adjustment can now follow the sound. An optional Adaptive mode gives a little more help in quiet passages and eases off as things get loud, instead of applying a single fixed curve. New adjustments also ease in gradually over the first few weeks rather than arriving at full strength on day one, so an unaccustomed ear has time to settle. As always, this is a comfort adjustment you fine-tune by ear — a starting point, not a clinical fitting.

**A simpler equalizer**

The old set of overlapping EQ modes is now two clear surfaces: a Graphic equalizer on a hearing-oriented set of bands for quick shaping, and a full Parametric canvas when you want fine control. Presets are organized around what you're trying to achieve rather than by music genre, and the more specialized mixing-oriented displays have been retired to keep the screen focused. Nothing you set up before is lost — your profiles carry across, and any bands that don't fit the graphic grid stay editable.

**An in-app listening check**

A new, optional guided check estimates your hearing thresholds ear by ear using quiet test tones, then offers to turn the result into a starting hearing adjustment. It's framed throughout as an at-home estimate to tune by ear — not a hearing test, and not a diagnosis.

**Clearer wording, and honest limits**

A wide pass on language across the app. Audiogram-derived processing is described as a "hearing adjustment," not a clinical "correction," and medical-sounding claims are gone. Health & safety information is consolidated into one place you can always reach. Level and exposure readouts now say plainly when a value is an estimate — or simply unknown — instead of ever implying "safe," and the listening-dose estimate accounts for your system volume. The app also warns you when settings work against each other, such as a tinnitus notch fighting your hearing adjustment, or a headphone correction left on for the wrong output device.

**A more consistent interface**

The menu-bar popover is now a glanceable status-and-remote surface rather than a cramped copy of the whole app. Profile management, the Tinnitus tools, Adaptive Comfort, Safe Listening, and Settings were each reorganized to lead with what you're trying to do. Every adjustable value now shows its scope — whole-app, per-profile, per-ear, or today — and a broad accessibility pass improved VoiceOver, keyboard control, and Dynamic Type support.

**Reliability, privacy, and performance**

Many improvements under the hood: safer handling of your profiles on disk, more resilient audio capture and recovery around sleep, wake, and device changes, and tightened audio-thread work for glitch-free playback. On privacy, exported profiles no longer carry machine-identifying details, listening-dose values stay out of system logs, and the in-app privacy notes now describe exactly what does and doesn't leave your Mac — nothing you play is ever recorded or sent anywhere.

## 0.8.1

A small maintenance release with two accuracy fixes under the hood: more robust detection of which channels carry your system audio when your output is an audio interface, and a corrected level scale on the spectrum display. Nothing changes in how EQ, presets, or listening-dose tracking work.

**Fixes**

- **Sturdier audio capture on interfaces that also have inputs.** When your output device is an audio interface with its own microphone or line inputs (for example a podcasting mixer), SherlockEQ now reads the device's actual channel layout to locate your system audio instead of assuming a fixed position. This guards against an edge case where a live input could bleed into one ear. On ordinary speakers, headphones, and DACs nothing changes — this is a robustness improvement, not a change you'll normally hear.
- **The spectrum display's level scale now reads true.** The frequency spectrum was reading about 1.8 dB lower than the actual signal because of how the analysis window was accounted for, so the numbers on the display sat slightly low. The scale is now calibrated correctly. This is a display-only change — it never affected the audio you hear, and it never affected listening-dose tracking, which measures level independently. The safety-warning line on the spectrum stays exactly where it was.

## 0.8.0

A reworked Tinnitus Notch. Two behavior fixes correct how the notch filter actually sounds, and the Tinnitus Notch screen gets strength presets, a live preview of the band being reduced, a guided pitch-matching flow, and an optional daily check-in.

**Fixed**

- **The notch's Depth slider now actually changes the sound.** Previously the notch always cut all the way to silence at its center frequency no matter what Depth was set to — the slider had no audible effect. Depth now works as labeled: a shallower setting leaves more of the sound in place, a deeper one reduces it further.
- **Narrow and Wide were swapped.** The Width control's Narrow setting was actually broader than Wide. They're corrected now: Narrow affects the smallest band around your selected pitch, Wide the largest.
- **The right ear's notch now shows up on the equalizer curve.** When left and right ears had different notch settings, only the left ear's cut appeared on the frequency-response graph — the right ear's was invisible even though it was being applied correctly to the audio. Both ears now draw correctly on the Simple, Speech, Advanced, and Expert tabs.

**Improved**

- **Strength presets: Subtle, Balanced, Strong.** Pick a preset instead of tuning Depth and Width by hand. Each is labeled with its trade-off — Subtle keeps audio clearest, Strong reduces more but can sound duller. The fine-tune sliders are still there if you want manual control.
- **A live preview of the notch.** The Tinnitus Notch screen now draws the actual shape of the band being reduced — center frequency, depth, and width — instead of just a line marking the pitch. Both ears show at once when your left and right notches differ.
- **Guided pitch-matching.** An optional walkthrough helps you find a repeatable match: sweep up from below, check for octave confusion, and capture a few matches to get a suggested average and range instead of relying on a single guess.
- **Clearer guidance on when a notch helps.** The screen now explains that a notch suits steady, tone-like ringing and is less useful for hissing, roaring, clicking, pulsing, or shifting tinnitus — and calls out pulsatile, sudden one-sided, or dizziness-accompanied symptoms as reasons to see a hearing professional instead.
- **An optional daily check-in.** Rate how much your tinnitus bothered you today — not how loud it seemed — and see a simple trend over time. It's not a clinical score, just a way to notice whether things are trending better.

## 0.7.3

A small bug-fix release. It resolves a case where waking your Mac — or coming back to it after it's been asleep overnight — could leave SherlockEQ stuck showing an audio-engine error banner instead of resuming normally. Nothing changes in how EQ or dose tracking work.

**Fixes**

- **Waking from sleep no longer gets stuck on an audio engine error.** Right after your Mac wakes, or after it's been asleep overnight, SherlockEQ's audio engine could briefly disagree with itself about the current sample rate and show a stuck "Audio engine: Unexpected SR mismatch" banner until you relaunched the app. SherlockEQ now recognizes this as a momentary hiccup and retries automatically, so it resolves itself within a second or two instead of getting stuck.

## 0.7.2

A code-quality and security-hardening release. It fixes a crash on importing certain audiogram files, closes several findings from a focused security review — including a case where a downloaded headphone-correction file could push the volume to unpredictable levels — and stops your tinnitus and profile settings from being written to the system's debug logs. Nothing changes in how EQ, profiles, or safe-listening work.

**Fixes**

- **Importing a damaged audiogram file no longer crashes SherlockEQ.** A corrupted or hand-edited audiogram file with an invalid measurement could crash the app on import. SherlockEQ now skips the bad measurement and imports the rest of the file normally.

**Security**

- **Headphone-correction files can no longer set an unsafe volume.** A malformed or tampered `ParametricEQ.txt` file — whether picked manually or downloaded from the online AutoEQ catalog — could contain a preamp value extreme enough to drive the volume far beyond a safe level. That value is now kept within the same safe range as every other EQ setting.
- **Your tinnitus and profile settings stay out of the system logs.** Applying a profile used to write your tinnitus notch frequency and profile name to the system's unified log in plain text, where they could end up in a diagnostic report. That detail is now redacted from the log.
- **Your hearing profiles and listening history are excluded from backups.** Profiles and your listening-dose history are now marked so Time Machine and similar tools skip them, and each file is readable only by your account — so this data doesn't linger in old backups you have no way to clean up from within the app.
- **The audio engine is more resilient to unusual buffer sizes.** During a device switch or sleep/wake, the audio engine could momentarily receive an unexpected buffer size. It's now validated before use, closing a theoretical memory-safety gap in that path.

**Under the hood**

- **Smoother real-time spectrum analysis.** The spectrum analyzer's internal buffering was tightened to reduce the chance of a stall on the audio thread. No user-facing change.

## 0.7.1

A focused bug-fix release. It resolves a problem where switching to another macOS user account could leave that account with no sound. Nothing changes in how EQ or dose tracking work.

**Fixes**

- **Other accounts keep their sound during fast user switching.** Because SherlockEQ taps the system audio at a level shared across all login sessions, switching to another user used to leave that account silent until SherlockEQ was quit. SherlockEQ now releases the audio tap when its account is switched out and restores it when you switch back, so other users hear sound normally.

## 0.7.0

A small stability-and-polish release that rounds out the 0.6 series. It corrects how the new listening-history chart labels days when you travel, and tidies the About window. Nothing changes in how EQ or dose tracking work.

**Fixes**

- **Listening history stays on the right day when you change time zones.** Each day's entry in the 7-day history is now tied to the calendar day it happened on, so traveling between time zones no longer shifts a day's bar or resets the current day's dose early.

**Improvements**

- **A cleaner About window.** "Free and Open Source" and the website link now share one line.

## 0.6.9

This release brings the Safe Listening screen's 7-day history to life: your daily listening dose is now saved and charted, so you can see how this week's exposure compares day to day. The About window also got a small refresh. Nothing changes in how EQ or dose tracking work.

**New**

- **A real 7-day listening history.** The Safe Listening screen now charts each day's peak dose for the past week, coloured green, amber, or red against the same 80 % / 100 % thresholds as the live dose card. Today's bar reflects your exposure so far; past days are captured automatically at the midnight rollover and saved between launches — including when SherlockEQ was closed overnight. A day with no listening simply doesn't appear.

**Improvements**

- **A tidier About window.** The credits now read "Free and Open Source", with a little more spacing and a link to the SherlockEQ website.

## 0.6.8

A small maintenance release. It refreshes the first-launch welcome video and fixes a case where re-opening SherlockEQ wouldn't bring the existing window forward. The rest is internal cleanup. Nothing changes in how EQ or safe-listening work.

**Improvements**

- **An updated welcome video.** The first-launch onboarding screen now plays a refreshed intro clip.

**Fixes**

- **Re-launching brings the running app forward.** When SherlockEQ was already running, opening it again now reliably activates the existing instance and brings its window to the front instead of occasionally leaving it in the background.

**Under the hood**

- **Cleaner internal state wiring.** The app's audio-state object was split so each screen depends only on the settings it actually uses, and an unused parameter was removed from the spectrum analyzer. No user-facing change.

## 0.6.7

This release adds a short intro video to the first-launch welcome screen and makes your audiogram much easier to reuse — copy it onto your other profiles in one step, or save it to a file and load it back later. The spectrum analyzer, the Profiles screen, and a couple of keyboard niceties also got some polish. Nothing changes in how EQ or safe-listening work.

**New**

- **A welcome video on first launch.** The onboarding screen now opens with a brief intro video that plays once and settles on its final frame. It's purely a welcome — onboarding works exactly as before on builds without it.
- **Apply one audiogram to several profiles at once.** The Audiogram screen's new *Manage Audiogram → Apply to Other Profiles…* lets you copy the active profile's hearing thresholds onto any profiles you pick. Each profile's EQ, tinnitus notch, and compensation strength are left untouched — only the audiogram and its correction update.
- **Import and export audiograms.** *Manage Audiogram → Import…/Export…* saves your audiogram to a file or loads one back into the active profile, so you can back it up or move it between Macs without copying a whole profile.

**Improvements**

- **The analyzer's input and output now show the real difference.** The input overlay reflects the true unprocessed signal (both channels) instead of mirroring the output, so the gap between the two curves is exactly what the EQ is doing.
- **A cleaner Output view.** The faint peak-hold line in the spectrum now appears only when the Peaks layer is on, so an Output-only view is a clean silhouette.
- **⌘1 opens the Analog Control Unit.** Pairs with ⌘0 for the main window.
- **Profile icons have plain-English names.** The icon picker now reads Person, Headphones, AirPods Pro, Speaker, Voice, Night, Day, Work, Home, and so on, instead of technical symbol names.
- **A tidier profile page.** The technical metadata footer (timestamps and ID) is hidden by default; turn it back on under Settings → Diagnostics if you need it for support.

**Fixes**

- **"Reset to Factory Default" now enables after any change.** Editing a factory preset's audiogram, tinnitus notch, compensation strength, or headphone correction now correctly enables Reset — previously it only noticed tone, output-trim, name, and balance edits.
- **The notch marker no longer lingers.** The dashed marker and label in the visualizer now appear only while the tinnitus notch is on, instead of pointing at a curve feature that isn't there.

**Under the hood**

- **The automated test suite runs again.** A startup guard kept the test bundle from launching; the suite now runs in full, so regressions get caught before they ship. No user-facing change.

## 0.6.6

A reliability release. The main fix is for audio that didn't come back cleanly after your Mac woke from sleep — most often after sitting overnight. In that state the audio engine or the system-audio tap could fail to start, leaving SherlockEQ silent until you toggled it off and on or relaunched. This release detects those momentary start-up failures and retries them on its own, so sound returns without you having to do anything. Nothing changes in how EQ, profiles, or safe-listening work.

**Fixes**

- **Audio reliably restarts after sleep and wake.** After waking from sleep, the audio engine and the system-audio tap could occasionally report a transient start-up error and stay silent. SherlockEQ now retries these momentary failures with a short back-off on both start paths, and recovers a tap that didn't come up — so audio resumes on its own instead of needing a manual restart.

**Under the hood**

- **Equalizer filtering now runs on Apple's Accelerate framework.** The per-ear equalizer cascade was moved onto Apple's maintained `vDSP` signal-processing routines. The sound you hear is unchanged — this keeps the audio path leaner and easier to maintain.

## 0.6.5

A correction-focused fix. In earlier versions, choosing an equalizer preset or editing bands by hand could quietly overwrite the hearing correction derived from your audiogram — leaving you listening through the preset alone. This release makes your audiogram correction its own layer that always stays applied: equalizer presets and manual tweaks now sit *on top of* it rather than replacing it. It also makes the on-screen curves easier to read.

**Fixes**

- **Your hearing correction is no longer overwritten by EQ presets or edits.** The correction calculated from your audiogram is now kept separate from the equalizer, and the two are combined when you listen. Picking a preset, dragging bands, or clearing the equalizer changes only the equalizer — your hearing correction stays in place.
- **An entered audiogram always produces a correction.** Profiles that had an audiogram but were showing a flat correction — for example after clearing equalizer bands — now rebuild the correction from your stored thresholds automatically.

**Improvements**

- **A clearer picture of what you hear.** The equalizer chart now shows a combined *Result* line — your hearing correction and equalizer together — as the main curve, with an optional *Breakdown* view that separates the correction and your equalizer into their own lines.
- **Easier-to-read curves, per ear.** Each curve type now has its own line style and each ear its own color, with a new on-chart legend that labels them. The encoding is designed to stay clear for color-vision differences.
- **More complete in-app Help.** New and corrected Help articles for Speech EQ, Advanced EQ, and Listening Comfort, with fixes to several documentation inconsistencies.

## 0.6.4

A security-hardening release. SherlockEQ runs without the macOS sandbox so it can tap system audio, which means its helper surfaces deserve extra care. This update tightens how the command-line tool talks to the app, what files that channel can touch, and the permissions on the app's own data — closing the findings from a focused security review. There are no changes to how EQ, profiles, or safe-listening work.

**Security**

- **The command-line control channel is now authenticated.** The `sherlockeq` tool talks to the running app over a local channel that previously accepted any message from any program on your Mac. The app now issues a private, per-launch token that only your account can read, and ignores any request that doesn't present it — so another program can't quietly drive SherlockEQ on your behalf.
- **Profile import and export stay where they belong.** Importing and exporting profiles through the command-line tool now accepts only real `.json` files and won't follow a symlink in place of the target. This prevents the app from being tricked into overwriting an unrelated file or reading something it shouldn't.
- **Downloaded headphone-correction files are kept inside their cache.** Entries fetched from the online AutoEQ catalog are sanitized before being written to disk, so a malformed or tampered catalog entry can't place a file outside SherlockEQ's own cache folder.
- **Your data folders are now private to your account.** The folders SherlockEQ creates for your profiles and cached corrections are created — and existing ones tightened — so only your account can read them. Profiles can encode details about your hearing; they shouldn't be readable by other users on a shared Mac.

## 0.6.3

A large bug-fix release from a full code audit. It protects your saved EQ work, makes the daily listening-safety tracking dependable across restarts and midnight, and hardens profile and headphone-correction importing.

**Fixed**

- **Editing an audiogram no longer erases your manual EQ.** Adjusting a hearing-threshold point used to overwrite every band you had tuned in the Simple, Speech, Advanced, or Expert tabs. The audiogram now updates only its own bands and leaves the rest of your EQ intact.
- **Linked left/right channels stay truly in sync.** In Expert, adding, removing, or dragging a band with channels linked now mirrors to the other ear correctly instead of letting the two ears drift apart or overwriting an unrelated band.
- **Your daily listening dose is remembered.** The safe-listening dose now persists across app relaunches within the same day, rolls over at midnight even when no audio is playing, and counts time more accurately across pauses — so a high-exposure day is tracked honestly.
- **Safe-listening alerts aren't missed at startup.** A notification triggered moments after launch is no longer dropped while notification permission is still being checked.
- **Importing profiles and headphone corrections is more robust.** Shared or hand-edited profile files load even when they omit internal ids, AutoEQ files whose filters omit a Q value now import fully instead of partially, and the correct correction is matched when the catalog has two headphones with the same name.
- **The Expert EQ graph shows its full range.** Bands set to the ±24 dB extremes are now drawn and stay draggable on the curve instead of being silently clamped to ±18 dB.
- **The tinnitus-notch preview shows the correct ear.** With separate per-ear notches enabled, the Expert graph now shows the notch for the ear you're editing rather than always the left.
- **Diagnostic and calibration tones behave across device changes.** The test tone and SPL-calibration tone now stop cleanly when you switch output devices or the Mac sleeps, instead of getting stuck "on" with no sound or quietly corrupting an in-progress calibration.
- **Cleaner audio recovery and rarer edge cases.** Audio now self-heals after a brief interruption instead of staying choppy, a rare feedback-loop condition at startup is prevented, and an output-permission change mid-session is handled without leaving the audio engine in a bad state.
- **A profile that can't be loaded is reported, not hidden.** If a profile file fails to load, SherlockEQ now tells you instead of silently dropping it from the list.
- **Smoother VU metering and immediate diagnostic toggles.** The analog VU needle no longer jumps after sleep/wake, and signal-chain bypass switches take effect immediately while a diagnostic tone is active.
- **Command-line tool: `install` is safer.** `sherlockeq install` now refuses to overwrite an unrelated file at the target path instead of replacing it.

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
