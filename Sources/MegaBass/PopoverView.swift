import AppKit
import MegaBassCore
import SwiftUI

enum Theme {
    static let ground = Color(red: 0.043, green: 0.043, blue: 0.059)
    static let panel = Color(red: 0.086, green: 0.086, blue: 0.11)
    static let hairline = Color.white.opacity(0.07)
    static let secondary = Color(red: 0.54, green: 0.54, blue: 0.59)
    // Accent pair: megabass magenta/orange by default; follows the playing source and station.
    nonisolated(unsafe) static var hot = Palettes.megabass.hot
    nonisolated(unsafe) static var heat = Palettes.megabass.heat
    static var accent: LinearGradient { LinearGradient(colors: [hot, heat], startPoint: .topLeading, endPoint: .bottomTrailing) }
}

struct PopoverView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var hub: NowPlayingHub
    @ObservedObject private var theme = ThemeAnimator.shared

    private var paletteKey: String { hub.active.rawValue + ":" + hub.cliamp.station }
    /// One planet per cliamp station; per track for Spotify and Music.
    private var planetKey: String {
        hub.active == .cliamp ? "cliamp:" + (hub.cliamp.station.isEmpty ? "megabass" : hub.cliamp.station) : hub.active.rawValue + ":" + hub.now.title
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            PowerRing(engine: engine, planet: PlanetStyle.from(planetKey))
                .padding(.top, 4)
            if !hub.installedSources.isEmpty { NowPlaying(hub: hub, player: hub.cliamp) }
            if engine.needsPermission { permissionRow }
            Group {
                ModePicker(mode: $engine.mode, enabled: engine.enabled)
                VStack(spacing: 14) {
                    LowBandControl(low: $engine.rumbleHz, high: $engine.crossover, spectrum: engine.spectrum, live: engine.enabled)
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
        .environment(\.themeTick, theme.tick)              // every accent view repaints as the palette blends
        .coordinateSpace(name: "panel")
        .onContinuousHover(coordinateSpace: .named("panel")) { phase in
            switch phase {
            case .active(let p): RingSim.shared.cursor = p
            case .ended: RingSim.shared.cursor = nil
            }
        }
        .onAppear { applyPalette() }
        .onChange(of: paletteKey) { _ in applyPalette() }
        .environment(\.colorScheme, .dark)
        .onAppear { hub.startPolling() }
        .onDisappear { hub.stopPolling() }
    }

    private func applyPalette() {
        theme.go(to: Palettes.current(source: hub.active, station: hub.cliamp.station), key: paletteKey)
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
        case .system: return (engine.spectrum.max() ?? 0) > 0.05 ? "LISTENING" : "SILENT"
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
    var planet = PlanetStyle.from("megabass")
    @Environment(\.themeTick) private var themeTick
    private let ticks = 48

    var body: some View {
        ZStack {
            // vizamp's particle ridge, bent into a circle.
            RingVisualizer(engine: engine)
                .frame(width: 280, height: 280)          // sparks fly past the hero's box; layout stays 168
            Button(action: { withAnimation(.easeOut(duration: 0.18)) { engine.toggle() } }) {
                ZStack {
                    // A small gas giant with an atmosphere; the halo spills past the 96 pt hit area.
                    // The power icon lives on the planet's surface (see PlanetSpin).
                    PlanetView(engine: engine, radius: 48, style: planet)
                        .frame(width: 164, height: 164)
                }
                .frame(width: 96, height: 96)
                .contentShape(Circle())
                .scaleEffect(1 + 0.04 * engine.kickPulse)
            }
            .buttonStyle(.plain)
            .onHover { PlanetSpin.shared.hover = $0 }
            .help("Planet " + planet.definition)
            .accessibilityLabel(engine.enabled ? "Turn megabass off" : "Turn megabass on")
        }
        .frame(width: 168, height: 168)
        .background(GeometryReader { g in
            // Where the ring sits in the panel, for the cursor-driven MilkDrop flow.
            let f = g.frame(in: .named("panel"))
            let _ = { RingSim.shared.ringCenter = CGPoint(x: f.midX, y: f.midY) }()
            Color.clear
        })
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
    @Environment(\.themeTick) private var themeTick
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
                    .foregroundStyle(mode == m ? (enabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white)) : AnyShapeStyle(Theme.secondary))
                    .background {
                        if mode == m {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.1))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
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
    var spectrum: [Double] = []
    var live = false
    static let range = SpectrumAnalyzer.range
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
            BandStrip(low: $low, high: $high, spectrum: spectrum, live: live)
        }
        .help("The trackpad plays \(hzText). Left handle: how deep. Right handle: how much of the song. Above the bass it only plays notes that stand out and last.")
    }
}

/// Two-handle band selector over three faint zones. Drag anywhere: the nearer handle follows.
struct BandStrip: View {
    @Binding var low: Double
    @Environment(\.themeTick) private var themeTick
    @Binding var high: Double
    var spectrum: [Double] = []
    var live = false
    private let r = LowBandControl.range

    private func x(_ hz: Double, _ w: CGFloat) -> CGFloat { CGFloat(log(hz / r.lowerBound) / log(r.upperBound / r.lowerBound)) * w }
    private func hz(_ x: CGFloat, _ w: CGFloat) -> Double { r.lowerBound * pow(r.upperBound / r.lowerBound, Double(max(0, min(1, x / max(1, w))))) }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let xl = x(low, w), xh = x(high, w)
            ZStack(alignment: .topLeading) {
                // The track is the live spectrum on the same axis: bars the trackpad plays glow.
                let n = max(1, spectrum.count)
                let barW = w / CGFloat(n)
                ForEach(0..<n, id: \.self) { i in
                    let v = i < spectrum.count ? spectrum[i] : 0
                    let hz = r.lowerBound * pow(r.upperBound / r.lowerBound, (Double(i) + 0.5) / Double(n))
                    let inBand = hz >= low && hz <= high
                    let h = 3 + 25 * CGFloat(live ? v : 0)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(inBand ? (live ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.5))) : AnyShapeStyle(Color.white.opacity(0.16)))
                        .frame(width: max(1.5, barW - 2), height: h)
                        .offset(x: CGFloat(i) * barW + 1, y: 30 - h)
                }
                // Zone names under the track.
                ForEach(LowBandControl.zones, id: \.name) { z in
                    let a = x(z.from, w), b = x(z.to, w)
                    Text(z.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(high > z.from && low < z.to ? Color.white.opacity(0.9) : Theme.secondary.opacity(0.6))
                        .fixedSize()
                        .frame(width: b - a)
                        .offset(x: a, y: 40)
                }
                // The band itself: a thin bar along the bottom of the track, handles on it.
                Capsule().fill(Color.white.opacity(0.85))
                    .frame(width: max(4, xh - xl), height: 3)
                    .offset(x: xl, y: 31)
                handle.offset(x: xl - 8, y: 24.5)
                    .accessibilityElement()
                    .accessibilityLabel("Depth")
                    .accessibilityValue("\(Int(low)) hertz")
                    .accessibilityAdjustableAction { dir in low = max(r.lowerBound, min(high / 1.5, low * (dir == .increment ? 1.1 : 0.9))).rounded() }
                handle.offset(x: xh - 8, y: 24.5)
                    .accessibilityElement()
                    .accessibilityLabel("How much of the song")
                    .accessibilityValue("up to \(Int(high)) hertz")
                    .accessibilityAdjustableAction { dir in high = max(low * 1.5, min(r.upperBound, high * (dir == .increment ? 1.1 : 0.9))).rounded() }
            }
            .frame(width: w, height: 54, alignment: .topLeading)
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
        .frame(height: 54)
        .animation(.linear(duration: 0.06), value: spectrum)
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

/// Now playing from cliamp, Spotify or Music: source/station pill, title, artist, progress, transport.
struct NowPlaying: View {
    @ObservedObject var hub: NowPlayingHub
    @Environment(\.themeTick) private var themeTick
    @ObservedObject var player: CliampBridge

    var body: some View {
        let now = hub.now
        VStack(alignment: .leading, spacing: 8) {
            sourceMenu
            // Title and artist share one centre line with the transport.
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if now.running && !now.title.isEmpty {
                        Text(now.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(now.artist.isEmpty ? hub.active.name : now.artist).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    } else {
                        Text("Nothing playing").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("Pick a station or a player above").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    transport("backward.fill", "Previous track") { hub.prev() }
                    transport(now.playing ? "pause.fill" : "play.fill", now.playing ? "Pause" : "Play") {
                        if now.running { hub.toggle() } else { hub.select(hub.active) }
                    }
                    transport("forward.fill", "Next track") { hub.next() }
                }
            }
            // Full-width progress, times at both ends (Control Center style).
            if now.running && now.duration > 0 {
                VStack(spacing: 3) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule().fill(Theme.accent).frame(width: g.size.width * min(1, now.position / now.duration))
                        }
                    }
                    .frame(height: 3)
                    HStack {
                        Text(Self.time(now.position))
                        Spacer()
                        Text("-" + Self.time(max(0, now.duration - now.position)))
                    }
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    /// The pill: what's playing (a cliamp station, Spotify, Music). Its menu switches players and stations.
    private var sourceMenu: some View {
        Menu {
            Section("Play on") {
                ForEach(hub.installedSources) { s in
                    Button { hub.select(s) } label: {
                        let mark = hub.snapshot(s).playing ? "  ▸ playing" : ""
                        if s == hub.active { Label(s.name + mark, systemImage: "checkmark") } else { Text(s.name + mark) }
                    }
                }
            }
            if !player.stations.isEmpty {
                Section("cliamp radio") {
                    ForEach(player.stations, id: \.id) { st in
                        Button { player.play(station: st.id); hub.select(.cliamp) } label: {
                            if hub.active == .cliamp && st.id == player.station { Label(st.name, systemImage: "checkmark") } else { Text(st.name) }
                        }
                    }
                }
            }
            if !player.playlists.isEmpty {
                Section("cliamp playlists") {
                    ForEach(player.playlists, id: \.self) { name in Button(name) { player.play(playlist: name); hub.select(.cliamp) } }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: hub.active == .cliamp ? "dot.radiowaves.left.and.right" : "music.note")
                    .font(.system(size: 9, weight: .semibold))
                Text(pillTitle)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.hot)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.hot.opacity(0.14)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch player or cliamp station")
        .accessibilityLabel("Source")
    }

    private var pillTitle: String {
        if hub.active == .cliamp { return player.stations.first { $0.id == player.station }?.name ?? "cliamp" }
        return hub.active.name
    }

    static func time(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    private func transport(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}
