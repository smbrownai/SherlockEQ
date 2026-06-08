import Foundation
import Darwin
import OSLog

/// Preflight + request the System Audio Recording TCC permission that
/// Apple's CATap (Core Audio Process Tap) API requires.
///
/// There is no public API for this bucket. Apple ships
/// `NSAudioCaptureUsageDescription` (the Info.plist key) and the implicit
/// prompt that fires on first `AudioHardwareCreateProcessTap`, but no
/// `CGRequestSystemAudioCaptureAccess` / `AVCaptureDevice` equivalent.
/// `CGRequestScreenCaptureAccess` works but routes the app into the
/// broader Screen & System Audio Recording bucket — wrong place for an
/// audio-only tool. The widely-used workaround is to dlopen Apple's TCC
/// private framework and call its preflight/request directly, against
/// service name `kTCCServiceAudioCapture`.
///
/// Same service on macOS 14 and 15+ — the OS-level service identifier
/// hasn't changed; only the Settings UI grouping did (standalone bucket
/// on 15+, grouped under Screen Recording on 14.x). No `#available`
/// branch needed.
///
/// Modeled on insidegui/AudioCap's `AudioRecordingPermission.swift`,
/// the de-facto reference implementation for CATap apps.
/// See https://github.com/insidegui/AudioCap.
enum AudioCapturePermission {

    enum Status {
        case undetermined
        case denied
        case authorized
    }

    /// TCC service identifier for system audio capture. Stable string,
    /// owned by Apple — not something we're synthesizing.
    private static let service = "kTCCServiceAudioCapture" as CFString

    private static let log = Logger(
        subsystem: "com.shawnbrown.SherlockEQ",
        category: "AudioCapturePermission"
    )

    /// Synchronous: returns the current grant state without prompting.
    /// Returns `.undetermined` if the SPI can't be loaded (in which case
    /// callers should fall through to `request()` — the implicit prompt
    /// on first CATap call is still a valid fallback).
    static func preflight() -> Status {
        guard let preflightFn = loadPreflight() else { return .undetermined }
        // TCCAccessPreflight returns 0 when authorized, non-zero when not.
        // The non-zero space includes both "denied" and "undetermined"; the
        // SPI doesn't distinguish in this codepath, so we conservatively
        // treat any non-zero as "needs request" — `request()` will then
        // either prompt (undetermined) or return the recorded deny.
        let result = preflightFn(service, nil)
        return result == 0 ? .authorized : .denied
    }

    /// Triggers the TCC dialog if needed; returns whether access is
    /// granted. If the SPI can't be loaded the returned value is `false`
    /// — caller should surface a clear "couldn't request permission"
    /// error rather than silently proceeding.
    static func request() async -> Bool {
        guard let requestFn = loadRequest() else {
            log.error("Could not load TCCAccessRequest from TCC.framework")
            return false
        }
        return await withCheckedContinuation { continuation in
            requestFn(service, nil) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - SPI loading

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn   = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let handle: UnsafeMutableRawPointer? = {
        let path = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
        let h = dlopen(path, RTLD_NOW)
        if h == nil {
            log.error("dlopen TCC.framework failed: \(String(cString: dlerror()))")
        }
        return h
    }()

    private static func loadPreflight() -> PreflightFn? {
        guard let h = handle, let sym = dlsym(h, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)
    }

    private static func loadRequest() -> RequestFn? {
        guard let h = handle, let sym = dlsym(h, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFn.self)
    }
}
