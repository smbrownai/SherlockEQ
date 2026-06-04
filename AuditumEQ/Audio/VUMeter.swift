import Foundation

/// What "0 VU" means in digital terms. The component doesn't assume a
/// universal meaning — the host app picks the mode that matches its
/// reference frame and supplies a dBFS value where needed.
public enum VUCalibration: Equatable {
    /// EBU R128 / "Standard Digital" alignment. Default −18 dBFS.
    case standardDigital(referenceDBFS: Double = -18)
    /// SMPTE / North American broadcast alignment. Default −20 dBFS.
    case broadcastDigital(referenceDBFS: Double = -20)
    /// 0 VU = the dBFS level corresponding to the user's calibrated
    /// comfortable listening loudness. Host computes the dBFS from its
    /// SPL calibration + the user's selected comfortable dBA level.
    case comfortableListening(referenceDBFS: Double)
    /// Caller-supplied 0 VU reference.
    case custom(referenceDBFS: Double)

    public var referenceDBFS: Double {
        switch self {
        case .standardDigital(let v),
             .broadcastDigital(let v),
             .comfortableListening(let v),
             .custom(let v):
            return v
        }
    }

    /// Plain-language caption for the optional under-meter label. Keep
    /// readable for users who don't have audio-engineering background.
    public var captionLabel: String {
        switch self {
        case .standardDigital(let v):
            return String(format: "0 VU = %.0f dBFS · Standard", v)
        case .broadcastDigital(let v):
            return String(format: "0 VU = %.0f dBFS · Broadcast", v)
        case .comfortableListening:
            return "0 VU = Comfortable level"
        case .custom(let v):
            return String(format: "0 VU = %.1f dBFS", v)
        }
    }
}

/// One-channel state for a critically-damped second-order VU
/// integrator. The IEC/ANSI VU ballistic target is "300 ms rise to
/// within 1% of steady state for a 0 VU sine input." A critically-
/// damped second-order system hits that with ωn ≈ 22.13 rad/s — the
/// numerical solution of (1 + ωn·t)·exp(−ωn·t) = 0.01 at t = 0.3 s.
///
/// Why a second-order critically-damped model rather than a simple
/// low-pass:
///   - matches the mechanical behaviour of a real moving-coil VU
///     meter (mass + spring + dashpot, no overshoot)
///   - rise time and fall time come out symmetric, as the IEC spec
///     requires (within 10 % of each other)
///   - the position is continuous in both value and velocity, which
///     reads as inertia on screen — not a digital tracker
///
/// All integration uses a real time delta, so motion is consistent
/// across 60/120 Hz refresh rates and a single missed frame doesn't
/// produce a visible jump.
public struct VUBallisticsState {

    /// Current needle position in VU (dB above/below 0 VU reference).
    public private(set) var vu: Double = floorVU

    /// Internal velocity in VU/s. Visible for debugging only.
    public private(set) var velocity: Double = 0

    /// Hard floor below the dial. The integrator would otherwise chase
    /// `-Infinity` during silence and take noticeable time to climb
    /// back into the visible range when audio resumes.
    public static let floorVU: Double = -40

    /// ωn for the critically-damped 2nd-order system. 22.13 satisfies
    /// the 300 ms rise-time target. Public so the host can sanity-
    /// check the constant in tests.
    public static let omega: Double = 22.13

    public init() {}

    /// Snap to silence. Use when re-attaching a paused view so the
    /// needle doesn't briefly hold a stale reading.
    public mutating func reset() {
        vu = Self.floorVU
        velocity = 0
    }

    /// Advance by `dt` seconds toward the VU level matching `rms`
    /// (linear amplitude, 0…1) under a 0 VU reference of
    /// `referenceDBFS` dBFS. Pass `rms = 0` for "no audio"; the
    /// needle decays smoothly toward the floor.
    public mutating func update(rms: Double, referenceDBFS: Double, dt: Double) {
        // Clamp dt: zero step is a no-op; a step >100 ms (suspend,
        // missed frames, sleep/wake) would otherwise explode the
        // integrator. Better to take a few smaller virtual steps than
        // to bound the bug.
        let dt = max(0, min(0.1, dt))
        if dt == 0 { return }

        let target: Double
        if rms < 1e-7 {
            target = Self.floorVU
        } else {
            target = 20 * log10(rms) - referenceDBFS
        }

        let omega = Self.omega
        let omegaSq = omega * omega
        let twoZetaOmega = 2 * omega  // ζ = 1, critical damping
        let accel = omegaSq * (target - vu) - twoZetaOmega * velocity
        velocity += accel * dt
        let next = vu + velocity * dt
        if next < Self.floorVU {
            // Clamp + zero velocity so a fast transient-to-silence
            // transition doesn't leave residual downward velocity
            // that would cause a tiny visible bounce at the floor.
            vu = Self.floorVU
            velocity = 0
        } else {
            vu = next
        }
    }
}

/// VU dial scale layout. Tick positions mirror the classic broadcast
/// VU face: the lower scale is compressed and the −3 to +3 region
/// takes up most of the sweep — that's the area the user actually
/// reads. Fractions are along the arc, with 0 = far left of the
/// usable scale and 1 = +3 (also the right end of the arc).
public enum VUScale {

    public struct Tick {
        public let vu: Double
        public let label: String
        public let frac: Double
        /// `true` for the labelled marks (−20, −10, −7, −5, −3, 0,
        /// +1, +2, +3). Minor un-labelled ticks could be added in the
        /// future by setting `isMajor = false`.
        public let isMajor: Bool
    }

    public static let ticks: [Tick] = [
        Tick(vu: -20, label: "20", frac: 0.00, isMajor: true),
        Tick(vu: -10, label: "10", frac: 0.36, isMajor: true),
        Tick(vu:  -7, label:  "7", frac: 0.46, isMajor: true),
        Tick(vu:  -5, label:  "5", frac: 0.54, isMajor: true),
        Tick(vu:  -3, label:  "3", frac: 0.64, isMajor: true),
        Tick(vu:   0, label:  "0", frac: 0.74, isMajor: true),
        Tick(vu:  +1, label:  "1", frac: 0.83, isMajor: true),
        Tick(vu:  +2, label:  "2", frac: 0.92, isMajor: true),
        Tick(vu:  +3, label:  "3", frac: 1.00, isMajor: true)
    ]

    /// Where the 0 VU mark sits on the arc. Reused to place the red
    /// overscale band's left edge.
    public static let zeroFrac: Double = 0.74

    /// Map a VU value to a fractional dial position by piecewise-
    /// linear interpolation between the anchor ticks. Below the
    /// lowest anchor → 0; above the highest → just over 1 so the
    /// needle can peg slightly past +3 without going off the face.
    public static func frac(forVU vu: Double) -> Double {
        guard let first = ticks.first, let last = ticks.last else { return 0 }
        if vu <= first.vu { return first.frac }
        if vu >= last.vu {
            // Allow a small "peg" zone past the last anchor.
            let over = min(3.0, vu - last.vu)
            return last.frac + over * 0.02
        }
        for i in 0..<(ticks.count - 1) {
            let lo = ticks[i], hi = ticks[i + 1]
            if vu >= lo.vu && vu <= hi.vu {
                let t = (vu - lo.vu) / (hi.vu - lo.vu)
                return lo.frac + t * (hi.frac - lo.frac)
            }
        }
        return last.frac
    }
}
