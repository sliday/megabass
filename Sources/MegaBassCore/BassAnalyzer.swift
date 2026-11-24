import Foundation

/// One 10 ms analysis step of the low end.
public struct BassFrame: Sendable {
    /// Host time in seconds when this audio was captured.
    public var time: Double = 0
    /// 0...1 sub band (< 120 Hz) loudness, auto-gained.
    public var sub: Float = 0
    /// 0...1 bass band (< 350 Hz) loudness, auto-gained.
    public var bass: Float = 0
    /// Kick strength 0...1 when a low-end onset starts in this frame, else 0.
    public var kick: Float = 0
    /// When the kick started (same clock as `time`), to 2.5 ms.
    public var kickTime: Double = 0
    /// Bass / low-voice fundamental in Hz, 0 when nothing pitched.
    public var pitch: Float = 0
    public init() {}
}

/// RBJ biquad low-pass.
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0
    init(lowpass f: Double, q: Double = 0.7071, sr: Double) {
        let w = 2 * Double.pi * f / sr, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        b0 = Float((1 - c) / 2 / a0); b1 = Float((1 - c) / a0); b2 = b0
        a1 = Float(-2 * c / a0); a2 = Float((1 - alpha) / a0)
    }
    init(highpass f: Double, q: Double = 0.7071, sr: Double) {
        let w = 2 * Double.pi * f / sr, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        b0 = Float((1 + c) / 2 / a0); b1 = Float(-(1 + c) / a0); b2 = b0
        a1 = Float(-2 * c / a0); a2 = Float((1 - alpha) / a0)
    }
    @inline(__always) mutating func run(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Splits incoming audio into a sub band (kicks) and a bass band (bass line, low voices),
/// and every 10 ms reports loudness, kick onsets and the bass fundamental (YIN).
public final class BassAnalyzer {
    public let sampleRate: Double
    /// Sub band cutoff (Hz): what counts as felt bass for the rumble level and kick detection.
    public private(set) var crossover: Double = 100
    private var sub1, sub2, kick1, kick2, bass1, bass2, hp1, hp2: Biquad
    private let decim: Int
    private let lowRate: Double
    private var decimCount = 0

    // Low-rate bass ring for pitch detection.
    private var ring: [Float]
    private var ringPos = 0
    private let window: Int, tauMin: Int, tauMax: Int
    private var yin: [Float]

    // Per-hop accumulators.
    private let hop: Int
    private var hopCount = 0
    private var subSq: Float = 0, bassSq: Float = 0
    private var subHist: [Float] = [0, 0, 0, 0], bassHist: [Float] = [0, 0, 0, 0]
    private var histPos = 0
    // Kick onsets run on 2.5 ms blocks for timing.
    private let block: Int
    private var blockCount = 0
    private var blockSq: Float = 0
    private var onsetSlow: Float = 0
    private var pendingKick: Float = 0
    private var pendingKickTime: Double = 0
    private var blockTime: Double = 0

    // Envelopes and auto-gain.
    private var subPeak: Float = 1e-4, bassPeak: Float = 1e-4, kickPeak: Float = 1e-4
    private var sinceKick = 1000
    private var pitchHist: [Float] = [0, 0, 0]
    private var frameIndex = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        sub1 = Biquad(lowpass: crossover, sr: sampleRate); sub2 = sub1
        kick1 = Biquad(lowpass: 120, sr: sampleRate); kick2 = kick1     // kick detector: fixed band
        bass1 = Biquad(lowpass: 350, sr: sampleRate); bass2 = bass1
        // Pitch path drops < 60 Hz: kicks are near-sines down there and beat against the bass.
        // Bass notes keep their period through their harmonics.
        hp1 = Biquad(highpass: 60, sr: sampleRate); hp2 = hp1
        decim = max(1, Int((sampleRate / 4000).rounded()))
        lowRate = sampleRate / Double(decim)
        tauMin = Int(lowRate / 420)          // highest pitch ~420 Hz
        tauMax = Int(lowRate / 38)           // lowest pitch ~38 Hz
        window = Int(lowRate * 0.045)        // 45 ms integration
        ring = [Float](repeating: 0, count: window + tauMax + 1)
        yin = [Float](repeating: 0, count: tauMax + 1)
        hop = Int(sampleRate * 0.01)
        block = hop / 4
    }

    public func setCrossover(_ hz: Double) {
        let f = max(30, min(250, hz))   // the felt sub band tops out at 250 Hz whatever the band is
        guard f != crossover else { return }
        crossover = f
        let (z1a, z2a, z1b, z2b) = (sub1.z1, sub1.z2, sub2.z1, sub2.z2)
        sub1 = Biquad(lowpass: f, sr: sampleRate); sub2 = sub1
        sub1.z1 = z1a; sub1.z2 = z2a; sub2.z1 = z1b; sub2.z2 = z2b
    }

    /// Feed mono samples. `time` is the host time (s) of the first sample. Calls `emit` per 10 ms hop.
    public func process(_ samples: UnsafeBufferPointer<Float>, time: Double, emit: (BassFrame) -> Void) {
        for (i, x) in samples.enumerated() {
            let s = sub2.run(sub1.run(x))
            let b = bass2.run(bass1.run(x))
            subSq += s * s
            bassSq += b * b
            let k = kick2.run(kick1.run(x))
            blockSq += k * k
            blockCount += 1
            if blockCount >= block {
                blockCount = 0
                blockTime = time + Double(i) / sampleRate
                onset(sqrt(blockSq / Float(block)))
                blockSq = 0
            }
            let p = hp2.run(hp1.run(b))
            decimCount += 1
            if decimCount >= decim {
                decimCount = 0
                ring[ringPos] = p
                ringPos = (ringPos + 1) % ring.count
            }
            hopCount += 1
            if hopCount >= hop {
                hopCount = 0
                emit(step(time: time + Double(i) / sampleRate))
            }
        }
    }

    private func step(time: Double) -> BassFrame {
        // Levels over the last 40 ms: a 10 ms window is shorter than a low bass period and ripples.
        subHist[histPos] = subSq; bassHist[histPos] = bassSq
        histPos = (histPos + 1) % subHist.count
        let n = Float(hop * subHist.count)
        let subRMS = sqrt(subHist.reduce(0, +) / n), bassRMS = sqrt(bassHist.reduce(0, +) / n)
        subSq = 0; bassSq = 0
        frameIndex += 1

        // Auto-gain: peaks fall back over ~4 s so quiet tracks still drive the motor.
        subPeak = max(subRMS, subPeak * 0.9975, 1e-4)
        bassPeak = max(bassRMS, bassPeak * 0.9975, 1e-4)
        var f = BassFrame()
        f.time = time
        let gate: Float = 0.0015                     // about -56 dBFS: silence stays silent
        f.sub = subRMS > gate ? min(1, subRMS / subPeak) : 0
        f.bass = bassRMS > gate ? min(1, bassRMS / bassPeak) : 0

        if pendingKick > 0 { f.kick = pendingKick; f.kickTime = pendingKickTime; pendingKick = 0 }

        // Pitch every 2nd hop (20 ms), held between.
        if frameIndex % 2 == 0 {
            let p = bassRMS > gate ? detectPitch() : 0
            pitchHist.removeFirst(); pitchHist.append(p)
        }
        let sorted = pitchHist.sorted()
        f.pitch = sorted[1]
        return f
    }

    /// Kick onset: a 2.5 ms block of sub energy jumps well above the recent (~60 ms) level.
    private func onset(_ e: Float) {
        sinceKick += 1
        kickPeak = max(e, kickPeak * 0.9994, 1e-4)
        if sinceKick > 48, e > 0.003, e > onsetSlow * 2.6, e > kickPeak * 0.5 {
            pendingKick = min(1, e / kickPeak)
            pendingKickTime = blockTime
            sinceKick = 0
        }
        onsetSlow += (e - onsetSlow) * 0.04
    }

    /// YIN cumulative-mean-normalised difference over the decimated bass ring.
    private func detectPitch() -> Float {
        let n = ring.count
        let start = ringPos            // oldest sample
        @inline(__always) func at(_ k: Int) -> Float { ring[(start + k) % n] }
        var running: Float = 0
        yin[0] = 1
        for tau in 1...tauMax {
            var d: Float = 0
            for j in 0..<window {
                let diff = at(j) - at(j + tau)
                d += diff * diff
            }
            running += d
            yin[tau] = running > 0 ? d * Float(tau) / running : 1
        }
        func refine(_ t: Int) -> Float {
            let a = yin[t - 1], b = yin[t], c = yin[t + 1]
            let den = a - 2 * b + c
            let shift = den != 0 ? 0.5 * (a - c) / den : 0
            return Float(lowRate) / (Float(t) + shift)
        }
        var tau = tauMin
        var best = tauMin
        while tau < tauMax {
            if yin[tau] < 0.25 {
                while tau + 1 < tauMax, yin[tau + 1] < yin[tau] { tau += 1 }
                return refine(tau)
            }
            if yin[tau] < yin[best] { best = tau }
            tau += 1
        }
        return yin[best] < 0.45 ? refine(best) : 0
    }
}
