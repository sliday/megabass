import AVFoundation
import Foundation

/// An original 100 BPM groove (kick, bass line, hats) so megabass can be felt without any music
/// or permissions. Also the reference signal for the pitch tests: `notes` is the ground truth.
public final class DemoGroove {
    public static let bpm = 100.0
    /// Eighth-note bass line, MIDI numbers. A minor, 4 bars.
    public static let notes: [Int] = [
        33, 33, 45, 33, 36, 33, 40, 43,   // A1 A1 A2 A1 C2 A1 E2 G2
        31, 31, 43, 31, 35, 31, 38, 40,   // G1 ...
        29, 29, 41, 29, 33, 29, 36, 40,   // F1 ...
        28, 28, 40, 28, 32, 35, 38, 40,   // E1 ... G♯1 B1 D2 E2
    ]

    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    public private(set) var playing = false
    /// Mutes the speakers (trackpad only). For screenshots and tests.
    public var silent = false
    public var onSamples: ((UnsafeBufferPointer<Float>, Double, Double) -> Void)?

    public init() {}

    /// Renders `seconds` of the groove offline (mono) for tests.
    public static func render(seconds: Double, sampleRate: Double, drums: Bool = true) -> [Float] {
        var synth = Synth(sampleRate: sampleRate)
        synth.drums = drums
        return (0..<Int(seconds * sampleRate)).map { _ in synth.next() }
    }

    public func start() throws {
        guard !playing else { return }
        let out = engine.outputNode.inputFormat(forBus: 0)
        let sr = out.sampleRate > 0 ? out.sampleRate : 48000
        var synth = Synth(sampleRate: sr)
        var scratch = [Float](repeating: 0, count: 4096)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let n = AVAudioSourceNode(format: fmt) { [weak self] _, ts, count, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            let frames = min(Int(count), scratch.count)
            for i in 0..<frames { scratch[i] = synth.next() }
            for buf in list {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<frames { p[i] = scratch[i] }
            }
            if let cb = self?.onSamples {
                let host = ts.pointee.mFlags.contains(.hostTimeValid) ? Clock.seconds(hostTime: ts.pointee.mHostTime) : Clock.now()
                scratch.withUnsafeBufferPointer { cb(UnsafeBufferPointer(rebasing: $0[0..<frames]), host, sr) }
            }
            return noErr
        }
        node = n
        engine.attach(n)
        engine.connect(n, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = silent ? 0 : 0.9
        try engine.start()
        playing = true
    }

    public func stop() {
        guard playing else { return }
        engine.stop()
        if let node { engine.detach(node) }
        node = nil
        playing = false
    }

    struct Synth {
        let sr: Double
        var t = 0
        var bassPhase = 0.0, kickPhase = 0.0
        var lp1: Biquad, lp2: Biquad
        var noise: UInt32 = 0x1234567
        var drums = true
        init(sampleRate: Double) {
            sr = sampleRate
            lp1 = Biquad(lowpass: 420, q: 0.9, sr: sampleRate)
            lp2 = Biquad(lowpass: 900, sr: sampleRate)
        }
        mutating func next() -> Float {
            let time = Double(t) / sr
            t += 1
            let beat = time * DemoGroove.bpm / 60
            let eighth = beat * 2
            let step = Int(eighth) % DemoGroove.notes.count
            let inStep = eighth - floor(eighth)

            // Bass: saw, low-passed, short release before each next note.
            let midi = Double(DemoGroove.notes[step])
            let f = 440 * pow(2, (midi - 69) / 12)
            bassPhase += f / sr
            if bassPhase >= 1 { bassPhase -= 1 }
            let saw = Float(2 * bassPhase - 1)
            let gate = Float(inStep < 0.85 ? 1 : max(0, 1 - (inStep - 0.85) / 0.15))
            let bass = lp1.run(saw) * 0.55 * gate

            // Kick on beats 1 and 3, plus the "and" of 4.
            let bar = beat.truncatingRemainder(dividingBy: 4)
            var kick: Float = 0
            for hit in [0.0, 2.0, 3.5] where drums && bar >= hit && bar < hit + 0.5 {
                let kt = (bar - hit) * 60 / DemoGroove.bpm
                let kf = 48 + 110 * exp(-kt / 0.03)
                kickPhase += kf / sr
                kick = Float(sin(2 * .pi * kickPhase) * exp(-kt / 0.18)) * 0.9
            }

            // Hats on the off eighths.
            noise = noise &* 1664525 &+ 1013904223
            let white = Float(Int32(bitPattern: noise)) / Float(Int32.max)
            let hatEnv = Float(inStep < 0.5 && step % 2 == 1 ? exp(-inStep * 40) : 0)
            let hat = (white - lp2.run(white)) * hatEnv * 0.12

            return max(-1, min(1, bass + kick + hat)) * 0.8
        }
    }
}
