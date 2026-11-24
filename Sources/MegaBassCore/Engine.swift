import Combine
import Foundation

/// Wires capture (system tap or demo) → analyzer → haptic voice, and exposes state for the UI.
@MainActor
public final class Engine: ObservableObject {
    public enum Source: Equatable { case none, system, demo }

    @Published public private(set) var enabled = false
    @Published public var mode: BassMode { didSet { voice?.mode = mode; defaults.set(mode.rawValue, forKey: "mode") } }
    @Published public var intensity: Double { didSet { voice?.intensity = Float(intensity); defaults.set(intensity, forKey: "intensity") } }
    /// Sub band cutoff, Hz: how much of the low end drives the rumble.
    @Published public var crossover: Double { didSet { pipeline.crossover = crossover; defaults.set(crossover, forKey: "crossover") } }
    /// Lowest motor frequency, Hz: the rumble plays the bass note in the octave above this.
    @Published public var rumbleHz: Double { didSet { voice?.rumbleHz = rumbleHz; pipeline.low = rumbleHz; defaults.set(rumbleHz, forKey: "rumbleHz") } }
    @Published public private(set) var source: Source = .none
    @Published public private(set) var problem: String?
    @Published public private(set) var needsPermission = false
    @Published public private(set) var outputName = ""

    // Live meters, refreshed ~30 times a second while on.
    @Published public private(set) var level: Double = 0
    @Published public private(set) var bassLevel: Double = 0
    @Published public private(set) var note = ""
    @Published public private(set) var kickPulse: Double = 0
    @Published public private(set) var history: [Double] = Array(repeating: 0, count: 32)

    private let defaults = UserDefaults.standard
    private var motor: Motor?
    private var voice: HapticVoice?
    private let tap = SystemTap()
    private let demo = DemoGroove()
    private let pipeline = Pipeline()
    private var meterTimer: Timer?
    private var frameTick = 0
    private var askedPermission = false

    public init() {
        mode = BassMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .bass
        intensity = defaults.object(forKey: "intensity") as? Double ?? 0.8
        crossover = defaults.object(forKey: "crossover") as? Double ?? 100
        rumbleHz = defaults.object(forKey: "rumbleHz") as? Double ?? 45
        pipeline.crossover = crossover
        pipeline.low = rumbleHz
        AudioDevices.observeDefaultOutput { [weak self] in
            Task { @MainActor in self?.outputChanged() }
        }
        if defaults.bool(forKey: "enabled") { setEnabled(true) }
    }

    public var demoPlaying: Bool { demo.playing }
    public var demoSilent: Bool {
        get { demo.silent }
        set { demo.silent = newValue }
    }

    public func toggle() { setEnabled(!enabled) }

    public func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: "enabled")
        if on {
            guard prepareMotor() else { return }
            enabled = true
            voice?.start()
            startMeters()
            if !demo.playing { startSystem() }
        } else {
            enabled = false
            demo.stop()
            tap.stop()
            voice?.stop()
            source = .none
            stopMeters()
        }
    }

    public func toggleDemo() {
        if demo.playing {
            demo.stop()
            // The demo switched us on just for itself: switch back off.
            if !defaults.bool(forKey: "enabled") { setEnabled(false) } else { startSystem() }
            objectWillChange.send()
            return
        }
        if !enabled {
            guard prepareMotor() else { return }
            enabled = true          // not saved: the demo alone doesn't turn megabass on for next launch
            voice?.start()
            startMeters()
        }
        tap.stop()
        do {
            let p = pipeline
            demo.onSamples = { samples, host, rate in p.feed(samples, host: host, offset: 0, sampleRate: rate) }
            try demo.start()
            source = .demo
            problem = nil
        } catch {
            problem = "Demo failed: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    public func requestPermission() {
        AudioCapturePermission.request { [weak self] ok in
            guard let self else { return }
            self.needsPermission = !ok
            if ok, self.enabled, !self.demo.playing { self.startSystem() }
        }
    }

    // MARK: - Internals

    private func prepareMotor() -> Bool {
        if motor != nil { return true }
        do {
            let m = try Motor()
            motor = m
            let v = HapticVoice(motor: m)
            v.mode = mode
            v.intensity = Float(intensity)
            v.rumbleHz = rumbleHz
            voice = v
            pipeline.voice = v
            problem = nil
            return true
        } catch {
            problem = "\(error)"
            return false
        }
    }

    private func startSystem() {
        tap.stop()
        outputName = AudioDevices.defaultOutputName()
        switch AudioCapturePermission.state {
        case .denied:
            needsPermission = true
            source = .none
            return
        case .unknown where !askedPermission:
            // Ask first: without System Audio Recording the tap silently returns zeros for other apps.
            askedPermission = true
            AudioCapturePermission.request { [weak self] ok in
                guard let self else { return }
                self.needsPermission = !ok
                if ok, self.enabled, !self.demo.playing { self.startSystem() }
            }
            return
        default: break
        }
        do {
            let latency = AudioDevices.outputLatency()
            let p = pipeline
            try tap.start { samples, host, rate in p.feed(samples, host: host, offset: latency, sampleRate: rate) }
            source = .system
            needsPermission = false
            problem = nil
        } catch {
            source = .none
            problem = "Can't listen to system audio: \(error)"
        }
    }

    private func outputChanged() {
        guard enabled, source == .system else { outputName = AudioDevices.defaultOutputName(); return }
        startSystem()
    }

    private func startMeters() {
        stopMeters()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMeters() }
        }
    }

    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0; bassLevel = 0; note = ""; kickPulse = 0
        history = Array(repeating: 0, count: history.count)
    }

    private func tickMeters() {
        guard let voice else { return }
        let s = voice.status
        let f = pipeline.lastFrame
        level = Double(s.level)
        bassLevel = bassLevel * 0.6 + Double(max(f.sub, f.bass)) * 0.4
        note = s.noteName
        let sinceKick = Clock.now() - s.kickAt
        kickPulse = sinceKick < 0.25 ? 1 - sinceKick / 0.25 : 0
        frameTick += 1
        if frameTick % 2 == 0 {
            history.removeFirst()
            history.append(max(bassLevel, kickPulse * 0.9))
        }
    }
}

/// The audio-thread side: analysis and hand-off to the voice. Every call to `feed` comes from one
/// audio thread at a time (tap queue or demo render), so the analyzer needs no lock of its own.
final class Pipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var analyzer: BassAnalyzer?
    private var cycles: CycleTracker?
    private var tones: ToneTracker?
    private var _voice: HapticVoice?
    private var _last = BassFrame()

    var voice: HapticVoice? {
        get { lock.withLock { _voice } }
        set { lock.withLock { _voice = newValue } }
    }
    var lastFrame: BassFrame { lock.withLock { _last } }
    private var _crossover: Double = 100
    private var _low: Double = 30
    var crossover: Double {
        get { lock.withLock { _crossover } }
        set { lock.withLock { _crossover = newValue } }
    }
    var low: Double {
        get { lock.withLock { _low } }
        set { lock.withLock { _low = newValue } }
    }

    static let split = 160.0

    /// `offset`: seconds from this host time until the audio leaves the speakers.
    func feed(_ samples: UnsafeBufferPointer<Float>, host: Double, offset: Double, sampleRate: Double = 48000) {
        if analyzer == nil || analyzer!.sampleRate != sampleRate { analyzer = BassAnalyzer(sampleRate: sampleRate) }
        analyzer!.setCrossover(crossover)
        if cycles == nil || cycles!.sampleRate != sampleRate { cycles = CycleTracker(sampleRate: sampleRate) }
        // Bass (cycle by cycle) up to 160 Hz; prominent tones from there up to the High handle.
        cycles!.setBand(low: low, high: min(crossover, Self.split))
        let v = voice
        if let v { cycles!.process(samples, time: host + offset) { v.push($0) } }
        if crossover > Self.split * 1.2 {
            if tones == nil || tones!.sampleRate != sampleRate { tones = ToneTracker(sampleRate: sampleRate) }
            tones!.setBand(low: max(low, Self.split), high: crossover)
            tones!.bassHz = Double(lastFrame.pitch)
            if let v { tones!.process(samples, time: host + offset) { v.push($0) } }
        }
        var last: BassFrame?
        analyzer!.process(samples, time: host + offset) { f in
            v?.push(f)
            last = f
        }
        if let last { lock.withLock { _last = last } }
    }
}
