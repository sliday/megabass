import Accelerate
import Foundation

/// Log-spaced band levels (0...1) of whatever the Mac plays, for the popover's visualizer.
/// 2048-point FFT every ~33 ms; bands from 30 Hz to 8 kHz; auto-gained over a 60 dB window.
public final class SpectrumAnalyzer {
    public let sampleRate: Double
    public let bandCount: Int
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
    private let edges: [Int]
    private var peakDB: Float = -60

    public init(sampleRate: Double, bands: Int = 28) {
        self.sampleRate = sampleRate
        bandCount = bands
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        ring = [Float](repeating: 0, count: n)
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        frame = [Float](repeating: 0, count: n)
        re = [Float](repeating: 0, count: n / 2)
        im = [Float](repeating: 0, count: n / 2)
        mag = [Float](repeating: 0, count: n / 2)
        hop = Int(sampleRate / 30)
        let size = 2048
        let binHz = sampleRate / Double(size)
        edges = (0...bands).map { i in
            let hz = 30 * pow(8000 / 30, Double(i) / Double(bands))
            return max(1, min(size / 2 - 1, Int((hz / binHz).rounded())))
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    public func process(_ samples: UnsafeBufferPointer<Float>, emit: ([Float]) -> Void) {
        for x in samples {
            ring[ringPos] = x
            ringPos = (ringPos + 1) % n
            hopCount += 1
            if hopCount >= hop {
                hopCount = 0
                emit(analyse())
            }
        }
    }

    private func analyse() -> [Float] {
        let tail = n - ringPos
        for k in 0..<tail { frame[k] = ring[ringPos + k] }
        for k in 0..<ringPos { frame[tail + k] = ring[k] }
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
        var out = [Float](repeating: 0, count: bandCount)
        var top: Float = -120
        for b in 0..<bandCount {
            let lo = edges[b], hi = max(edges[b] + 1, edges[b + 1])
            var m: Float = 0
            for k in lo..<hi { m = max(m, mag[k]) }
            let db = 20 * log10(m / Float(n) + 1e-9)
            out[b] = db
            top = max(top, db)
        }
        peakDB = max(top, peakDB - 0.15)            // falls ~4.5 dB a second
        return out.map { max(0, min(1, ($0 - (peakDB - 60)) / 60)) }
    }
}
