import Foundation
import Combine

/// One step of undo for the popover's quick tone adjustments, plus the note
/// explaining what the last nudge managed to do.
///
/// The popover has no `UndoManager` — that lives on the main window — so a
/// nudge made with the window closed would otherwise be unrecoverable without
/// opening the Equalizer and dragging five sliders back by eye. This is the
/// escape hatch. (When the main window *is* open, `ProfileStore` also
/// registers its own undo entry, so ⌘Z works there too; this button is the
/// path that doesn't depend on that.)
///
/// Deliberately one step deep. A popover isn't a document, and a stack would
/// invite treating it as one.
///
/// **Staleness is the whole design problem here.** A snapshot taken before a
/// nudge is only safe to restore while nothing else has touched those bands.
/// If the user drags a Graphic slider, runs `sherlockeq`, switches profiles, or
/// loads a preset, restoring would silently clobber that newer work. So the
/// snapshot records the gains it *expected* to leave behind and re-checks them
/// before offering undo: if reality has moved on, the button quietly disappears
/// instead of becoming a trap.
@MainActor
final class QuickAdjustHistory: ObservableObject {

    /// Shared instance, following `HelpCenter.shared`.
    ///
    /// A singleton rather than an injected `@EnvironmentObject` specifically
    /// because the only consumer lives inside a `MenuBarExtra`. A missing
    /// environment object is a hard crash on first access, and the popover is
    /// built lazily on first open — so that crash would be invisible to every
    /// build and test check and would land on the user, in a menu-bar app that
    /// has no other window to fall back to. There is no plausible second
    /// instance of "the last quick adjustment", so the injection bought
    /// nothing to offset that.
    static let shared = QuickAdjustHistory()

    private init() {}

    struct Snapshot {
        let profileID: UUID
        /// Only the centers the macro touched.
        let centers: [Double]
        let previousLeft: [Double]
        let previousRight: [Double]
        /// What we wrote — the staleness check compares against this.
        let expectedLeft: [Double]
        let expectedRight: [Double]
        /// e.g. "More bass", for the button's tooltip.
        let actionName: String
    }

    @Published private(set) var snapshot: Snapshot?

    /// Transient result of the last nudge, shown under the buttons. Cleared on
    /// the next action so it never becomes ambient text the user stops reading.
    @Published private(set) var note: String?

    func record(_ snapshot: Snapshot, note: String?) {
        self.snapshot = snapshot
        self.note = note
    }

    func setNote(_ note: String?) {
        self.note = note
    }

    func clear() {
        snapshot = nil
        note = nil
    }

    /// The snapshot, but only if it's still safe to apply to `profile`.
    ///
    /// Requires both that it belongs to this profile and that the bands still
    /// hold the values the nudge left there. The tolerance is well below the
    /// 0.1 dB the UI ever displays, so it catches real edits without tripping
    /// on float round-tripping through JSON.
    func usableSnapshot(for profile: HearingProfile) -> Snapshot? {
        guard let snapshot, snapshot.profileID == profile.id else { return nil }
        let left = ToneMacro.gains(at: snapshot.centers, in: profile.leftEar.bands)
        let right = ToneMacro.gains(at: snapshot.centers, in: profile.rightEar.bands)
        guard matches(left, snapshot.expectedLeft), matches(right, snapshot.expectedRight) else {
            return nil
        }
        return snapshot
    }

    private func matches(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.0001 }
    }
}
