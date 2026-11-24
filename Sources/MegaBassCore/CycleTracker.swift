import Foundation

/// One period of the low-band waveform, as the speakers will play it.
public struct BassCycle: Sendable {
    /// Start of the period (same clock as the input time).
    public var start: Double
    /// Length in seconds; 1/period is the frequency the motor plays.
    public var period: Double
    /// Peak of this period, 0...1 after auto-gain.
    public var amp: Float
}

/// Band-passes the audio to the low band and cuts it into single waveform periods at upward zero
/// crossings. Each period goes to the motor as one actuation at that period's own frequency, so the
/// trackpad replays the music's bass cycle by cycle.
///
/// A period is emitted the moment it STARTS, with the length and peak of the one before it: bass
/// periods change slowly, and waiting for each to finish would add a whole period of lag.
public final class CycleTracker {
    public let sampleRate: Double
    public private(set) var lowHz: Double = 30
    public private(set) var highHz: Double = 120
    private var lp1, lp2, hp1: Biquad
    private var prev: Float = 0
    private var armed = false
    private var lastCross: Double = 0
    private var cycleMax: Float = 0
    private var peak: Float = 1e-4
    private let peakDecay: Float
    private var samplesSinceCross = 0
    private var lastPeriod: Double = 0
    private var lastAmp: Float = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        lp1 = Biquad(lowpass: 120, sr: sampleRate); lp2 = lp1
        hp1 = Biquad(highpass: 30, sr: sampleRate)
        peakDecay = Float(exp(-1 / (3 * sampleRate)))     // auto-gain falls back over ~3 s
    }

    /// The band the motor plays: `low` is the floor (Hz), `high` the cutoff.
    public func setBand(low: Double, high: Double) {
        let lo = max(15, min(150, low)), hi = max(lo * 1.5, min(400, high))
        if lo != lowHz { lowHz = lo; hp1 = Biquad(highpass: lo, sr: sampleRate) }
        if hi != highHz {
            highHz = hi
            lp1 = Biquad(lowpass: hi, sr: sampleRate); lp2 = lp1
        }
    }

    public func process(_ samples: UnsafeBufferPointer<Float>, time: Double, emit: (BassCycle) -> Void) {
        let minPeriod = 0.6 / highHz, maxPeriod = 1.5 / lowHz
        let maxGap = Int(maxPeriod * sampleRate)
        for (i, x) in samples.enumerated() {
            let y = hp1.run(lp2.run(lp1.run(x)))
            let a = abs(y)
            if a > cycleMax { cycleMax = a }
            peak = max(a, peak * peakDecay, 1e-4)
            let h = max(peak * 0.06, 2e-4)                 // hysteresis: noise can't make crossings
            if y < -h { armed = true }
            samplesSinceCross += 1
            if armed, prev <= 0, y > 0 {
                let frac = Double(-prev / (y - prev))
                let t = time + (Double(i) - 1 + frac) / sampleRate
                if lastCross > 0 {
                    let period = t - lastCross
                    if period >= minPeriod, period <= maxPeriod, cycleMax > 0.0015 {
                        lastPeriod = period
                        lastAmp = min(1, cycleMax / peak)
                    } else {
                        lastPeriod = 0
                    }
                }
                // The period starting now, predicted from the one that just ended.
                if lastPeriod > 0 { emit(BassCycle(start: t, period: lastPeriod, amp: lastAmp)) }
                lastCross = t
                cycleMax = 0
                armed = false
                samplesSinceCross = 0
            }
            if samplesSinceCross > maxGap { lastCross = 0; lastPeriod = 0 }   // silence: restart cleanly
            prev = y
        }
    }
}
