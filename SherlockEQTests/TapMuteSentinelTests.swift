import Testing
import Foundation
@testable import SherlockEQ

struct TapMuteSentinelTests {

    private func scratchDefaults() -> UserDefaults {
        // A throwaway suite so the test never touches the production domain.
        let name = "tapmute.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - Decision (the conservative guards)

    @Test func recoversWhenWeOwnTheMuteAndDeviceMatches() {
        let m = TapMuteSentinel.Marker(deviceUID: "dev-A", preTapMuted: false)
        #expect(TapMuteSentinel.shouldUnmute(marker: m, currentDeviceUID: "dev-A", currentlyMuted: true))
    }

    @Test func leavesAUserSetMuteAlone() {
        // preTapMuted == true → the device was already muted before we tapped;
        // that mute is the user's, so we must not clear it.
        let m = TapMuteSentinel.Marker(deviceUID: "dev-A", preTapMuted: true)
        #expect(!TapMuteSentinel.shouldUnmute(marker: m, currentDeviceUID: "dev-A", currentlyMuted: true))
    }

    @Test func doesNothingWhenNotMuted() {
        let m = TapMuteSentinel.Marker(deviceUID: "dev-A", preTapMuted: false)
        #expect(!TapMuteSentinel.shouldUnmute(marker: m, currentDeviceUID: "dev-A", currentlyMuted: false))
    }

    @Test func doesNotTouchADifferentDevice() {
        // Default output changed since the crash — don't unmute a device the
        // user may have muted deliberately.
        let m = TapMuteSentinel.Marker(deviceUID: "dev-A", preTapMuted: false)
        #expect(!TapMuteSentinel.shouldUnmute(marker: m, currentDeviceUID: "dev-B", currentlyMuted: true))
    }

    @Test func allowsWhenUIDsCannotBeCompared() {
        // A nil on either side can't prove a mismatch; the common single-device
        // case still recovers.
        let m1 = TapMuteSentinel.Marker(deviceUID: nil, preTapMuted: false)
        #expect(TapMuteSentinel.shouldUnmute(marker: m1, currentDeviceUID: "dev-A", currentlyMuted: true))
        let m2 = TapMuteSentinel.Marker(deviceUID: "dev-A", preTapMuted: false)
        #expect(TapMuteSentinel.shouldUnmute(marker: m2, currentDeviceUID: nil, currentlyMuted: true))
    }

    // MARK: - Persistence lifecycle

    @Test func markThenReadThenClear() {
        let d = scratchDefaults()
        #expect(TapMuteSentinel.staleMarker(defaults: d) == nil)

        TapMuteSentinel.markActive(deviceUID: "dev-A", preTapMuted: false, defaults: d)
        let read = TapMuteSentinel.staleMarker(defaults: d)
        #expect(read == TapMuteSentinel.Marker(deviceUID: "dev-A", preTapMuted: false))

        TapMuteSentinel.clear(defaults: d)
        #expect(TapMuteSentinel.staleMarker(defaults: d) == nil)
    }

    @Test func cleanTeardownLeavesNoStaleMarker() {
        // Simulate a clean run: mark on start, clear on teardown → next launch
        // sees nothing to recover.
        let d = scratchDefaults()
        TapMuteSentinel.markActive(deviceUID: "dev-A", preTapMuted: false, defaults: d)
        TapMuteSentinel.clear(defaults: d)
        #expect(TapMuteSentinel.staleMarker(defaults: d) == nil)
    }
}
