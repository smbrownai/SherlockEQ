import Foundation
import CoreGraphics

/// Log-spaced frequency axis. Maps between Hz and a 0…1 fraction along
/// an axis whose endpoints are `minHz` and `maxHz` in log space. Used
/// anywhere a frequency draws against a horizontal width — the parametric
/// canvas, the audiogram EQ preview, the tone finder — so the same
/// mapping doesn't get rewritten (with subtly different `let logMin =
/// log10(...)` boilerplate) at every call site.
///
/// Precomputes `log10` of the endpoints once at construction. Inverses
/// are exact (`hz(forFrac(forHz: x)) == x` modulo floating-point), so
/// round-tripping pixel coordinates through this struct is safe.
struct LogFreqAxis {
    let minHz: Double
    let maxHz: Double
    let logMin: Double
    let logMax: Double

    init(minHz: Double, maxHz: Double) {
        self.minHz = minHz
        self.maxHz = maxHz
        self.logMin = log10(minHz)
        self.logMax = log10(maxHz)
    }

    var logRange: Double { logMax - logMin }

    /// Hz → 0…1 fraction along the axis. Hz outside `[minHz, maxHz]`
    /// returns a fraction outside [0, 1] — call `frac(forHz:clamped:)`
    /// or clamp at the call site if you need it bounded.
    func frac(forHz hz: Double) -> Double {
        (log10(hz) - logMin) / logRange
    }

    /// Hz → fraction, clamped to [0, 1].
    func frac(forHz hz: Double, clamped: Bool) -> Double {
        let f = frac(forHz: hz)
        return clamped ? max(0, min(1, f)) : f
    }

    /// 0…1 fraction → Hz. Inverse of `frac(forHz:)`.
    func hz(forFrac frac: Double) -> Double {
        pow(10, logMin + frac * logRange)
    }

    /// Hz → x in a `width`-pixel-wide region. Clamps Hz to the axis
    /// endpoints first, so out-of-range frequencies land on the edge
    /// rather than off-canvas.
    func x(forHz hz: Double, width: CGFloat) -> CGFloat {
        let clamped = max(minHz, min(maxHz, hz))
        return width * CGFloat(frac(forHz: clamped))
    }

    /// x in a `width`-pixel-wide region → Hz. Clamps `x` to [0, width]
    /// before mapping so a drag past the canvas edge stays in range.
    func hz(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return minHz }
        let f = max(0, min(1, Double(x / width)))
        return hz(forFrac: f)
    }
}
