import Accelerate
import Foundation

/// The song's tempo and beat grid, from the audio itself. An onset envelope at 200 frames a second
/// (rises in broadband and low-band amplitude) is autocorrelated over the last 8 s. The range is
/// 60-160 BPM (faster songs read half time); a prior around 110 BPM and support from the doubled
/// lag settle the octave; peaks at 1-4x the lag refine the
/// period below one frame. A comb over the window places the beats, and the stronger of the two
/// alternate beats marks the half-time "bang" (usually beats 1 and 3, where the kick lands).
public final class TempoTracker {
    public struct Beat: Sendable {
        public var bpm = 0.0
        /// The latest beat, in the time base given to `process` (speaker time in the app).
        public var beatAt = 0.0
        /// The latest half-time beat (every second beat, the stronger one).
        public var bangAt = 0.0
        /// 0...1: how clearly the envelope repeats at this tempo.
        public var confidence = 0.0
        public var period: Double { bpm > 0 ? 60 / bpm : 0 }
        public init() {}
    }

    public static let frameRate = 200.0
    public let sampleRate: Double
    public private(set) var beat = Beat()

    private let hop: Int
    private let size: Int
    private var energy = 0.0, energyLow = 0.0, count = 0
    private var lp = 0.0
    private let lpA: Double, envA: Double
    private var prevE = 0.0, prevL = 0.0
    private var onset: [Double]
    private var pos = 0, filled = 0, sinceEstimate = 0
    private var lastFrameTime = 0.0
    private var estimates: [Double] = []

    public init(sampleRate: Double, seconds: Double = 8) {
        self.sampleRate = sampleRate
        hop = max(1, Int((sampleRate / Self.frameRate).rounded()))
        size = Int(seconds * Self.frameRate)
        onset = [Double](repeating: 0, count: size)
        lpA = 1 - exp(-2 * .pi * 150 / sampleRate)
        envA = 1 - exp(-1 / (0.012 * sampleRate))
    }

    /// `time`: when `samples[0]` plays (the same time base the beats come back in).
    public func process(_ samples: UnsafeBufferPointer<Float>, time: Double) {
        for (i, s) in samples.enumerated() {
            let x = Double(s)
            lp += lpA * (x - lp)
            // Energy envelopes over ~12 ms: longer than a bass cycle, so they follow attacks and
            // not the waveform itself.
            energy += envA * (x * x - energy)
            energyLow += envA * (lp * lp - energyLow)
            count += 1
            if count >= hop {
                // Rises in RMS amplitude (not dB): a note starting after silence must not outweigh a kick.
                let e = energy.squareRoot()
                let l = energyLow.squareRoot()
                let o = 0.4 * max(0, e - prevE) + 1.6 * max(0, l - prevL)      // the kick and bass lead
                prevE = e; prevL = l
                count = 0
                onset[pos] = o
                pos = (pos + 1) % size
                filled = min(size, filled + 1)
                lastFrameTime = time + Double(i + 1) / sampleRate
                sinceEstimate += 1
                if sinceEstimate >= Int(Self.frameRate / 2), filled >= Int(Self.frameRate * 4) {
                    sinceEstimate = 0
                    estimate()
                }
            }
        }
    }

    private func estimate() {
        let n = filled
        var o = [Double](repeating: 0, count: n)
        for k in 0..<n { o[k] = onset[(pos - n + k + size) % size] }
        let mean = o.reduce(0, +) / Double(n)
        for k in 0..<n { o[k] -= mean }
        let fr = Self.frameRate
        let lMin = Int(fr * 60 / 160), lMax = Int(fr * 60 / 60)
        let top = min(n / 2, lMax * 4 + 2)
        var ac = [Double](repeating: 0, count: top + 1)
        o.withUnsafeBufferPointer { p in
            for lag in 0...top {
                var s = 0.0
                vDSP_dotprD(p.baseAddress! + lag, 1, p.baseAddress!, 1, &s, vDSP_Length(n - lag))
                ac[lag] = s / Double(n - lag)
            }
        }
        guard ac[0] > 1e-9 else { beat.confidence = 0; return }
        // Score each beat period by its comb in lag space: repetition at 1, 2, 3 and 4 beats (a bar).
        // Syncopated tempos (2/3, 3/2 of the beat) line up with only some of those; a tempo prior
        // settles what is left.
        func near(_ x: Double) -> Double {
            let c = Int(x.rounded())
            guard c >= 1, c + 1 <= top else { return 0 }
            return max(ac[c - 1], ac[c], ac[c + 1])
        }
        func score(_ lag: Double) -> Double {
            let bpm = 60 * fr / lag
            let prior = exp(-0.5 * pow(log2(bpm / 110) / 0.9, 2))
            return (near(lag) + near(2 * lag) + 0.5 * near(3 * lag) + near(4 * lag)) * prior
        }
        var best = 0, bestScore = -Double.infinity
        for lag in lMin...lMax {
            let s = score(Double(lag))
            if s > bestScore { bestScore = s; best = lag }
        }
        // Stay with the current tempo unless a rival is clearly better.
        if beat.bpm > 0 {
            let curLag = beat.period * fr
            if bestScore < score(curLag) * 1.15 { best = Int(curLag.rounded()) }
        }
        // Refine: a parabola through each of the peaks at 1-4x the lag; longer lags are more exact.
        func peak(near l: Int) -> Double? {
            guard l >= 2, l + 2 <= top else { return nil }
            var m = l
            for c in (l - 2)...(l + 2) where ac[c] > ac[m] { m = c }
            guard m > 0, m < top else { return nil }
            let a = ac[m - 1], b = ac[m], c = ac[m + 1]
            let d = a - 2 * b + c
            return Double(m) + (d < 0 ? 0.5 * (a - c) / d : 0)
        }
        var sum = 0.0, wsum = 0.0
        for k in 1...4 {
            guard let p = peak(near: best * k) else { continue }
            sum += p / Double(k) * Double(k); wsum += Double(k)
        }
        guard wsum > 0 else { return }
        let periodFrames = sum / wsum
        let period = periodFrames / fr
        // Hold steady against a single odd estimate; follow a change once it repeats.
        estimates.append(period)
        if estimates.count > 5 { estimates.removeFirst() }
        let med = estimates.sorted()[estimates.count / 2]
        let cur = beat.period
        let smoothed: Double
        if cur == 0 || abs(med - cur) / cur > 0.03 { smoothed = med } else { smoothed = cur + (med - cur) * 0.4 }
        beat.bpm = 60 / smoothed
        beat.confidence = max(0, min(1, ac[best] / ac[0]))
        // Phase: the offset whose comb (every second beat back from now) collects the most onset.
        // Two beats, not one: the bar's strong kicks (1 and 3) then line up only on the true grid,
        // where off-beat hats and syncopated kicks could pull a one-beat comb half a beat off.
        let pf = smoothed * fr
        func comb(_ phase: Double) -> Double {
            var s = 0.0, k = 0.0, w = 1.0
            while true {
                let idx = Int((Double(n - 1) - phase - k * 2 * pf).rounded())
                if idx < 0 { break }
                // ±10 ms around each step: an onset peak is only a few frames wide.
                var v = 0.0
                for j in max(0, idx - 2)...min(n - 1, idx + 2) { v += o[j] }
                s += v * w; k += 1; w *= 0.85               // recent bars count most
            }
            return s
        }
        var bestPhase = 0.0, bestComb = -Double.infinity
        for phase in 0...Int(2 * pf) {
            let s = comb(Double(phase))
            if s > bestComb { bestComb = s; bestPhase = Double(phase) }
        }
        // Keep the grid carried forward from the last bang unless the new phase is clearly better:
        // a syncopated kick can briefly outweigh the downbeat that follows it.
        if beat.bangAt > 0 {
            let bar = 2 * smoothed
            let carried = beat.bangAt + ((lastFrameTime - beat.bangAt) / bar).rounded(.down) * bar
            let phase = (lastFrameTime - carried) * fr
            if phase >= 0, phase <= 2 * pf, bestComb < comb(phase) * 1.2 { bestPhase = phase }
        }
        let bangAt = lastFrameTime - bestPhase / fr
        beat.bangAt = bangAt
        beat.beatAt = bangAt + smoothed <= lastFrameTime ? bangAt + smoothed : bangAt
    }
}
