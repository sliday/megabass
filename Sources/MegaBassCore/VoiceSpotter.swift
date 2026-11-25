import Foundation

/// Prominent voices for the visuals: a band in the voice range (150 Hz to 2 kHz) that stands out of
/// the spectrum around it, rises above its own recent level, and holds for ~100 ms. That reads as a
/// sung or lead note rather than a drum hit. Each event carries its pitch (0 low ... 1 high) and
/// strength (0...1).
public final class VoiceSpotter {
    public struct Event: Sendable {
        public var time: Double
        public var pitch: Double
        public var strength: Double
        public init(time: Double, pitch: Double, strength: Double) { self.time = time; self.pitch = pitch; self.strength = strength }
    }

    private var avg: [Double] = []
    private var hold: [Int] = []
    private var lastAt: [Double] = []
    private var lastAny = -10.0
    private var frames = 0

    public init() {}

    private static func band(_ hz: Double, count: Int) -> Int {
        let r = SpectrumAnalyzer.range
        return Int((log(hz / r.lowerBound) / log(r.upperBound / r.lowerBound) * Double(count)).rounded())
    }

    /// One spectrum frame (from `SpectrumAnalyzer`, ~30 a second); returns a voice when one starts.
    public func process(_ bands: [Float], time: Double) -> Event? {
        let n = bands.count
        if avg.count != n {
            avg = Array(repeating: 0, count: n); hold = Array(repeating: 0, count: n)
            lastAt = Array(repeating: -10, count: n)
        }
        let lo = max(3, Self.band(150, count: n)), hi = min(n - 4, Self.band(2000, count: n))
        let crowded = Self.band(400, count: n)            // below this, bass harmonics crowd the voice
        var best: (i: Int, score: Double)?
        for i in lo...hi {
            let v = Double(bands[i])
            let around = Double(bands[i - 3] + bands[i - 2] + bands[i + 2] + bands[i + 3]) / 4
            let peak = v >= Double(bands[i - 1]) && v >= Double(bands[i + 1])
            let stand = v - around, rise = v - avg[i]
            let need = i < crowded ? 0.2 : 0.12
            if peak && v > 0.4 && stand > need && rise > 0.1 { hold[i] += 1 } else { hold[i] = 0 }
            // Fire once per note: on the third frame it holds, away from the last voice and this pitch.
            if hold[i] == 3, frames > 30, time - lastAny > 0.35, time - lastAt[i] > 1.0 {    // 1 s warm-up for the averages
                let score = stand + rise
                if best == nil || score > best!.score { best = (i, score) }
            }
        }
        for i in 0..<n { avg[i] += (Double(bands[i]) - avg[i]) * 0.03 }      // ~1 s memory at 30 frames/s
        frames += 1
        guard let b = best else { return nil }
        lastAny = time
        for j in max(0, b.i - 1)...min(n - 1, b.i + 1) { lastAt[j] = time }
        // The winner is often a harmonic: if a standing peak sits an octave (or an octave and a
        // fifth) below, that is the note.
        var root = b.i
        let perOctave = Double(n) / log2(SpectrumAnalyzer.range.upperBound / SpectrumAnalyzer.range.lowerBound)
        for ratio in [2.0, 3.0] {
            let j = Int((Double(b.i) - log2(ratio) * perOctave).rounded())
            guard j >= max(lo, 3), j + 3 < n else { continue }
            let v = Double(bands[j])
            let around = Double(bands[j - 3] + bands[j - 2] + bands[j + 2] + bands[j + 3]) / 4
            if v >= Double(bands[j - 1]), v >= Double(bands[j + 1]), v > 0.35, v - around > 0.06 { root = j; break }
        }
        return Event(time: time, pitch: Double(root - lo) / Double(max(1, hi - lo)), strength: min(1, b.score / 0.6))
    }
}
