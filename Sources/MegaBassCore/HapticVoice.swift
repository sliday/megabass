import Foundation

public enum BassMode: String, CaseIterable, Sendable {
    /// Felt and heard: the music's own bass waveform, replayed on the motor period by period.
    case bass
    /// Felt: kicks as thumps plus a rumble that follows the sub.
    case punch
    /// Heard: the trackpad sings a fifth over the bass line.
    case harmony

    public var title: String {
        switch self { case .punch: "Punch"; case .bass: "Bass"; case .harmony: "Harmony" }
    }
}

/// What the voice is doing right now, for the UI.
public struct VoiceStatus: Sendable {
    public var level: Float = 0
    public var noteName: String = ""
    public var kickAt: Double = 0
    public var actuationsPerSecond = 0
    /// Bass mode: median of how late recent periods started vs when the speakers play them (s).
    public var mirrorLate: Double = 0
}

/// Reads analysis frames (delayed to line up with the speakers) and plays them on the motor
/// from its own high-priority thread.
public final class HapticVoice {
    private let motor: Motor
    private let lock = NSLock()
    private var queue: [BassFrame] = []
    private var pendingKicks: [(t: Double, amp: Float)] = []
    private var cycles: [BassCycle] = []
    private var toneQueue: [ProminentTone] = []
    private var tone = ProminentTone(time: 0, hz: 0, amp: 0)
    private var _mode: BassMode = .bass
    private var _intensity: Float = 0.8
    private var _delay: Double = 0
    private var _rumbleHz: Double = 45
    private var _kicks = true
    private var _status = VoiceStatus()
    private var running = false
    private var thread: Thread?

    public init(motor: Motor) { self.motor = motor }

    public var mode: BassMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
    public var intensity: Float {
        get { lock.withLock { _intensity } }
        set { lock.withLock { _intensity = max(0, min(1, newValue)) } }
    }
    /// Seconds to hold frames back so the haptics land with the speaker output.
    public var delay: Double {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = max(0, min(0.5, newValue)) } }
    }
    /// Lowest frequency the motor shakes at (Hz). Punch rumble plays the bass note folded into the
    /// octave above this; kicks dive down to it.
    public var rumbleHz: Double {
        get { lock.withLock { _rumbleHz } }
        set { lock.withLock { _rumbleHz = max(20, min(160, newValue)) } }
    }
    public var kicksEnabled: Bool {
        get { lock.withLock { _kicks } }
        set { lock.withLock { _kicks = newValue } }
    }
    public var status: VoiceStatus { lock.withLock { _status } }

    /// Called from the audio thread with each low-band period (Bass mode plays these).
    public func push(_ c: BassCycle) {
        lock.lock()
        cycles.append(c)
        if cycles.count > 400 { cycles.removeFirst(cycles.count - 400) }
        lock.unlock()
    }

    /// Called from the audio thread every 10 ms with the prominent tone above the bass (or none).
    public func push(_ t: ProminentTone) {
        lock.lock()
        toneQueue.append(t)
        if toneQueue.count > 100 { toneQueue.removeFirst(toneQueue.count - 100) }
        lock.unlock()
    }

    /// Called from the audio thread. Kicks also go to their own list, due at their onset time.
    public func push(_ f: BassFrame) {
        lock.lock()
        if f.kick > 0 { pendingKicks.append((f.kickTime, f.kick)) }
        queue.append(f)
        if queue.count > 200 { queue.removeFirst(queue.count - 200) }
        lock.unlock()
    }

    public func start() {
        guard !running else { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.qualityOfService = .userInteractive
        t.name = "megabass.voice"
        thread = t
        t.start()
    }

    public func stop() {
        running = false
        lock.withLock { queue.removeAll(); cycles.removeAll(); toneQueue.removeAll(); pendingKicks.removeAll(); _status = VoiceStatus() }
    }

    // MARK: - Voice thread

    private var current = BassFrame()
    private var kicks: [(t: Double, amp: Double)] = []
    private var voiceNote: Double = 0        // sung harmony frequency, Hz (glides)
    private var heldPitch: Float = 0
    private var heldUntil: Double = 0
    private var noteStart: Double = 0
    private var lastRoot = 0
    private let key = KeyTracker()
    private var countWindowStart: Double = 0
    private var countInWindow = 0

    /// Where this motor is loud (measured with a mic on a MacBook Pro M4): bass-carrier harmonics go near these.
    static let carrierTargets: [(hz: Double, w: Double)] = [(415, 0.6), (1320, 0.4)]
    /// The band the harmony voice sings in.
    static let voiceBand = 330.0..<660.0
    /// Fraction of each bass period the motor sounds. The gap makes a pulse train at the bass pitch:
    /// without it the restarts blend into a steady tone and the low note disappears.
    public static var bassDuty = 0.5

    private var mirrorEnd: Double = 0      // when the last replayed period finishes
    private var lateHist: [Double] = []

    private func loop() {
        while running {
            if mode == .bass { mirror(); continue }
            let now = Clock.now()
            lock.lock()
            let due = now - _delay
            while let f = queue.first, f.time <= due {
                queue.removeFirst()
                current = f
                if f.pitch > 0 { key.add(Double(f.pitch), weight: Double(f.bass)) }
            }
            while let k = pendingKicks.first, k.t <= due {
                pendingKicks.removeFirst()
                if due - k.t < 0.1 { kicks.append((now, Double(k.amp))) }
            }
            let mode = _mode, intensity = Double(_intensity), rumbleHz = _rumbleHz, kicksOn = _kicks
            lock.unlock()
            if !kicksOn { kicks.removeAll() }

            // Stale input (paused music, lost tap): fall silent.
            if current.time < due - 0.25 { current = BassFrame() }
            kicks.removeAll { now - $0.t > 0.18 }

            var tones: [(hz: Double, amp: Double)] = []
            var step = 0.005
            var duty = 1.0
            var label = ""

            // Held pitch bridges short unvoiced gaps (a kick on top of a note).
            var pitch = Double(current.pitch)
            if pitch > 0 { heldPitch = current.pitch; heldUntil = now + 0.09 } else if now < heldUntil { pitch = Double(heldPitch) }
            let bassAmp = min(1, Double(current.bass) * 1.15) * intensity

            switch mode {
            case .punch:
                // Felt: the motor shakes at the bass note itself, folded into the octave above
                // `rumbleHz`, so the vibration follows the bass line. Unpitched sub: the base rumble.
                let amp = pow(Double(current.sub), 1.2) * intensity
                if amp > 0.04 {
                    let f = pitch > 0 ? Self.fold(Self.quantize(pitch), into: rumbleHz..<(rumbleHz * 2)) : rumbleHz
                    tones += [(f, amp), (f * 2, amp * 0.35)]
                    step = max(1, (0.03 * f).rounded()) / f
                    if pitch > 0 { label = Self.name(f) }
                }
            case .bass:
                break
            case .harmony:
                if pitch > 0, bassAmp > 0.05 {
                    let root = Self.midi(Self.quantize(pitch))
                    let interval = key.harmony(above: root)
                    let target = Self.fold(440 * pow(2, Double(root + interval - 69) / 12), into: Self.voiceBand)
                    if root != lastRoot { lastRoot = root; noteStart = now }
                    if voiceNote == 0 { voiceNote = target } else { voiceNote *= pow(target / voiceNote, 0.5) }
                    let age = now - noteStart
                    var f = voiceNote
                    if age > 0.18 { f *= pow(2, min(1, (age - 0.18) / 0.25) * 0.2 * sin(2 * .pi * 5.8 * age) / 12) }
                    let env = age < 0.015 ? 0.6 + 0.4 * age / 0.015 : 1
                    tones.append((f, bassAmp * env))
                    step = max(1, ((age < 0.06 ? 0.02 : 0.045) * f).rounded()) / f
                    label = Self.name(f)
                } else { voiceNote = 0 }
            }

            // Kicks: a pitch dive from a felt click down to the rumble floor. When a bass note is
            // sounding (Bass, Harmony) the kick rides inside each bass-period burst: shortening the
            // step would break the pulse train that carries the bass pitch.
            var kicked = false
            let carrying = mode != .punch && !tones.isEmpty
            for k in kicks {
                let age = now - k.t
                let f = rumbleHz + (700 - rumbleHz) * exp(-age / 0.016)
                tones.append((f, min(1, k.amp * intensity * 1.3 * exp(-age / 0.07))))
                if !carrying { step = min(step == 0.005 ? 1 / f : step, 2 / f) }
                kicked = true
            }

            let total = tones.reduce(0) { $0 + $1.amp }
            guard total > 0.02 else {
                if pitch == 0 { voiceNote = 0; lastRoot = 0 }
                lock.withLock { _status.level = 0; _status.noteName = "" }
                waitOrKick(until: now + 0.005)
                continue
            }
            tones.sort { $0.amp > $1.amp }
            let use = Array(tones.prefix(6))
            motor.play(use, ms: step * duty * 1000, level: Float(min(1, total)))
            publish(level: Float(min(1, total)), note: label, kick: kicked && kicks.contains { now - $0.t < 0.001 }, now: now)
            waitOrKick(until: now + step)
        }
    }

    /// Bass mode: replay the next low-band period at its own frequency, at the moment the speakers
    /// play it. Late periods play back to back so the waveform stays continuous; a backlog is dropped.
    private func mirror() {
        let now = Clock.now()
        lock.lock()
        let due = now - _delay
        // Drop anything more than 40 ms behind: better a skipped period than a growing lag.
        while let c = cycles.first, c.start + c.period < due - 0.04 { cycles.removeFirst() }
        while let t = toneQueue.first, t.time <= due { tone = t; toneQueue.removeFirst() }
        if tone.time < due - 0.1 { tone.hz = 0 }
        let next = cycles.first
        let intensity = _intensity, delay = _delay
        lock.unlock()

        let toneAmp = tone.hz > 0 ? Double(tone.amp) * Double(intensity) : 0
        guard let c = next, c.start + delay <= now + 0.03 || toneAmp == 0 else {
            // No bass due soon, but a prominent tone: play it in a short segment.
            if mirrorEnd <= now, toneAmp > 0.03 {
                let seg = max(1, (0.012 * tone.hz).rounded()) / tone.hz
                motor.play([(tone.hz, 1)], ms: seg * 1000, level: Float(min(1, toneAmp)))
                publish(level: Float(min(1, toneAmp)), note: Self.name(tone.hz), kick: false, now: now)
                mirrorEnd = now + seg
                Clock.wait(until: now + seg * 0.9)
            } else {
                Clock.wait(until: now + 0.002)
            }
            return
        }
        guard let c = next else {
            lock.withLock { _status.level = 0; _status.noteName = "" }
            Clock.wait(until: now + 0.002)
            return
        }
        let startAt = max(c.start + delay, mirrorEnd > now ? mirrorEnd : 0)
        if startAt > now + 0.0005 {
            Clock.wait(until: min(startAt, now + 0.002))
            return
        }
        lock.withLock { _ = cycles.removeFirst() }
        let f = 1 / c.period
        let bassLevel = pow(Double(c.amp), 0.8) * Double(intensity)
        var tones: [(hz: Double, amp: Double)] = [(f, bassLevel)]
        if toneAmp > 0.03 { tones.append((tone.hz, toneAmp)) }
        let level = Float(min(1, tones.reduce(0) { $0 + $1.amp }))
        if level > 0.02 {
            motor.play(tones, ms: c.period * 1000, level: level)
            publish(level: level, note: Self.name(f) + (toneAmp > 0.03 ? " · " + Self.name(tone.hz) : ""), kick: false, now: now)
        }
        mirrorEnd = now + c.period
        lateHist.append(now - (c.start + delay))
        if lateHist.count >= 50 {
            let med = lateHist.sorted()[lateHist.count / 2]
            lateHist.removeAll(keepingCapacity: true)
            lock.withLock { _status.mirrorLate = med }
        }
        Clock.wait(until: now + c.period * 0.9)
    }

    /// Sleeps until `t`, but wakes as soon as a kick falls due: a kick must not wait out a rumble segment.
    private func waitOrKick(until t: Double) {
        while running {
            let n = Clock.now()
            if n >= t { return }
            let kickDue = lock.withLock { pendingKicks.first.map { $0.t <= n - _delay } ?? false }
            if kickDue { return }
            Clock.wait(until: min(t, n + 0.001))
        }
    }

    private func publish(level: Float, note: String, kick: Bool, now: Double) {
        countInWindow += 1
        lock.lock()
        _status.level = level
        _status.noteName = note
        if kick { _status.kickAt = now }
        if now - countWindowStart >= 1 {
            _status.actuationsPerSecond = countInWindow
            countInWindow = 0
            countWindowStart = now
        }
        lock.unlock()
    }

    /// Nearest equal-tempered semitone (A4 = 440).
    static func quantize(_ hz: Double) -> Double {
        440 * pow(2, (12 * log2(hz / 440)).rounded() / 12)
    }
    /// Octave-shifts into `band` (one octave wide).
    static func fold(_ hz: Double, into band: Range<Double>) -> Double {
        var f = hz
        while f < band.lowerBound { f *= 2 }
        while f >= band.upperBound { f /= 2 }
        return f
    }
    static func midi(_ hz: Double) -> Int { Int((69 + 12 * log2(hz / 440)).rounded()) }
    public static func name(_ hz: Double) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let midi = Int((69 + 12 * log2(hz / 440)).rounded())
        return names[((midi % 12) + 12) % 12] + String(midi / 12 - 1)
    }
}

/// Tracks the song's key from the bass notes (Krumhansl-Schmuckler) to pick a diatonic third.
final class KeyTracker {
    private var hist = [Double](repeating: 0, count: 12)
    private static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    private var cached: (tonic: Int, minor: Bool, conf: Double)?
    private var adds = 0

    func add(_ hz: Double, weight: Double) {
        let pc = ((HapticVoice.midi(hz) % 12) + 12) % 12
        for i in 0..<12 { hist[i] *= 0.997 }        // ~2-3 s memory at 100 frames/s
        hist[pc] += weight
        adds += 1
        if adds % 10 == 0 { cached = nil }
    }

    var estimate: (tonic: Int, minor: Bool, conf: Double) {
        if let cached { return cached }
        var best = (tonic: 0, minor: false, conf: -1.0)
        let mean = hist.reduce(0, +) / 12
        for tonic in 0..<12 {
            for (isMinor, profile) in [(false, Self.major), (true, Self.minor)] {
                let pm = profile.reduce(0, +) / 12
                var num = 0.0, dx = 0.0, dy = 0.0
                for i in 0..<12 {
                    let x = hist[(tonic + i) % 12] - mean, y = profile[i] - pm
                    num += x * y; dx += x * x; dy += y * y
                }
                let r = dx > 0 ? num / sqrt(dx * dy) : 0
                if r > best.conf { best = (tonic, isMinor, r) }
            }
        }
        cached = best
        return best
    }

    /// Semitones above `root` for the harmony: a diatonic third when the key is clear, else a fifth.
    func harmony(above root: Int) -> Int {
        let k = estimate
        guard k.conf > 0.5 else { return 7 }
        let scale = k.minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        let degree = (((root - k.tonic) % 12) + 12) % 12
        guard let i = scale.firstIndex(of: degree) else { return 7 }
        let third = scale[(i + 2) % 7] + (i + 2 >= 7 ? 12 : 0)
        return third - degree
    }
}

/// Monotonic host-time clock in seconds.
public enum Clock {
    private static let ticksPerSecond: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return 1e9 * Double(tb.denom) / Double(tb.numer)
    }()
    public static func now() -> Double { Double(mach_absolute_time()) / ticksPerSecond }
    public static func seconds(hostTime: UInt64) -> Double { Double(hostTime) / ticksPerSecond }
    /// Sleeps, then spins only for the last ~1.5 ms.
    public static func wait(until t: Double) {
        while true {
            let n = now()
            if n >= t { return }
            if t - n > 0.0015 { usleep(useconds_t((t - n - 0.0015) * 1e6)) }
        }
    }
}
