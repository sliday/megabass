import Foundation
import MegaBassCore

// Headless checks for megabass. Prints one line per measurement and exits non-zero on a failed bar.
//   mbcheck pitch              analyzer vs the demo's known bass line (offline, no hardware)
//   mbcheck sing <mode> [secs] [duty]demo analysed in real time, played ONLY on the trackpad (speakers silent)
//   mbcheck tap [secs]         system-audio capture levels per second
//   mbcheck latency            reported output latency of the default device

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "pitch"

func midi(_ hz: Float) -> Int { Int((69 + 12 * log2(Double(hz) / 440)).rounded()) }

switch cmd {
case "pitch":
    let sr = 48000.0, secs = 20.0
    let audio = DemoGroove.render(seconds: secs, sampleRate: sr)
    let an = BassAnalyzer(sampleRate: sr)
    var total = 0, exact = 0, octave = 0, silent = 0, kicks = 0
    var kickTimes: [Double] = []
    audio.withUnsafeBufferPointer { buf in
        an.process(buf, time: 0) { f in
            if f.kick > 0 { kicks += 1; kickTimes.append(f.time) }
            let eighth = f.time * DemoGroove.bpm / 60 * 2
            let into = eighth - floor(eighth)
            guard f.time > 1, into > 0.35, into < 0.8 else { return }   // settled middle of each note
            let want = DemoGroove.notes[Int(eighth) % DemoGroove.notes.count]
            total += 1
            if f.pitch <= 0 { silent += 1; return }
            let got = midi(f.pitch)
            if got == want { exact += 1 } else if (got - want) % 12 == 0 { octave += 1 }
        }
    }
    let bars = secs * DemoGroove.bpm / 60 / 4
    // Ground-truth kicks: beats 1, 3 and the "and" of 4 in every bar.
    var truth: [Double] = []
    for bar in 0..<Int(bars) { for h in [0.0, 2.0, 3.5] { truth.append((Double(bar) * 4 + h) * 60 / DemoGroove.bpm) } }
    var hitErr: [Double] = []
    for k in truth {
        if let d = kickTimes.map({ abs($0 - k) }).min(), d < 0.06 { hitErr.append(d) }
    }
    let extras = kickTimes.filter { t in truth.allSatisfy { abs($0 - t) >= 0.06 } }.count
    let recall = Double(hitErr.count) / Double(truth.count)
    let medErr = hitErr.isEmpty ? 999 : hitErr.sorted()[hitErr.count / 2] * 1000
    let pcAcc = Double(exact + octave) / Double(max(total, 1))
    print(String(format: "pitch: exact %.1f%%  pitch-class %.1f%%  unvoiced %.1f%%  (%d frames)", Double(exact) / Double(max(total, 1)) * 100, pcAcc * 100, Double(silent) / Double(max(total, 1)) * 100, total))
    print(String(format: "kicks: recall %.0f%% (%d/%d), median offset %.0f ms, extra sub hits %d (%.1f per bar)", recall * 100, hitErr.count, truth.count, medErr, extras, Double(extras) / bars))
    let pass = pcAcc >= 0.9 && recall >= 0.9 && medErr <= 30 && Double(extras) / bars <= 1
    print(pass ? "PASS" : "FAIL")
    exit(pass ? 0 : 1)

case "sing":
    let mode = BassMode(rawValue: args.count > 1 ? args[1] : "bass") ?? .bass
    let secs = args.count > 2 ? Double(args[2]) ?? 8 : 8
    let motor = try Motor()
    let voice = HapticVoice(motor: motor)
    voice.mode = mode
    voice.intensity = 1
    if args.count > 3, let d = Double(args[3]) { HapticVoice.bassDuty = d }
    if ProcessInfo.processInfo.environment["MB_NOKICK"] != nil { voice.kicksEnabled = false }
    voice.start()
    let sr = 48000.0
    let audio = DemoGroove.render(seconds: secs, sampleRate: sr)
    let an = BassAnalyzer(sampleRate: sr)
    let t0 = Clock.now() + 0.1
    let block = 480
    var i = 0
    // Feed in real time, as a capture would.
    let verbose = ProcessInfo.processInfo.environment["MB_LOG"] != nil
    var lastLog = 0.0
    var lastF = BassFrame()
    while i < audio.count {
        let start = t0 + Double(i) / sr
        Clock.wait(until: start)
        if verbose, start - lastLog >= 0.05 {
            lastLog = start
            let st = voice.status
            let el = start - t0
            let want = DemoGroove.notes[Int(el * DemoGroove.bpm / 60 * 2) % DemoGroove.notes.count]
            print(String(format: "%.2f want %@ playing %@ lvl %.2f aps %d | frame pitch %.1f bass %.2f sub %.2f", el, HapticVoice.name(440 * pow(2, Double(want - 69) / 12)), st.noteName, st.level, st.actuationsPerSecond, lastF.pitch, lastF.bass, lastF.sub))
        }
        let end = min(i + block, audio.count)
        audio[i..<end].withUnsafeBufferPointer { an.process($0, time: start) { voice.push($0); lastF = $0 } }
        i = end
    }
    Clock.wait(until: Clock.now() + 0.3)
    voice.stop()
    print("start \(String(format: "%.3f", t0)) mode \(mode.rawValue) actuations \(motor.actuations)")

case "tap":
    let secs = args.count > 1 ? Int(args[1]) ?? 5 : 5
    print("permission:", AudioCapturePermission.state, "output:", AudioDevices.defaultOutputName())
    let tap = SystemTap()
    let lock = NSLock()
    var sq: Double = 0, n = 0, peak: Float = 0
    try tap.start { buf, _, _ in
        lock.lock()
        for x in buf { sq += Double(x * x); peak = max(peak, abs(x)) }
        n += buf.count
        lock.unlock()
    }
    print("tap rate", tap.sampleRate)
    for s in 1...secs {
        Thread.sleep(forTimeInterval: 1)
        lock.lock()
        let rms = n > 0 ? sqrt(sq / Double(n)) : 0
        print(String(format: "%ds frames=%d rms=%.1f dBFS peak=%.3f", s, n, 20 * log10(rms + 1e-9), peak))
        sq = 0; n = 0; peak = 0
        lock.unlock()
    }
    tap.stop()

case "dump":
    let sr = 48000.0
    let audio = DemoGroove.render(seconds: 6, sampleRate: sr)
    let an = BassAnalyzer(sampleRate: sr)
    audio.withUnsafeBufferPointer { buf in
        an.process(buf, time: 0) { f in
            let eighth = f.time * DemoGroove.bpm / 60 * 2
            let want = DemoGroove.notes[Int(eighth) % DemoGroove.notes.count]
            let got = f.pitch > 0 ? midi(f.pitch) : -1
            print(String(format: "%.2f step %2d into %.2f want %d got %d (%.1f Hz) sub %.2f bass %.2f kick %.2f %@", f.time, Int(eighth) % 32, eighth - floor(eighth), want, got, f.pitch, f.sub, f.bass, f.kick, got == want ? "" : "  <<"))
        }
    }

case "pulse":
    // Fixed pulse train: carrier harmonics restarted every 1/f0, sounding `duty` of each period.
    let f0 = args.count > 1 ? Double(args[1]) ?? 55 : 55
    let duty = args.count > 2 ? Double(args[2]) ?? 0.5 : 0.5
    let secs = args.count > 3 ? Double(args[3]) ?? 2 : 2
    let motor = try Motor()
    let tones: [(hz: Double, amp: Double)] = [(max(1, (415 / f0).rounded()) * f0, 0.6), (max(1, (1320 / f0).rounded()) * f0, 0.4)]
    let t0 = Clock.now()
    var t = 0.0
    while t < secs {
        motor.play(tones, ms: duty * 1000 / f0, level: 1)
        t += 1 / f0
        Clock.wait(until: t0 + t)
    }
    print("pulses", motor.actuations)

case "e2e":
    // Full path: demo → speakers → system tap → analyzer → voice → motor. Measures each haptic kick
    // against the moment that kick leaves the speaker (render host time + device output latency).
    let secs = args.count > 1 ? Double(args[1]) ?? 8 : 8
    let motor = try Motor()
    let voice = HapticVoice(motor: motor)
    let e2eMode = BassMode(rawValue: args.count > 2 ? args[2] : "punch") ?? .punch
    voice.mode = e2eMode
    voice.intensity = 0.9
    voice.start()
    let outLat = AudioDevices.outputLatency()
    let an = BassAnalyzer(sampleRate: 48000)
    let ct = CycleTracker(sampleRate: 48000)
    ct.setBand(low: 30, high: 120)
    let tap = SystemTap()
    try tap.start { buf, host, _ in
        an.process(buf, time: host + outLat) { voice.push($0) }
        ct.process(buf, time: host + outLat) { voice.push($0) }
    }
    let demo = DemoGroove()
    let lock = NSLock()
    var firstHost = 0.0
    demo.onSamples = { _, host, _ in lock.withLock { if firstHost == 0 { firstHost = host } } }
    try demo.start()
    var hapticKicks: [Double] = []
    var last = 0.0
    let end = Clock.now() + secs
    while Clock.now() < end {
        let k = voice.status.kickAt
        if k != last { last = k; hapticKicks.append(k) }
        usleep(1000)
    }
    let late = voice.status.mirrorLate
    let aps = voice.status.actuationsPerSecond
    demo.stop(); tap.stop(); voice.stop()
    if e2eMode == .bass {
        print(String(format: "bass mirror: periods start %+.0f ms vs speakers (median), %d actuations/s", late * 1000, aps))
        print(abs(late) <= 0.04 ? "PASS" : "FAIL")
        exit(0)
    }
    let h0 = lock.withLock { firstHost }
    // Demo kicks: beats 1, 3 and the "and" of 4.
    var heard: [Double] = []
    for bar in 0..<Int(secs / 2.4) + 1 { for b in [0.0, 2.0, 3.5] { heard.append(h0 + (Double(bar) * 4 + b) * 0.6 + outLat) } }
    var lags: [Double] = []
    for k in hapticKicks { if let n = heard.min(by: { abs($0 - k) < abs($1 - k) }), abs(n - k) < 0.15 { lags.append(k - n) } }
    lags.sort()
    let med = lags.isEmpty ? .nan : lags[lags.count / 2] * 1000
    print(String(format: "output: %@ (reported latency %.1f ms)", AudioDevices.defaultOutputName(), outLat * 1000))
    print(String(format: "haptic kicks %d, matched %d, lag vs heard: median %+.0f ms, range %+.0f..%+.0f ms", hapticKicks.count, lags.count, med, (lags.first ?? 0) * 1000, (lags.last ?? 0) * 1000))
    print(abs(med) <= 60 ? "PASS" : "FAIL")

case "live":
    // Whatever the Mac is playing (Spotify, Music, YouTube) → trackpad, with a log twice a second.
    let mode = BassMode(rawValue: args.count > 1 ? args[1] : "punch") ?? .punch
    let secs = args.count > 2 ? Double(args[2]) ?? 20 : 20
    let motor = try Motor()
    let voice = HapticVoice(motor: motor)
    voice.mode = mode
    voice.intensity = 0.9
    voice.start()
    let outLat = AudioDevices.outputLatency()
    let an = BassAnalyzer(sampleRate: 48000)
    let lock = NSLock()
    var last = BassFrame(), kicks = 0, sq = 0.0, n = 0
    let tap = SystemTap()
    try tap.start { buf, host, _ in
        for x in buf { sq += Double(x * x) }
        n += buf.count
        an.process(buf, time: host + outLat) { f in voice.push(f); lock.withLock { last = f; if f.kick > 0 { kicks += 1 } } }
    }
    print("listening to \(AudioDevices.defaultOutputName()), mode \(mode.rawValue)")
    let t0 = Clock.now()
    while Clock.now() - t0 < secs {
        usleep(500_000)
        let st = voice.status
        let (f, k, rms) = lock.withLock { () -> (BassFrame, Int, Double) in
            let r = n > 0 ? sqrt(sq / Double(n)) : 0; sq = 0; n = 0; let kk = kicks; kicks = 0; return (last, kk, r)
        }
        print(String(format: "%4.1fs  input %5.1f dBFS  sub %.2f  bass %.2f  pitch %@  kicks %d  → trackpad %@ lvl %.2f, %d act/s",
                     Clock.now() - t0, 20 * log10(rms + 1e-9), f.sub, f.bass, f.pitch > 0 ? HapticVoice.name(Double(f.pitch)) : "--", k, st.noteName.isEmpty ? "--" : st.noteName, st.level, st.actuationsPerSecond))
    }
    tap.stop(); voice.stop()

case "cycles":
    // 1) Pure sines: each period's frequency must match within 1 %.
    let sr = 48000.0
    var worst = 0.0
    for hz in [30.0, 45, 60, 90, 120, 200] {
        let tr = CycleTracker(sampleRate: sr)
        tr.setBand(low: 20, high: 250)
        let x = (0..<Int(sr)).map { Float(0.5 * sin(2 * Double.pi * hz * Double($0) / sr)) }
        var got: [Double] = []
        x.withUnsafeBufferPointer { tr.process($0, time: 0) { c in if c.start > 0.2 { got.append(1 / c.period) } } }
        let err = got.map { abs($0 - hz) / hz }.max() ?? 1
        worst = max(worst, err)
        print(String(format: "sine %5.0f Hz → %d periods, worst error %.2f %%", hz, got.count, err * 100))
    }
    // 2) Demo bass stem (no drums: with drums the low band is bass + kick, and replaying the kick's
    //    periods is correct): periods should sit on the bass note (±50 cents), weighted by loudness.
    let audio = DemoGroove.render(seconds: 20, sampleRate: sr, drums: false)
    let tr = CycleTracker(sampleRate: sr)
    tr.setBand(low: 30, high: 120)
    var onNote = 0.0, total = 0.0, covered = 0.0
    audio.withUnsafeBufferPointer { buf in
        tr.process(buf, time: 0) { c in
            guard c.start > 1 else { return }
            let eighth = c.start * DemoGroove.bpm / 60 * 2
            let into = eighth - floor(eighth)
            guard into > 0.15, into < 0.8 else { return }
            let want = 440 * pow(2, Double(DemoGroove.notes[Int(eighth) % DemoGroove.notes.count] - 69) / 12)
            let cents = abs(1200 * log2((1 / c.period) / want))
            let w = Double(c.amp)
            total += w
            covered += c.period
            if cents < 50 { onNote += w }
        }
    }
    let match = onNote / max(total, 1e-9)
    print(String(format: "demo bass stem: %.1f %% of bass energy replayed on the right note (±50 cents)", match * 100))
    // 3) Full mix: the replay must be continuous while the bass plays (no dropouts).
    let mix = DemoGroove.render(seconds: 20, sampleRate: sr)
    let tm = CycleTracker(sampleRate: sr)
    tm.setBand(low: 30, high: 120)
    var mixCovered = 0.0
    mix.withUnsafeBufferPointer { tm.process($0, time: 0) { c in if c.start > 1 { mixCovered += c.period } } }
    let coverage = mixCovered / 19 / 0.85        // the bass sounds 85 % of each note
    print(String(format: "demo full mix: periods cover %.0f %% of the time the bass sounds", min(1, coverage) * 100))
    let pass = worst < 0.01 && match >= 0.85 && coverage >= 0.85
    print(pass ? "PASS" : "FAIL")
    exit(pass ? 0 : 1)

case "tones":
    // Prominent-tone tracker: must follow a melody over the groove and ignore noise.
    let sr = 48000.0, secs = 12.0
    let melody: [Double] = [659.3, 784.0, 880.0, 784.0, 659.3, 587.3, 523.3, 587.3]   // E5 G5 A5 G5 E5 D5 C5 D5
    let noteLen = 0.3
    let groove = DemoGroove.render(seconds: secs, sampleRate: sr)
    var phase = 0.0
    let withMelody: [Float] = groove.enumerated().map { i, g in
        let t = Double(i) / sr
        let f = melody[Int(t / noteLen) % melody.count]
        phase += f / sr
        let into = t.truncatingRemainder(dividingBy: noteLen)
        let env = into < 0.01 ? into / 0.01 : (into > noteLen - 0.03 ? max(0, (noteLen - into) / 0.03) : 1)
        return g + Float(0.12 * env * sin(2 * .pi * phase))
    }
    var wrong: [String: Int] = [:]
    func run(_ x: [Float]) -> (onPitch: Double, active: Double) {
        let tr = ToneTracker(sampleRate: sr)
        tr.setBand(low: 160, high: 4000)
        let an = BassAnalyzer(sampleRate: sr)
        var hits = 0, active = 0, total = 0
        // As in the app: the analyzer's bass pitch from the previous block tells the tracker what to skip.
        var pos = 0
        while pos < x.count {
            let end = min(pos + 256, x.count)
            x[pos..<end].withUnsafeBufferPointer { b in
                an.process(b, time: Double(pos) / sr) { f in tr.bassHz = Double(f.pitch) }
                tr.process(b, time: Double(pos) / sr) { t in
            guard t.time > 1 else { return }
            let into = t.time.truncatingRemainder(dividingBy: noteLen)
            guard into > 0.09, into < noteLen - 0.02 else { return }   // allow window fill + 40 ms hold
            total += 1
            if t.hz == 0 { wrong["silent " + HapticVoice.name(melody[Int(t.time / noteLen) % melody.count]) + "@" + (tr.bassHz > 0 ? HapticVoice.name(tr.bassHz) : "0"), default: 0] += 1 }
            if t.hz > 0 {
                active += 1
                let want = melody[Int(t.time / noteLen) % melody.count]
                if abs(1200 * log2(t.hz / want)) < 50 { hits += 1 } else { wrong[HapticVoice.name(want) + "→" + HapticVoice.name(t.hz) + "@" + (tr.bassHz > 0 ? HapticVoice.name(tr.bassHz) : "0"), default: 0] += 1 }
            }
                }
            }
            pos = end
        }
        return (Double(hits) / Double(max(total, 1)), Double(active) / Double(max(total, 1)))
    }
    let m = run(withMelody)
    let melodyMisses = wrong
    let g = run(groove)
    var seed: UInt32 = 99
    let noise: [Float] = (0..<Int(sr * secs)).map { _ in seed = seed &* 1664525 &+ 1013904223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.1 }
    let nz = run(noise)
    print(String(format: "melody over groove: on pitch %.0f %% of note time, active %.0f %%", m.onPitch * 100, m.active * 100))
    print("misses:", melodyMisses.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    print(String(format: "groove alone (bass harmonics, hats): tone active %.0f %% of the time", g.active * 100))
    print(String(format: "white noise: tone active %.0f %% of the time", nz.active * 100))
    let pass = m.onPitch >= 0.8 && nz.active <= 0.05
    print(pass ? "PASS" : "FAIL")
    exit(pass ? 0 : 1)

case "latency":
    print(AudioDevices.defaultOutputName(), String(format: "%.1f ms", AudioDevices.outputLatency() * 1000))

default:
    print("usage: mbcheck pitch | sing <punch|bass|harmony> [secs] | tap [secs] | latency")
}
