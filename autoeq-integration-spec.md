# AuditumEQ — AutoEQ Integration Spec
**Feature:** AutoEQ On-Demand Profile Fetching + Tinnitus Notch Filter Interaction  
**For:** Claude Code implementation session  
**Scope:** Two connected features — remote profile search/import and signal chain composition

---

## Design Notes (Read Before Implementing)

Two architectural decisions are worth understanding before touching any code:

**1. The ±1/3 octave conflict detection window is a judgment call.**  
It is wide enough to catch meaningful interactions between an AutoEQ boost and the tinnitus notch, but not so wide that it triggers false warnings on every profile. During testing, if warnings feel too frequent or too rare, this window should be the first thing tuned. It is expressed as a constant (`conflictWindowOctaves = 1.0/3.0`) so it is easy to adjust in one place.

**2. Notch-after-correction is a deliberate therapeutic choice.**  
The tinnitus notch filter is placed downstream of the AutoEQ headphone correction (Stage 3, after Stage 2). This means the notch is operating on an already-corrected, tonally flattened signal rather than on a colored headphone response. The practical effect: the notch depth the user dials in behaves consistently across different headphones. If notch were applied first, a headphone with a strong peak near the tinnitus frequency would make the notch feel shallow; one with a dip there would make it feel aggressive. Post-correction placement removes that variability. Surface this reasoning in the in-app tooltip for the notch stage so audiologically-aware users understand the design intent.

---

## Architecture Overview

Two-phase system:

**Phase 1 — Index**  
A local search index of all available headphone profiles, parsed from AutoEQ's hosted README.md. Fetched once at first launch and refreshed in the background every 7 days. Never fetches individual profile files until the user explicitly selects one.

**Phase 2 — Profile Fetch**  
Individual `ParametricEQ.txt` files fetched on demand via raw GitHub URLs when the user selects a headphone. Cached locally after the first fetch.

No accounts, no API keys, no analytics. All fetches go directly to `raw.githubusercontent.com`.

---

## Phase 1: Index

### Source

```
https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/README.md
```

### Parsing

The README.md is a markdown list. Each entry looks like:

```
- [Sennheiser HD 650](./oratory1990/over-ear/Sennheiser%20HD%20650)
```

Parse each line to extract:

| Field | Example | Notes |
|---|---|---|
| `name` | `"Sennheiser HD 650"` | Display name from link text |
| `path` | `"oratory1990/over-ear/Sennheiser HD 650"` | URL-decoded relative path, leading `./` stripped |
| `source` | `"oratory1990"` | First path component |
| `type` | `"over-ear"` | Second path component |

Skip lines that do not match the pattern `- [name](./path)`.

### Storage

Write the parsed index to:
```
Application Support/AuditumEQ/autoeq_index.json
```

Index entry schema:
```swift
struct AutoEQIndexEntry: Codable {
    let name: String        // "Sennheiser HD 650"
    let path: String        // "oratory1990/over-ear/Sennheiser HD 650"
    let source: String      // "oratory1990"
    let type: String        // "over-ear", "in-ear", "earbud"
}
```

Store an `indexFetchedAt: Date` alongside the array so refresh logic can check age.

### Refresh Logic

- On launch: check `indexFetchedAt`. If older than 7 days, fetch in background.
- On first launch with no cached index: fetch before enabling the search UI. Show a loading state in the search field ("Loading headphone library…"). Do not block app launch — defer this fetch to when the user navigates to the AutoEQ search view.
- Never show a modal or blocking alert for index fetching. All index operations happen silently or with a subtle inline indicator.

---

## Phase 2: Profile Fetch

### URL Construction

```
https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/{URL-encoded path}/ParametricEQ.txt
```

Example:
```
https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Sennheiser%20HD%20650/ParametricEQ.txt
```

URL-encode each path component individually. Do not encode the `/` separators between components.

### Cache Location

```
Application Support/AuditumEQ/autoeq_profiles/{source}/{type}/{name}.json
```

The `.json` file stores the parsed `AutoEQProfile` struct (see below), not the raw `.txt`. Parse once on fetch, cache the structured result.

---

## ParametricEQ.txt Parser

### File Format

```
Preamp: -6.5 dB
Filter 1: ON PK Fc 21 Hz Gain 4.5 dB Q 0.700
Filter 2: ON PK Fc 105 Hz Gain -3.5 dB Q 1.410
Filter 3: ON LSC Fc 105 Hz Gain 4.0 dB Q 0.700
Filter 4: ON HSC Fc 10000 Hz Gain 3.0 dB Q 0.700
Filter 5: OFF PK Fc 3000 Hz Gain 1.0 dB Q 1.000
```

### Data Models

```swift
struct AutoEQProfile: Codable {
    let headphoneName: String
    let source: String
    let type: String              // "over-ear", "in-ear", etc.
    let preampGain: Double        // negative dB value from file, e.g. -6.5
    let filters: [AutoEQFilter]
    let fetchedAt: Date
}

struct AutoEQFilter: Codable {
    let index: Int
    let enabled: Bool
    let filterType: EQFilterType
    let frequency: Double         // Hz
    let gain: Double              // dB
    let q: Double
}

enum EQFilterType: String, Codable {
    case peak       = "PK"
    case lowShelf   = "LSC"
    case highShelf  = "HSC"
}
```

### Parser Rules

- Parse the `Preamp:` line first. Strip `" dB"` and parse as `Double`. This value is always negative or zero.
- For each `Filter N:` line:
  - Check state field: `ON` sets `enabled = true`, `OFF` sets `enabled = false`.
  - Map filter type string to `EQFilterType`. If unrecognized, skip the filter and log a warning.
  - Strip units (`"Hz"`, `"dB"`) before parsing numeric values.
  - Clamp `q` to `0.1...16.0` after parsing.
- Skip filters where `enabled == false`. They are not added to the parsed profile.
- If parsing fails on any individual filter line, skip that filter and log a warning. Do not throw or fail the whole parse.
- If the `Preamp:` line is missing entirely, default to `0.0 dB` and log a warning.

---

## Search UI

**Location:** Main window → Device Profiles section → "Import from AutoEQ" panel

### Component: `AutoEQSearchView`

**Search field**
- Placeholder: `"Search 6,000+ headphone profiles…"`
- Activates result list after 2 or more characters are typed
- Clears results immediately when field is cleared

**Result list**
- Each row:
  - Primary label: headphone name (`"Sennheiser HD 650"`)
  - Secondary label: source + type (`"oratory1990 · over-ear"`)
- Matching: case-insensitive contains match on `name`. Also match if the query matches the source (e.g., typing "oratory" surfaces all oratory1990 entries).
- Cap visible results at 50. If more than 50 match, show a footer row: `"Showing 50 of N results — keep typing to narrow"`. This footer is not tappable.
- Result list is a `ScrollView` — do not use a `Picker` or `Menu`.

**On row selection**
1. Show an inline spinner on the selected row.
2. Fetch and parse the `ParametricEQ.txt`.
3. On success: save the profile to cache, add it to the saved profiles list, dismiss the search UI, briefly animate the new entry into the saved list.
4. On failure: show an inline error message on the row (see Error Handling). Do not dismiss the search UI on failure.

**Do not auto-apply the profile on import.** Import only adds it to the saved profiles list. The user activates it explicitly.

---

## Saved Profiles List

**Location:** Main window → Device Profiles section, below the search panel

Stored as an ordered array of profile identifiers in `AppStorage`. Each identifier is the `path` string from the index entry.

Each list row displays:
- Headphone name (bold)
- Source badge — small pill label (e.g., `"oratory1990"`)
- Type label (e.g., `"over-ear"`)
- Date imported (secondary, formatted as relative time if < 7 days, otherwise short date)
- `"Apply"` button — activates this profile as the current AutoEQ stage
- `"Delete"` button — removes from saved list and deletes the cached `.json` file

The currently active profile row is visually distinguished (e.g., a checkmark or highlighted background).

**This list is the data source for the menu bar popover's headphone selector.** The popover shows only saved profiles, never the full catalog.

---

## Signal Chain

Process audio through these sequential stages in fixed order:

```
Stage 0  →  Safe Listening Dose Monitor (measurement only, not a filter)
Stage 1  →  Preamp (computed gain, not user-editable)
Stage 2  →  AutoEQ Filters (headphone correction)
Stage 3  →  Tinnitus Notch Filter
Stage 4  →  Manual Parametric EQ
```

See Design Notes above for the rationale for placing the notch after AutoEQ correction.

---

## Preamp Computation

```
combinedPreamp = autoEQPreamp + notchHeadroomAdjustment + manualEQHeadroom
```

Where:
- `autoEQPreamp` — the value from `AutoEQProfile.preampGain`, e.g. `-6.5 dB`. Always ≤ 0.
- `notchHeadroomAdjustment` — `0.0 dB` in all normal cases. A notch filter only attenuates; it never adds gain requiring headroom compensation.
- `manualEQHeadroom` — if any Stage 4 bands have positive gain, compute this as the minimum value needed to prevent clipping given the peak manual EQ gain. Use the same peak-headroom approach AutoEQ uses internally.

Display the computed preamp value in the Device Profile settings view as a read-only field. Include a tooltip: `"Preamp is set automatically to prevent clipping from the combined EQ filters."` Do not allow the user to edit this field directly; they control it indirectly by adjusting their EQ bands.

---

## Conflict Detection

A conflict occurs when an AutoEQ filter has positive gain AND its center frequency falls within ±1/3 octave of the active tinnitus notch frequency.

This matters because AutoEQ may boost near the tinnitus frequency (e.g., to correct a headphone dip at 4 kHz), which partially counteracts the notch's attenuation.

### Detection Rule

```swift
let conflictWindowOctaves = 1.0 / 3.0   // Tunable constant — see Design Notes

for filter in activeProfile.filters where filter.gain > 0 {
    let lowerBound = notchFreq * pow(2.0, -conflictWindowOctaves)
    let upperBound = notchFreq * pow(2.0,  conflictWindowOctaves)
    if filter.frequency >= lowerBound && filter.frequency <= upperBound {
        // flag as conflict
    }
}
```

### Exact-Match Case

If any AutoEQ filter has `filter.frequency == notchFreq` (within 1 Hz), treat this as a **high-severity conflict** and adjust the warning copy: `"An AutoEQ filter is centered exactly on your tinnitus frequency ([X] Hz). Consider disabling AutoEQ correction at this frequency."`

### Conflict Warning UI

When one or more conflicts are detected, show a warning banner in the Device Profile settings view:

> ⚠️ One or more AutoEQ filters boost near your tinnitus frequency ([X] Hz). This may reduce notch therapy effectiveness.

Offer two action buttons in the banner:

| Button | Behavior |
|---|---|
| `"Show me"` | Scrolls to and highlights the conflicting filter band(s) on the EQ plot in amber |
| `"Adjust notch depth"` | Opens the notch filter panel so the user can deepen the notch to compensate |

**Do not automatically modify any filter values.** The warning is advisory only.  
**Do not block import or activation.** The user decides how to respond.

### Re-evaluation Triggers

Re-run conflict detection whenever:
- The user changes their tinnitus frequency
- The user activates a different headphone profile
- `autoEQEnabled` or `notchFilterEnabled` toggle state changes

---

## Combined Frequency Response Display

The EQ visualization panel shows three overlaid curves:

| Curve | Color | Label | Can Hide? |
|---|---|---|---|
| AutoEQ correction | Primary accent color | `"Headphone Correction"` | Yes |
| Notch filter | Muted teal or amber | `"Tinnitus Notch"` | Yes |
| Combined output | Thicker white/near-white | `"Final Response"` | No |

The combined output curve is always the arithmetic sum of all active stages. It cannot be hidden.

A vertical reference line at the tinnitus notch frequency is always visible regardless of which curves are shown.

Curve visibility toggles appear as a small legend below the plot. Each has a colored swatch and a label. Tapping a swatch toggles that curve. The combined output swatch is not tappable.

When `autoEQEnabled` is false, the AutoEQ curve is dimmed/dashed rather than removed entirely, so the user can see what they are bypassing.

When `notchFilterEnabled` is false, the notch curve is dimmed/dashed. The vertical reference line remains visible.

---

## Independent Toggle States

Four independent boolean states, each persisted in `AppStorage`:

```swift
@AppStorage("autoEQEnabled")     var autoEQEnabled: Bool     = false
@AppStorage("notchFilterEnabled") var notchFilterEnabled: Bool = false
@AppStorage("manualEQEnabled")   var manualEQEnabled: Bool   = false
@AppStorage("auditumEQEnabled")  var auditumEQEnabled: Bool  = false
```

`auditumEQEnabled` is the master bypass. When false, all stages pass through unmodified and all individual toggle states are visually disabled (greyed out) but their stored values are preserved.

**When `autoEQEnabled` → false:**
- Remove AutoEQ filters from the processing chain.
- Recompute preamp (drop `autoEQPreamp` component, keep only `manualEQHeadroom` if applicable).
- Combined response curve updates immediately.
- Show a subtle `"Headphone correction off"` label near the plot.
- Dismiss any active conflict warning (no active AutoEQ = no conflict possible).

**When `notchFilterEnabled` → false:**
- Remove the notch from the chain.
- Dismiss any active conflict warning.
- Show a subtle `"Tinnitus notch off"` label near the plot.
- If the user has never seen it: show a one-time dismissable reminder banner — `"Notch therapy is most effective with consistent daily use."` Store a `hasShownNotchOffReminder: Bool` flag in `AppStorage`. Never show this reminder more than once.

---

## Safe Listening Dose Monitor Integration

The dose monitor (Stage 0) measures input level before any EQ is applied, but must account for the gain that downstream stages will introduce.

```swift
let peakGainInChain = activeFilters
    .filter { $0.enabled }
    .map { $0.gain }
    .filter { $0 > 0 }
    .max() ?? 0.0

let effectiveInputLevel = measuredInputLevel + max(0.0, peakGainInChain + combinedPreamp)
```

Feed `effectiveInputLevel` into the dose calculation so the monitor is conservative — it assumes the worst-case frequency in the signal is hitting the highest boosted frequency at full amplitude.

Log a developer warning (non-fatal, console only) if `peakGainInChain` ever exceeds `3.0 dB` after the preamp has been applied. This indicates a preamp computation error that should be caught during testing.

---

## Error Handling

| Condition | User-Facing Message | Behavior |
|---|---|---|
| Network unavailable (index fetch) | `"AutoEQ library unavailable offline. Showing cached profiles."` | Non-blocking banner. Cached profiles still work normally. |
| Network unavailable (profile fetch) | `"Can't reach AutoEQ right now. Try again when connected."` | Inline error on the selected search row. Retry button. |
| GitHub rate limit (403) | `"AutoEQ fetch temporarily unavailable. Try again in a few minutes."` | Do not retry automatically more than once per 5 minutes. Store next-retry timestamp. |
| File not found (404) | `"Profile not found. It may have been renamed in AutoEQ."` | Inline error. Include a tappable link to `autoeq.app`. |
| Parse error | `"Could not read this profile. Try a different measurement source."` | Log full parse error to console. Show inline error on row. |
| Index parse yields 0 entries | `"AutoEQ library could not be loaded. Using cached version."` | Fall back to cached index silently. Log details to console. |

All error messages appear inline in the UI (on the row that triggered them, or as a dismissable banner). No modal alerts for any AutoEQ-related error.

---

## Privacy

- No analytics. No logging of which headphone profiles are fetched.
- No user identifiers sent to any server.
- All network traffic goes to `raw.githubusercontent.com` only.
- Cached files are stored in the app's sandboxed `Application Support` directory.
- Deleting a saved profile from the list also deletes the cached `.json` file from disk.
