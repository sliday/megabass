import Accelerate
import Foundation

/// A prominent, sustained frequency above the bass (a sung note, a lead line, a held chord tone).
public struct ProminentTone: Sendable {
    public var time: Double
    /// 0 when nothing in the band is prominent and steady enough to play.
    public var hz: Double
    public var amp: Float
}

/// Every 10 ms, finds the strongest spectral peak in a band (up to the motor's ~4 kHz limit) and
/// reports it only when it is prominent (well above the rest of the band) and has held its pitch long
/// enough for the motor to render it. Noise, hats and dense mixes report nothing.
public final class ToneTracker {
    public let sampleRate: Double
    public private(set) var lowHz: Double = 160
    public private(set) var highHz: Double = 2000
    /// Peak must be this many times the band's mean magnitude.
    public var prominence: Float = 6
    /// And hold its pitch (±60 cents) at least this long.
    public var minDuration = 0.04
    /// Current bass fundamental (Hz, 0 = none). Its overtones are skipped: the bass layer plays them.
    public var bassHz: Double = 0 {
        didSet { if bassHz > 0 { recentBass.append((clock, bassHz)) } }
    }
    private var recentBass: [(t: Double, hz: Double)] = []
    private var clock: Double = 0

    private let n = 2048
    private let log2n: vDSP_Length = 11
    private let setup: FFTSetup
    private var ring: [Float]
    private var ringPos = 0
    private let hop: Int
    private var hopCount = 0
    private var window: [Float]
    private var frame: [Float]
    private var re: [Float], im: [Float], mag: [Float]
    private var lastHz: Double = 0
    private var steadySince: Double = 0
    private var peak: Float = 1e-6

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        ring = [Float](repeating: 0, count: n)
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        frame = [Float](repeating: 0, count: n)
        re = [Float](repeating: 0, count: n / 2)
        im = [Float](repeating: 0, count: n / 2)
        mag = [Float](repeating: 0, count: n / 2)
        hop = Int(sampleRate * 0.01)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    public func setBand(low: Double, high: Double) {
        lowHz = max(100, low)
        highHz = min(4000, max(lowHz * 1.2, high))
    }

    public func process(_ samples: UnsafeBufferPointer<Float>, time: Double, emit: (ProminentTone) -> Void) {
        for (i, x) in samples.enumerated() {
            ring[ringPos] = x
            ringPos = (ringPos + 1) % n
            hopCount += 1
            if hopCount >= hop {
                hopCount = 0
                emit(analyse(time: time + Double(i) / sampleRate))
            }
        }
    }

    private func analyse(time: Double) -> ProminentTone {
        // Oldest-first copy, windowed.
        let tail = n - ringPos
        frame.withUnsafeMutableBufferPointer { f in
            ring.withUnsafeBufferPointer { r in
                for k in 0..<tail { f[k] = r[ringPos + k] }
                for k in 0..<ringPos { f[tail + k] = r[k] }
            }
        }
        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n))
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(n / 2))
            }
        }
        let binHz = sampleRate / Double(n)
        let lo = max(1, Int(lowHz / binHz)), hi = min(n / 2 - 2, Int(highHz / binHz))
        guard hi > lo + 4 else { return ProminentTone(time: time, hz: 0, amp: 0) }
        var best = -1
        var sum: Float = 0
        // The bass pitch lags note changes and drops out around kicks: suppress the overtones of every
        // bass pitch seen in the last 150 ms (300 ms if nothing newer).
        clock = time
        recentBass.removeAll { time - $0.t > 0.3 }
        var bases: [Double] = []
        for b in recentBass.reversed() where (time - b.t < 0.15 || bases.isEmpty) && !bases.contains(where: { abs($0 / b.hz - 1) < 0.02 }) {
            bases.append(b.hz)
        }
        for k in lo...hi {
            sum += mag[k]
            // Only true spectral peaks: the skirt between two bass overtones is not a tone.
            guard mag[k] > mag[k - 1], mag[k] >= mag[k + 1] else { continue }
            var overtone = false
            for f0 in bases where f0 > 20 {
                let h = Double(k) * binHz / f0, hr = h.rounded()
                // On a bass overtone? Then it's the bass, unless it towers over the neighbouring
                // overtones (a melody note that happens to be consonant with the bass).
                if hr >= 1, abs(h - hr) * f0 < max(binHz * 0.75, Double(k) * binHz * 0.023) {
                    func at(_ m: Double) -> Float {
                        let b = Int((m * f0 / binHz).rounded())
                        return b > 0 && b < n / 2 ? mag[b] : 0
                    }
                    if mag[k] < 2 * max(at(hr - 1), at(hr + 1)) { overtone = true; break }
                }
            }
            if overtone { continue }
            // Gentle tilt toward higher bins: low overtones are loud but rarely the line you'd follow.
            if best < 0 || mag[k] * sqrt(Float(k)) > mag[best] * sqrt(Float(best)) { best = k }
        }
        guard best > lo, best < hi else { return ProminentTone(time: time, hz: 0, amp: 0) }
        let mean = sum / Float(hi - lo + 1)
        let p = mag[best]
        peak = max(p, peak * 0.995)               // auto-gain over ~2 s of hops
        // Parabolic interpolation for the true frequency.
        let a = mag[best - 1], b = mag[best], c = mag[best + 1]
        let den = a - 2 * b + c
        let shift = den != 0 ? Double(0.5 * (a - c) / den) : 0
        let hz = (Double(best) + shift) * binHz

        let cents = lastHz > 0 ? abs(1200 * log2(hz / lastHz)) : 1e9
        if cents > 60 { steadySince = time }
        lastHz = hz
        let prominent = p > mean * prominence && p > 0.02 * Float(n) * 0.01
        guard prominent, time - steadySince >= minDuration else { return ProminentTone(time: time, hz: 0, amp: 0) }
        return ProminentTone(time: time, hz: hz, amp: min(1, p / peak))
    }
}
