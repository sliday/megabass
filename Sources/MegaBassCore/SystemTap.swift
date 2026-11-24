import AudioToolbox
import CoreAudio
import Foundation

/// Captures everything the Mac plays through a Core Audio process tap (macOS 14.4+).
/// No virtual driver: the tap is private to this process and leaves the sound unmuted.
public final class SystemTap {
    public enum Failure: Error, CustomStringConvertible {
        case status(String, OSStatus)
        public var description: String {
            switch self { case let .status(what, s): return "\(what) failed (\(s))" }
        }
    }

    public typealias Handler = (_ mono: UnsafeBufferPointer<Float>, _ hostTime: Double, _ sampleRate: Double) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "megabass.tap", qos: .userInteractive)
    private var mono = [Float](repeating: 0, count: 8192)
    public private(set) var sampleRate: Double = 48000
    public private(set) var running = false

    public init() {}

    public func start(_ handler: @escaping Handler) throws {
        guard !running else { return }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "megabass"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check("Create process tap", AudioHardwareCreateProcessTap(desc, &tapID))

        let outputUID = try AudioDevices.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "megabass tap",
            kAudioAggregateDeviceUIDKey: "com.megabass.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        do {
            try check("Create aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))
            sampleRate = (try? AudioDevices.tapSampleRate(tapID)) ?? 48000
            // Small IO buffers: the haptics can only start once a buffer arrives.
            var frames: UInt32 = 128
            var addr = AudioDevices.address(kAudioDevicePropertyBufferFrameSize)
            AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

            try check("Create IO proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, inTime, _, _ in
                self?.receive(input, inTime, handler)
            })
            try check("Start device", AudioDeviceStart(aggregateID, procID))
        } catch {
            stop()
            throw error
        }
        running = true
    }

    private func receive(_ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>, _ handler: Handler) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, let data = first.mData else { return }
        let channels = Int(first.mNumberChannels)
        var frames: Int
        if list.count > 1 {
            // Non-interleaved: one buffer per channel.
            frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            frames = min(frames, mono.count)
            let n = Float(list.count)
            for i in 0..<frames { mono[i] = 0 }
            for buf in list {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<frames { mono[i] += p[i] / n }
            }
        } else {
            let p = data.assumingMemoryBound(to: Float.self)
            let ch = max(1, channels)
            frames = min(Int(first.mDataByteSize) / MemoryLayout<Float>.size / ch, mono.count)
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<ch { s += p[i * ch + c] }
                mono[i] = s / Float(ch)
            }
        }
        let host = time.pointee.mFlags.contains(.hostTimeValid) ? Clock.seconds(hostTime: time.pointee.mHostTime) : Clock.now()
        let rate = sampleRate
        mono.withUnsafeBufferPointer { handler(UnsafeBufferPointer(rebasing: $0[0..<frames]), host, rate) }
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        running = false
    }

    deinit { stop() }

    private func check(_ what: String, _ s: OSStatus) throws {
        if s != noErr { throw Failure.status(what, s) }
    }
}

public enum AudioDevices {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    public static func defaultOutputDevice() throws -> AudioDeviceID {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let s = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        if s != noErr { throw SystemTap.Failure.status("Read default output", s) }
        return id
    }

    public static func defaultOutputUID() throws -> String {
        let dev = try defaultOutputDevice()
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = address(kAudioDevicePropertyDeviceUID)
        let s = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid)
        guard s == noErr, let uid else { throw SystemTap.Failure.status("Read output UID", s) }
        return uid.takeRetainedValue() as String
    }

    public static func defaultOutputName() -> String {
        guard let dev = try? defaultOutputDevice() else { return "" }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = address(kAudioObjectPropertyName)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr, let name else { return "" }
        return name.takeRetainedValue() as String
    }

    static func tapSampleRate(_ tap: AudioObjectID) throws -> Double {
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = address(kAudioTapPropertyFormat)
        let s = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &fmt)
        if s != noErr || fmt.mSampleRate <= 0 { throw SystemTap.Failure.status("Read tap format", s) }
        return fmt.mSampleRate
    }

    /// How long audio takes from the mixer to the speaker cone, as the device reports it.
    /// Bluetooth headphones report 100-250 ms; built-in speakers about 10-20 ms.
    public static func outputLatency() -> Double {
        guard let dev = try? defaultOutputDevice() else { return 0 }
        func u32(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var v: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = address(sel, scope)
            return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : 0
        }
        var rate: Double = 48000
        var size = UInt32(MemoryLayout<Double>.size)
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        _ = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate)
        var frames = u32(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
            + u32(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)
            + u32(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
        // First output stream's own latency.
        var streamsSize: UInt32 = 0
        var saddr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        if AudioObjectGetPropertyDataSize(dev, &saddr, 0, nil, &streamsSize) == noErr, streamsSize >= 4 {
            var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / 4)
            if AudioObjectGetPropertyData(dev, &saddr, 0, nil, &streamsSize, &streams) == noErr, let st = streams.first {
                var lat: UInt32 = 0
                var lsize = UInt32(4)
                var laddr = address(kAudioStreamPropertyLatency)
                if AudioObjectGetPropertyData(st, &laddr, 0, nil, &lsize, &lat) == noErr { frames += lat }
            }
        }
        return Double(frames) / max(rate, 1)
    }

    /// Calls `onChange` on the main queue when the default output device changes.
    public static func observeDefaultOutput(_ onChange: @escaping () -> Void) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in onChange() }
    }
}

/// System Audio Recording permission, through the private TCC calls Apple's own tools use.
/// Falls back to "unknown" if they are missing; starting the tap then triggers the system prompt.
public enum AudioCapturePermission {
    public enum State { case granted, denied, unknown }
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    public static var state: State {
        guard let tcc, let p = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(p, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    public static func request(_ done: @escaping (Bool) -> Void) {
        guard let tcc, let p = dlsym(tcc, "TCCAccessRequest") else { return done(true) }
        unsafeBitCast(p, to: Request.self)("kTCCServiceAudioCapture" as CFString, nil) { ok in
            DispatchQueue.main.async { done(ok) }
        }
    }
}
