import AppKit
import MegaBassCore
import SwiftUI

enum Theme {
    static let ground = Color(red: 0.043, green: 0.043, blue: 0.059)
    static let panel = Color(red: 0.086, green: 0.086, blue: 0.11)
    static let hairline = Color.white.opacity(0.07)
    static let secondary = Color(red: 0.54, green: 0.54, blue: 0.59)
    static let hot = Color(red: 1.0, green: 0.18, blue: 0.47)       // magenta
    static let heat = Color(red: 1.0, green: 0.48, blue: 0.16)      // orange
    static let accent = LinearGradient(colors: [hot, heat], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct PopoverView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(spacing: 14) {
            header
            PowerRing(engine: engine)
                .padding(.vertical, 4)
            if engine.needsPermission { permissionRow }
            Group {
                ModePicker(mode: $engine.mode)
                VStack(spacing: 14) {
                    LowBandControl(low: $engine.rumbleHz, high: $engine.crossover)
                    ValueSlider(label: "Intensity", value: $engine.intensity, range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" })
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
            }
            .opacity(engine.enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.18), value: engine.enabled)
            footer
        }
        .padding(16)
        .frame(width: 300)
        .background(Theme.ground.opacity(0.88))
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("megabass")
                .font(.system(size: 15, weight: .black, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(.white)
            Spacer()
            Text(status)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(engine.enabled && engine.source != .none ? Theme.hot : Theme.secondary)
                .accessibilityLabel("Status: \(status.lowercased())")
        }
    }

    private var status: String {
        if let p = engine.problem, !p.isEmpty { return "ERROR" }
        if !engine.enabled { return "OFF" }
        switch engine.source {
        case .demo: return "DEMO"
        case .system: return engine.bassLevel > 0.03 ? "LISTENING" : "NO BASS"
        case .none: return engine.needsPermission ? "NEEDS ACCESS" : "IDLE"
        }
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("megabass needs System Audio Recording to hear your music.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Allow") { engine.requestPermission() }
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let p = engine.problem, !p.isEmpty {
                Text(p).font(.system(size: 11)).foregroundStyle(Theme.hot).frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack {
                Button { engine.toggleDemo() } label: {
                    Label(engine.demoPlaying ? "Stop demo" : "Play demo", systemImage: engine.demoPlaying ? "stop.fill" : "play.fill")
                }
                .help("Play a built-in groove through your speakers and the trackpad. Needs no permissions.")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.secondary)
        }
    }
}

/// The hero: a power button wrapped in a ring of ticks that pulse with the bass.
struct PowerRing: View {
    @ObservedObject var engine: Engine
    private let ticks = 48

    var body: some View {
        ZStack {
            // Meter ring.
            ForEach(0..<ticks, id: \.self) { i in
                let v = level(at: i)
                Capsule()
                    .fill(engine.enabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.12)))
                    .opacity(engine.enabled ? 0.25 + 0.75 * v : 1)
                    .frame(width: 3, height: 6 + 16 * v)
                    .offset(y: -(62 + 8 * v))
                    .rotationEffect(.degrees(Double(i) / Double(ticks) * 360))
            }
            Button(action: { withAnimation(.easeOut(duration: 0.18)) { engine.toggle() } }) {
                ZStack {
                    Circle()
                        .fill(engine.enabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.panel))
                    Circle()
                        .strokeBorder(engine.enabled ? Color.white.opacity(0.25) : Color.white.opacity(0.1), lineWidth: 1)
                    VStack(spacing: 2) {
                        Image(systemName: "power")
                            .font(.system(size: 30, weight: .bold))
                        Text(engine.note.isEmpty ? " " : engine.note)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .opacity(0.85)
                    }
                    .foregroundStyle(engine.enabled ? .white : Theme.secondary)
                }
                .frame(width: 96, height: 96)
                .scaleEffect(1 + 0.04 * engine.kickPulse)
                .shadow(color: engine.enabled ? Theme.hot.opacity(0.35 + 0.35 * engine.kickPulse) : .clear, radius: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(engine.enabled ? "Turn megabass off" : "Turn megabass on")
        }
        .frame(width: 168, height: 168)
    }

    /// History mapped around the ring: newest at 12 o'clock, mirrored left and right.
    private func level(at i: Int) -> Double {
        guard engine.enabled else { return 0 }
        let h = engine.history
        let half = ticks / 2
        let d = i <= half ? i : ticks - i
        let idx = h.count - 1 - min(h.count - 1, d * h.count / (half + 1))
        return max(0, min(1, h[idx]))
    }
}

struct ModePicker: View {
    @Binding var mode: BassMode
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(BassMode.allCases, id: \.self) { m in
                Button { withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { mode = m } } label: {
                    VStack(spacing: 3) {
                        Image(systemName: icon(m)).font(.system(size: 13, weight: .semibold))
                        Text(m.title).font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(mode == m ? .white : Theme.secondary)
                    .background {
                        if mode == m {
                            RoundedRectangle(cornerRadius: 8).fill(Theme.accent).matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(m))
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    private func icon(_ m: BassMode) -> String {
        switch m { case .punch: "circle.dotted.circle"; case .bass: "waveform"; case .harmony: "music.quarternote.3" }
    }
    private func help(_ m: BassMode) -> String {
        switch m {
        case .punch: "Kicks thump, and the trackpad shakes at the bass note."
        case .bass: "The trackpad plays the song's own bass, cycle by cycle, with your speakers."
        case .harmony: "Hear it: the trackpad sings a third above the bass, in the song's key."
        }
    }
}

/// The low band the haptics play, as one log-scaled strip (20-300 Hz) with two handles.
/// Low: the floor (Bass mode cuts below it; Punch rumbles from it). High: the cutoff.
struct LowBandControl: View {
    @Binding var low: Double
    @Binding var high: Double
    static let range = 20.0...4000.0

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Frequencies").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                Spacer()
                Text("\(Int(low.rounded())) Hz – " + (high >= 1000 ? String(format: "%.1f kHz", high / 1000) : "\(Int(high.rounded())) Hz"))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
            BandStrip(low: $low, high: $high)
            HStack {
                Text("Bass"); Spacer(); Text("Voices"); Spacer(); Text("Melody")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.secondary.opacity(0.8))
        }
        .help("Drag the handles to choose what the trackpad plays. Bass is replayed cycle by cycle; above it, the trackpad plays any note that stands out and lasts long enough.")
    }
}

/// Two-handle band selector. Drag anywhere: the nearer handle follows.
struct BandStrip: View {
    @Binding var low: Double
    @Binding var high: Double
    private let r = LowBandControl.range

    private func x(_ hz: Double, _ w: CGFloat) -> CGFloat { CGFloat(log(hz / r.lowerBound) / log(r.upperBound / r.lowerBound)) * w }
    private func hz(_ x: CGFloat, _ w: CGFloat) -> Double { r.lowerBound * pow(r.upperBound / r.lowerBound, Double(max(0, min(1, x / max(1, w))))) }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let xl = x(low, w), xh = x(high, w)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(height: 6)
                Capsule().fill(Theme.accent).frame(width: max(6, xh - xl), height: 6).offset(x: xl)
                handle.offset(x: xl - 8)
                handle.offset(x: xh - 8)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    let key = "band"
                    if Detents.last[key] == nil {
                        Detents.last[key] = abs(d.startLocation.x - xl) <= abs(d.startLocation.x - xh) ? 0 : 1
                    }
                    let f = hz(d.location.x, w).rounded()
                    if Detents.last[key] == 0 { low = min(f, high / 1.5) } else { high = max(f, low * 1.5) }
                }
                .onEnded { _ in Detents.last["band"] = nil })
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("Frequencies")
        .accessibilityValue("\(Int(low)) to \(Int(high)) hertz")
        .accessibilityAdjustableAction { dir in high = max(low * 1.5, min(r.upperBound, high * (dir == .increment ? 1.1 : 0.9))) }
    }

    private var handle: some View {
        Circle().fill(.white).frame(width: 16, height: 16)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }
}

/// Label + value on one line, slim accent track below. Gives a trackpad tick at 25/50/75 %.
struct ValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var log: Bool = false
    let format: (Double) -> String
    var small = false

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(label).font(.system(size: small ? 11 : 12, weight: .medium)).foregroundStyle(small ? Theme.secondary : .white)
                Spacer()
                Text(format(value)).font(.system(size: small ? 11 : 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            GeometryReader { g in
                let w = g.size.width
                let t = fraction(value)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 4)
                    Capsule().fill(Theme.accent).frame(width: max(4, w * t), height: 4)
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: max(0, min(w - 14, w * t - 7)))
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                    set(fraction: d.location.x / max(1, w))
                })
            }
            .frame(height: 16)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { dir in
            let t = fraction(value)
            set(fraction: dir == .increment ? t + 0.05 : t - 0.05)
        }
    }

    private func fraction(_ v: Double) -> Double {
        log ? Foundation.log(v / range.lowerBound) / Foundation.log(range.upperBound / range.lowerBound)
            : (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func set(fraction t: Double) {
        let t = max(0, min(1, t))
        var v = log ? range.lowerBound * pow(range.upperBound / range.lowerBound, t)
                    : range.lowerBound + t * (range.upperBound - range.lowerBound)
        if step > 0 { v = (v / step).rounded() * step }
        value = v
        let detent = Int(t * 4)
        if let last = Detents.last[label], last != detent {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        Detents.last[label] = detent
    }
}

/// Last quarter each slider sat in (no @State: the Command Line Tools ship without SwiftUI's macro plugin).
@MainActor enum Detents { static var last: [String: Int] = [:] }
