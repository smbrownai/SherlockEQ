//
//  AutoEQMismatchTests.swift
//  SherlockEQTests
//
//  Truth table for the headphone-correction ↔ output-device mismatch check
//  (phase3-make-correction-land.md §7). Every guard in
//  `AutoEQMismatch.evaluate` gets a row; the motivating incident (a DT770
//  correction active on built-in speakers) is the positive case.
//

import Testing
import Foundation
@testable import SherlockEQ

struct AutoEQMismatchTests {

    /// A profile carrying a correction attached on the "DT770-UID" device.
    private func correctedProfile(
        deviceUID: String? = "DT770-UID",
        deviceName: String? = "DT770 Pro X",
        bands: Bool = true
    ) -> HearingProfile {
        var p = HearingProfile.makeDefault(name: "Test")
        p.autoEQName = "Beyerdynamic DT770 Pro X"
        p.autoEQBands = bands
            ? [EQBand(frequencyHz: 100, gaindB: -3, bandwidth: 1, filterType: .parametric, enabled: true)]
            : nil
        p.autoEQPreampDB = -6
        p.autoEQDeviceUID = deviceUID
        p.autoEQDeviceName = deviceName
        return p
    }

    private func evaluate(
        profile: HearingProfile?,
        stageEnabled: Bool = true,
        currentUID: String? = "Speakers-UID",
        currentName: String = "MacBook Air Speakers",
        builtIn: Bool = true,
        dismissed: Set<String> = []
    ) -> AutoEQMismatch? {
        AutoEQMismatch.evaluate(
            profile: profile,
            autoEQStageEnabled: stageEnabled,
            currentDeviceUID: currentUID,
            currentDeviceName: currentName,
            currentIsBuiltInSpeakers: builtIn,
            dismissedKeys: dismissed
        )
    }

    // MARK: - The positive case (the DT770-on-speakers incident)

    @Test func mismatchedDeviceProducesWarning() {
        let mismatch = evaluate(profile: correctedProfile())
        #expect(mismatch != nil)
        #expect(mismatch?.correctionName == "Beyerdynamic DT770 Pro X")
        #expect(mismatch?.attachedDeviceName == "DT770 Pro X")
        #expect(mismatch?.currentDeviceName == "MacBook Air Speakers")
        #expect(mismatch?.currentIsBuiltInSpeakers == true)
        // Built-in speakers get the categorical copy.
        #expect(mismatch?.message.contains("built-in speakers") == true)
    }

    @Test func nonBuiltInMismatchUsesNormalCopy() {
        let mismatch = evaluate(profile: correctedProfile(), currentName: "AirPods Pro", builtIn: false)
        #expect(mismatch != nil)
        #expect(mismatch?.message.contains("built-in speakers") == false)
    }

    // MARK: - Every guard

    @Test func matchingDeviceIsSilent() {
        #expect(evaluate(profile: correctedProfile(), currentUID: "DT770-UID") == nil)
    }

    @Test func legacyCorrectionWithoutRecordedDeviceIsSilent() {
        // No fuzzy name matching, no guessing — nil UID means no warning
        // until the correction is re-attached.
        #expect(evaluate(profile: correctedProfile(deviceUID: nil, deviceName: nil)) == nil)
    }

    @Test func noCorrectionIsSilent() {
        #expect(evaluate(profile: correctedProfile(bands: false)) == nil)
    }

    @Test func disabledStageIsSilent() {
        // Bypassed correction shapes nothing — nothing to warn about.
        #expect(evaluate(profile: correctedProfile(), stageEnabled: false) == nil)
    }

    @Test func unknownCurrentDeviceIsSilent() {
        #expect(evaluate(profile: correctedProfile(), currentUID: nil) == nil)
    }

    @Test func noProfileIsSilent() {
        #expect(evaluate(profile: nil) == nil)
    }

    // MARK: - Dismissal memory

    @Test func dismissedCombinationStaysSilent() {
        let profile = correctedProfile()
        let key = AutoEQMismatch.dismissalKey(profileID: profile.id, deviceUID: "Speakers-UID")
        #expect(evaluate(profile: profile, dismissed: [key]) == nil)
    }

    @Test func dismissalIsPerDevice() {
        // Dismissing on the speakers doesn't silence a later mismatch on
        // a third device.
        let profile = correctedProfile()
        let key = AutoEQMismatch.dismissalKey(profileID: profile.id, deviceUID: "Speakers-UID")
        let onThirdDevice = evaluate(
            profile: profile, currentUID: "HDMI-UID",
            currentName: "LG Display", builtIn: false,
            dismissed: [key]
        )
        #expect(onThirdDevice != nil)
    }
}
