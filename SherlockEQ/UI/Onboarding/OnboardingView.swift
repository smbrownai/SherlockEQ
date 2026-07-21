import SwiftUI
import AppKit
import UserNotifications

/// First-launch onboarding wizard (spec §8.4). A lean five-step flow:
///
///   1. Welcome — a full-bleed hero video + what SherlockEQ does + the
///      mandatory upstream-EQ note.
///   2. Permissions — primes the non-obvious **System Audio Recording**
///      TCC prompt (and the optional notifications prompt) with a plain-
///      language explanation *before* macOS asks. Without this, the first
///      thing a fresh install does is throw a "Screen Recording"-flavored
///      system dialog with zero context — which reads as malware for a
///      hearing-correction app, and silently captures zero buffers if
///      dismissed. See `catap-screen-recording-permission.md`.
///   3. Pick a starting point — choose a starter preset (all already seeded).
///   4. Personalization — *describes* the audiogram, tinnitus, and calibration
///      screens so the user knows where to tune later. Informational only: it
///      used to deep-link out, but jumping ended onboarding early and could
///      only reach one of the three, so the rows no longer navigate.
///   5. You're all set — wayfinding. A menu-bar app disappears once this
///      window closes (no Dock icon by default), so the final step points the
///      user at the status-bar icon and the "Open Main Window" route.
///
/// Deliberately *not* a deep guided audiogram / tinnitus / calibration
/// wizard: those are first-class screens now, so the Personalization step
/// names them rather than duplicating them inline.
///
/// Visual language matches the rest of the app (system colors + a
/// `sectionBox`-style card), per the SettingsView pattern — no separate
/// brand styling.
///
/// `AppDelegate` owns the hosting window and passes `onFinish`. The wizard
/// never sets the completion flag, starts audio, or closes the window
/// itself — it hands an optional deep-link target back through `onFinish`
/// and lets `AppDelegate` sequence the window/policy/audio side effects.
struct OnboardingView: View {

    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    /// Called when the user finishes or skips. A non-nil section asks
    /// `AppDelegate` to open the main window on that screen; nil just
    /// dismisses to the menu bar.
    let onFinish: (SidebarSection?) -> Void

    private enum Step: Int, CaseIterable {
        case welcome, permissions, profile, personalization, allSet
    }
    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            // Padding is applied per step, not blanket: the welcome step runs
            // its hero video edge-to-edge and pads only its own text block,
            // while the other steps keep the standard 28 pt inset.
            Group {
                switch step {
                case .welcome:         OnboardingWelcomeStep()
                case .permissions:     OnboardingPermissionsStep().padding(28)
                case .profile:         OnboardingProfileStep().padding(28)
                case .personalization: OnboardingPersonalizationStep().padding(28)
                case .allSet:          OnboardingAllSetStep().padding(28)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer (Back / progress dots / primary action)

    private var footer: some View {
        ZStack {
            // Progress dots sit at the absolute horizontal center of the
            // window, independent of the Back / primary buttons flanking them.
            dots

            HStack(spacing: 12) {
                if step != .welcome {
                    Button("Back") { goBack() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                Spacer()
                Button(primaryTitle) { goForward() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .overlay(alignment: .topTrailing) {
            // A persistent escape hatch — first launch shouldn't trap anyone.
            // Hidden on the final step, where "Finish" already completes things.
            if step != .allSet {
                Button("Skip") { finish(nil) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.trailing, 28)
                    .padding(.top, 2)
                    .offset(y: -22)
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private var primaryTitle: String {
        step == .allSet ? "Finish" : "Continue"
    }

    private func goForward() {
        switch step {
        case .welcome:         step = .permissions
        case .permissions:     step = .profile
        case .profile:         step = .personalization
        case .personalization: step = .allSet
        case .allSet:          finish(nil)
        }
    }

    private func goBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        step = prev
    }

    private func finish(_ section: SidebarSection?) {
        onFinish(section)
    }
}

// MARK: - Step 1: Welcome

private struct OnboardingWelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            // Full-bleed hero video, flush to the window's top and side edges
            // (a hard rectangular bottom edge, no rounding or fade). Collapses
            // to nothing when no video is bundled — the padded text block below
            // then becomes the whole screen, as the welcome step was before.
            OnboardingIntroVideo()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Welcome to SherlockEQ")
                            .font(.title.weight(.semibold))
                        Text("Real-time hearing adjustment for everything your Mac plays.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                // Upstream-EQ note — spec §8.4 requires the wizard to include
                // it. Wording kept in sync with the footnote on the Equalizer
                // screen so the two surfaces tell the same story.
                OnboardingCard {
                    Label {
                        Text("One thing to check")
                            .font(.callout.weight(.medium))
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.tint)
                    }
                    Text("Equalizers inside other apps — like Music's EQ or Sound Check — shape the audio before it reaches SherlockEQ and stack with its adjustment. For predictable results, keep other apps' equalizers flat.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Step 2: Permissions

private struct OnboardingPermissionsStep: View {
    @EnvironmentObject private var audioState: AudioState
    @ObservedObject private var notifications = NotificationManager.shared
    /// `AudioCapturePermission.preflight()` can't tell "never asked" from
    /// "denied" — both come back non-authorized. So we don't branch the UI
    /// on that distinction: we always offer "Grant access" first (which
    /// shows the TCC prompt when undetermined, or no-ops when hard-denied),
    /// and only fall back to the System Settings deep link *after* a request
    /// attempt has failed to flip us to authorized.
    @State private var audioGranted = false
    @State private var attempted = false
    @State private var requesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Permissions")
                .font(.title.weight(.semibold))
            Text("SherlockEQ needs one permission to do its job, and one optional one for safety alerts.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            audioPermissionCard
            notificationsCard
        }
        .onAppear { audioGranted = (AudioCapturePermission.preflight() == .authorized) }
    }

    // MARK: System Audio Recording (required)

    private var audioPermissionCard: some View {
        OnboardingCard {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.tint)
                Text("System Audio Recording")
                    .font(.callout.weight(.medium))
                Spacer()
                audioBadge
            }
            Text("macOS will ask for permission to record system audio. That's simply how SherlockEQ hears what's playing so it can correct it — nothing is recorded, saved, or sent anywhere. macOS files this under Screen & System Audio Recording, so the name looks broader than it is.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if audioGranted {
                EmptyView()
            } else if !attempted {
                Button {
                    requestAudio()
                } label: {
                    if requesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Grant access")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(requesting)
            } else {
                HStack(spacing: 10) {
                    Button("Open System Settings") { openAudioSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Text("Turn on SherlockEQ there, then relaunch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func requestAudio() {
        requesting = true
        Task {
            _ = await AudioCapturePermission.request()
            let granted = AudioCapturePermission.preflight() == .authorized
            await MainActor.run {
                audioGranted = granted
                attempted = true
                requesting = false
                if !granted {
                    audioState.showNotice(TransientNotice(
                        severity: .warning,
                        message: "System Audio Recording is off. SherlockEQ can run, but it won't process any audio until you grant it in System Settings."
                    ))
                }
            }
        }
    }

    private func openAudioSettings() {
        // 14.x groups this under Screen Recording; 15+ has a dedicated
        // System Audio Recording bucket on the same Privacy pane. The
        // ScreenCapture anchor lands on the right pane in both.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Notifications (optional)

    private var notificationsCard: some View {
        OnboardingCard {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(.tint)
                Text("Safe-listening alerts")
                    .font(.callout.weight(.medium))
                Spacer()
                statusBadge(forNotifications: notifications.authorizationStatus)
            }
            Text("Optional. Get a notification when your daily listening exposure climbs into the at-risk range. You can skip this and turn it on later.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if notifications.authorizationStatus == .notDetermined {
                Button("Enable alerts") { requestNotifications() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if notifications.authorizationStatus == .denied {
                HStack(spacing: 10) {
                    Button("Open System Settings") { openNotificationSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Text("Turn on SherlockEQ under Notifications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestNotifications() {
        Task {
            await NotificationManager.shared.requestAuthorization()
            await MainActor.run {
                audioState.noticeCenter.warnIfNotificationsDenied(
                    status: NotificationManager.shared.authorizationStatus
                )
            }
        }
    }

    // MARK: Status badges

    @ViewBuilder
    private var audioBadge: some View {
        if audioGranted {
            grantedBadge
        } else if attempted {
            badge("Off", systemImage: "xmark.circle.fill", tint: .orange)
        } else {
            badge("Needed", systemImage: "circle.dashed", tint: .secondary)
        }
    }

    @ViewBuilder
    private func statusBadge(forNotifications status: UNAuthorizationStatus) -> some View {
        switch status {
        case .authorized, .provisional, .ephemeral: grantedBadge
        case .denied: badge("Off", systemImage: "xmark.circle.fill", tint: .secondary)
        default:      badge("Optional", systemImage: "circle.dashed", tint: .secondary)
        }
    }

    private var grantedBadge: some View {
        badge("Granted", systemImage: "checkmark.circle.fill", tint: .green)
    }

    private func badge(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
    }
}

// MARK: - Step 3: Profile

private struct OnboardingProfileStep: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    /// Default selection — the neutral preset, matching the app's cold default.
    @State private var selected: HearingProfile.Factory = .musicBalanced

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pick a starting point")
                .font(.title.weight(.semibold))
            Text("Choose a listening preset to begin — you can switch or fine-tune anytime.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(Array(zip(HearingProfile.Factory.allCases, HearingProfile.factoryProfiles)), id: \.0) { factory, preset in
                    choiceRow(factory, preset: preset)
                }
            }
            .onChange(of: selected) { applySelection() }
            .onAppear { applySelection() }

            Text("These are listening-comfort presets, not a medical hearing adjustment.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Profile choice (radio-style, one card per factory preset)

    private func choiceRow(_ value: HearingProfile.Factory, preset: HearingProfile) -> some View {
        let isSelected = selected == value
        return Button {
            selected = value
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.name).font(.callout.weight(.medium))
                    if let description = preset.presetDescription {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Point the active profile at the selected factory preset (by stable id;
    /// it was installed during factory-preset reconciliation at launch).
    private func applySelection() {
        if profileStore.profiles.contains(where: { $0.id == selected.id }) {
            audioState.activeProfileID = selected.id
        }
    }
}

// MARK: - Step 4: Personalization

private struct OnboardingPersonalizationStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Personalization")
                .font(.title.weight(.semibold))
            Text("When you're ready, you can tailor SherlockEQ to your own hearing. Each of these lives on its own screen in the main window — there's nothing you have to set up right now.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            infoRow(symbol: "ear",
                    title: "Audiogram",
                    subtitle: "Plot a hearing test for a tailored adjustment.")
            infoRow(symbol: "bandage",
                    title: "Tinnitus pitch",
                    subtitle: "Match a tone to your ringing and notch it out.")
            infoRow(symbol: "shield.lefthalf.filled",
                    title: "Safe-listening calibration",
                    subtitle: "Match levels to an SPL meter for accurate exposure tracking.")

            OnboardingCard {
                Label {
                    Text("All optional")
                        .font(.callout.weight(.medium))
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.tint)
                }
                Text("None of these are required to start listening — set them up anytime from the main window. Each is saved per profile, so every profile can be personalized differently.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Informational row — names where each adjustment lives in the main
    /// window. Deliberately NOT a navigation link: jumping out here would end
    /// onboarding before the final step, and you could only ever reach one of
    /// the three before the wizard closed.
    private func infoRow(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

// MARK: - Step 5: You're all set

/// Closing wayfinding step. A menu-bar app vanishes from view once the
/// onboarding window closes (no Dock icon by default), so the last thing the
/// user sees points them at the status-bar icon and the "Open Main Window"
/// route — otherwise a fresh install looks like it quit.
private struct OnboardingAllSetStep: View {
    @EnvironmentObject private var preferences: AppPreferences

    /// True when the built-in display has a notch (a non-zero top safe-area
    /// inset). Notched Macs are where the menu-bar icon most often goes
    /// missing, so the copy names the situation directly rather than in the
    /// abstract. Not definitive — a crowded menu bar hides icons on
    /// non-notched Macs too — which is why the guidance below applies either
    /// way and only the lead sentence is tailored.
    private var hasNotch: Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    /// The Dock-icon toggle is the inverse of `hideFromDockEnabled` (on by
    /// default). Showing it here is the one reliable escape from the dead-end
    /// this step exists to prevent: if the menu-bar icon is hidden and there's
    /// no Dock icon, a menu-bar-only app has no way back on screen.
    private var keepInDock: Binding<Bool> {
        Binding(
            get: { !preferences.hideFromDockEnabled },
            set: { preferences.hideFromDockEnabled = !$0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("You're all set")
                .font(.title.weight(.semibold))
            Text("SherlockEQ runs quietly in your menu bar — it doesn't keep a window open or a Dock icon, so it stays out of your way.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            OnboardingCard {
                HStack(alignment: .top, spacing: 12) {
                    // Same glyph the status item shows, so it's recognizable.
                    Image(systemName: "waveform.and.magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundStyle(.tint)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Look for this icon in your menu bar")
                            .font(.callout.weight(.medium))
                        // Honest about the limitation: macOS can hide a
                        // status item behind the notch or off a full menu bar,
                        // and gives the app no way to force it back or even
                        // know it's gone. So we set the expectation rather than
                        // promising "top-right" unconditionally.
                        Text(hasNotch
                             ? "It sits near the top-right. Your Mac has a notch, so if your menu bar is full the icon can be hidden behind it — the Dock option below is the sure way to keep SherlockEQ reachable."
                             : "It sits at the top-right. If your menu bar is crowded, macOS may hide it — the Dock option below keeps SherlockEQ reachable either way.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            OnboardingCard {
                Toggle(isOn: keepInDock) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keep SherlockEQ in the Dock")
                            .font(.callout.weight(.medium))
                        Text("A dependable way back to the app if the menu-bar icon is ever hard to find. You can change this later in Settings.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }

            OnboardingCard {
                Label {
                    Text("Opening the app")
                        .font(.callout.weight(.medium))
                } icon: {
                    Image(systemName: "macwindow")
                        .foregroundStyle(.tint)
                }
                Text("The main window opens now — the audiogram, equalizer, profiles, and every setting. Close it whenever you like; SherlockEQ keeps running. Reopen it from the menu-bar icon (or the Dock, if you kept it).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Shared card

/// `sectionBox`-equivalent for the onboarding surface (kept local so the
/// wizard doesn't reach into SettingsView's private helper).
private struct OnboardingCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}
