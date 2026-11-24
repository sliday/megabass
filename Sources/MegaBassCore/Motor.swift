import Foundation

/// The trackpad's Force Touch haptic motor, driven through the private MultitouchSupport framework.
/// Technique from nospeaker (MIT, Cody Collier): one actuation per short burst of sine tones.
public final class Motor {
    public enum Failure: Error, CustomStringConvertible {
        case frameworkMissing, noTrackpad, noHapticMotor
        public var description: String {
            switch self {
            case .frameworkMissing: return "This macOS lacks the MultitouchSupport functions megabass needs."
            case .noTrackpad: return "No trackpad found."
            case .noHapticMotor: return "The trackpad has no Force Touch motor."
            }
        }
    }

    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
    private typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
    private typealias ActuatorClose = @convention(c) (CFTypeRef) -> Int32
    private typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
    private typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

    private let actuator: CFTypeRef
    private let pointer: UnsafeMutableRawPointer
    private let create: ActuationCreate
    private let fire: ActuationPlay
    private let close: ActuatorClose?
    private var deviceList: CFArray?
    public let builtIn: Bool
    public private(set) var actuations = 0

    public init() throws {
        guard let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            throw Failure.frameworkMissing
        }
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(mt, name).map { unsafeBitCast($0, to: T.self) } }
        guard let createList = sym("MTDeviceCreateList", CreateList.self),
              let getID = sym("MTDeviceGetDeviceID", GetID.self),
              let actuatorCreate = sym("MTActuatorCreateFromDeviceID", ActuatorCreate.self),
              let actuatorOpen = sym("MTActuatorOpen", ActuatorOpen.self),
              let create = sym("MTActuationCreateFromDictionary", ActuationCreate.self),
              let fire = sym("MTActuationActuate", ActuationPlay.self)
        else { throw Failure.frameworkMissing }
        let isBuiltIn = sym("MTDeviceIsBuiltIn", IsBuiltIn.self)
        guard let list = createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else { throw Failure.noTrackpad }
        var ids: [(id: UInt64, builtIn: Bool)] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            if getID(dev, &id) == 0 { ids.append((id, isBuiltIn?(dev) ?? false)) }
        }
        for d in ids.sorted(by: { $0.builtIn && !$1.builtIn }) {
            if let ref = actuatorCreate(d.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 {
                actuator = ref
                pointer = Unmanaged.passUnretained(ref as AnyObject).toOpaque()
                builtIn = d.builtIn
                self.create = create
                self.fire = fire
                close = sym("MTActuatorClose", ActuatorClose.self)
                deviceList = list
                return
            }
        }
        throw Failure.noHapticMotor
    }

    deinit { _ = close?(actuator) }

    /// Plays sine tones (Hz, relative weight) together for `ms` milliseconds at `level` 0...1.
    /// Weights are normalised to sum to 1; the driver stalls on long runs above that.
    @discardableResult
    public func play(_ tones: [(hz: Double, amp: Double)], ms: Double, level: Float) -> Bool {
        guard !tones.isEmpty, level > 0.001 else { return false }
        let sum = max(tones.reduce(0) { $0 + $1.amp }, 0.0001)
        let shape: [String: Any] = [
            "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": ms],
            "Tones": tones.map {
                ["Type": "Sine", "Amplitude": $0.amp / sum, "DurationMS": ms, "DelayMS": 0.0, "FrequencykHz": $0.hz / 1000]
            },
        ]
        guard let act = create(shape as CFDictionary, 0) else { return false }
        let ok = fire(act, pointer, 0, min(1, max(0, level)), 0) == 0
        Unmanaged<AnyObject>.fromOpaque(act).release()
        actuations += 1
        return ok
    }
}
