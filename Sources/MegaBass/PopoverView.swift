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
    @ObservedObject var player: CliampBridge

    var body: some View {
        VStack(spacing: 14) {
            header
            PowerRing(engine: engine)
                .padding(.top, 4)
            SpectrumStrip(engine: engine)
            if player.installed { NowPlaying(player: player) }
            if engine.needsPermission { permissionRow }
            Group {
                ModePicker(mode: $engine.mode, enabled: engine.enabled)
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
        .onAppear { player.startPolling() }
        .onDisappear { player.stopPolling() }
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
                .foregroundStyle(engine.enabled && engine.source != .none ? Color.white : Theme.secondary)
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
                    .opacity(engine.enabled ? 0.45 + 0.55 * v : 1)
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
                    Image(systemName: "power")
                        .font(.system(size: 32, weight: .bold))
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
    var enabled = true
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
                            RoundedRectangle(cornerRadius: 8)
                                .fill(enabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.14)))
                                .matchedGeometryEffect(id: "thumb", in: thumb)
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

/// What the haptics play, as one log-scaled strip (20 Hz - 4 kHz) with two handles.
/// Left: how deep (Bass mode cuts below it; Punch rumbles from it). Right: how much of the song.
struct LowBandControl: View {
    @Binding var low: Double
    @Binding var high: Double
    static let range = 20.0...4000.0
    /// Plain-language zones on the strip.
    static let zones: [(name: String, from: Double, to: Double)] = [("Bass", 20, 160), ("Voices", 160, 1000), ("Melody", 1000, 4000)]

    /// Both handles in words, cut at the same edges as the zones on the strip.
    private var summary: String {
        let depth = low < 45 ? "Deep bass" : (low < 90 ? "Bass" : "Upper bass")
        switch high {
        case ...Self.zones[0].to: return depth + " only"
        case ...Self.zones[1].to: return depth + " + voices"
        default: return depth + ", voices + melody"
        }
    }
    private var hzText: String {
        "\(Int(low.rounded())) Hz to " + (high >= 1000 ? String(format: "%.1f kHz", high / 1000) : "\(Int(high.rounded())) Hz")
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Frequencies").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                Spacer()
                Text(summary).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            BandStrip(low: $low, high: $high)
        }
        .help("The trackpad plays \(hzText). Left handle: how deep. Right handle: how much of the song. Above the bass it only plays notes that stand out and last.")
    }
}

/// Two-handle band selector over three faint zones. Drag anywhere: the nearer handle follows.
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
            ZStack(alignment: .topLeading) {
                // Zones: faint segments with their names centred below.
                ForEach(LowBandControl.zones, id: \.name) { z in
                    let a = x(z.from, w), b = x(z.to, w)
                    Capsule().fill(Color.white.opacity(0.08))
                        .frame(width: b - a - 2, height: 6)
                        .offset(x: a + 1, y: 8)
                    Text(z.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(high > z.from && low < z.to ? Color.white.opacity(0.9) : Theme.secondary.opacity(0.6))
                        .fixedSize()
                        .frame(width: b - a)
                        .offset(x: a, y: 26)
                }
                Capsule().fill(Color.white.opacity(0.85))
                    .frame(width: max(6, xh - xl), height: 6)
                    .offset(x: xl, y: 8)
                handle.offset(x: xl - 8, y: 3)
                    .accessibilityElement()
                    .accessibilityLabel("Depth")
                    .accessibilityValue("\(Int(low)) hertz")
                    .accessibilityAdjustableAction { dir in low = max(r.lowerBound, min(high / 1.5, low * (dir == .increment ? 1.1 : 0.9))).rounded() }
                handle.offset(x: xh - 8, y: 3)
                    .accessibilityElement()
                    .accessibilityLabel("How much of the song")
                    .accessibilityValue("up to \(Int(high)) hertz")
                    .accessibilityAdjustableAction { dir in high = max(low * 1.5, min(r.upperBound, high * (dir == .increment ? 1.1 : 0.9))).rounded() }
            }
            .frame(width: w, height: 40, alignment: .topLeading)
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
        .frame(height: 40)
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
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 6)
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: max(6, w * t), height: 6)
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: max(0, min(w - 16, w * t - 8)))
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

/// The visualizer: what the Mac is playing, 30 Hz to 8 kHz, with the note the trackpad is on.
struct SpectrumStrip: View {
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(engine.spectrum.enumerated()), id: \.offset) { i, v in
                    // Bars the trackpad is playing (inside the Frequencies band) glow; the rest stay quiet.
                    let hz = 30 * pow(8000 / 30, (Double(i) + 0.5) / Double(engine.spectrum.count))
                    let inBand = hz >= engine.rumbleHz && hz <= engine.crossover
                    Capsule()
                        .fill(inBand && engine.enabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.28)))
                        .frame(height: max(2, 26 * v))
                }
            }
            .frame(height: 26, alignment: .bottom)
            HStack {
                Text("30 Hz").foregroundStyle(Theme.secondary.opacity(0.6))
                Spacer()
                Text(engine.enabled && !engine.note.isEmpty ? "trackpad ♪ " + engine.note : " ")
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Text("8 kHz").foregroundStyle(Theme.secondary.opacity(0.6))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
        }
        .animation(.linear(duration: 0.06), value: engine.spectrum)
        .accessibilityElement()
        .accessibilityLabel("Spectrum")
        .accessibilityValue(engine.note.isEmpty ? "" : "Trackpad playing \(engine.note)")
    }
}

/// cliamp now playing: title, artist, progress and transport. Start a playlist if cliamp is idle.
struct NowPlaying: View {
    @ObservedObject var player: CliampBridge

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            if player.running && !player.title.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(player.artist.isEmpty ? "cliamp" : player.artist).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    if player.duration > 0 {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.1))
                                Capsule().fill(Color.white.opacity(0.7)).frame(width: g.size.width * min(1, player.position / player.duration))
                            }
                        }
                        .frame(height: 3)
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 12) {
                    transport("backward.fill", "Previous track") { player.prev() }
                    transport(player.playing ? "pause.fill" : "play.fill", player.playing ? "Pause" : "Play") { player.toggle() }
                    transport("forward.fill", "Next track") { player.next() }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("cliamp").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Text(player.running ? "Nothing playing" : "Player not running").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Menu("Play") {
                    ForEach(player.playlists, id: \.self) { name in Button(name) { player.play(playlist: name) } }
                    if player.playlists.isEmpty { Text("No playlists yet: run cliamp in Terminal") }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    private func transport(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}
