import MegaBassCore
import SwiftUI

/// What the trackpad is doing, at a glance: a small trackpad that shakes with the haptic level,
/// with ripples spreading from its centre: closer and faster at higher frequencies. The caption
/// says it in words: "47 Hz · B1 · 62 pulses/s".
struct HapticPad: View {
    @ObservedObject var engine: Engine
    @Environment(\.themeTick) private var themeTick
    var compact = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !engine.enabled)) { tl in
            Canvas { ctx, size in draw(ctx, size: size, t: tl.date.timeIntervalSinceReferenceDate) }
        }
        .frame(height: compact ? 6 : 64)
        .accessibilityElement()
        .accessibilityLabel("Trackpad haptics")
        .accessibilityValue(!engine.enabled ? "off" : (engine.hapticHzShown > 0 ? "\(Int(engine.hapticHzShown)) hertz" : "waiting for music"))
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let level = engine.enabled ? engine.level : 0
        let hz = engine.hapticHz
        if compact {
            let w = size.width * min(1, level * 1.3)
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: size.height / 2 - 1.5, width: size.width, height: 3), cornerRadius: 1.5), with: .color(.white.opacity(0.1)))
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: size.height / 2 - 1.5, width: w, height: 3), cornerRadius: 1.5), with: .color(Theme.hot))
            return
        }
        // The pad: a trackpad across the card. It doesn't shake; shapes carry the motion.
        let pad = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let shape = Path(roundedRect: pad, cornerRadius: 10)
        ctx.fill(shape, with: .linearGradient(Gradient(colors: [Color(white: 0.2), Color(white: 0.12)]),
                                             startPoint: CGPoint(x: pad.minX, y: pad.minY), endPoint: CGPoint(x: pad.maxX, y: pad.maxY)))
        ctx.stroke(shape, with: .color(.white.opacity(0.1 + 0.3 * level)), lineWidth: 1)
        var inside = ctx
        inside.clip(to: shape)
        let c = CGPoint(x: pad.midX, y: pad.midY)
        if engine.enabled, hz > 0, level > 0.02 {
            // A soundwave, not rings: one soft radial gradient whose brightness follows a sine
            // outward from the centre. Phase is accumulated and the wavelength eased, so frequency
            // changes bend the motion instead of making it jump.
            let w = WavePhase.shared.advance(t: t, hz: hz)
            let reach = pad.width * 0.55
            var stops: [Gradient.Stop] = []
            let n = 28
            for k in 0...n {
                let x = Double(k) / Double(n)
                let wave = 0.5 + 0.5 * sin(2 * .pi * (x * reach / w.lambda - w.phase))
                let a = wave * (1 - x) * (1 - x) * min(1, level * 1.4) * 0.85
                stops.append(.init(color: Theme.hot.opacity(a), location: x))
            }
            var oval = inside
            oval.translateBy(x: c.x, y: c.y)
            oval.scaleBy(x: 1.6, y: 0.55)
            oval.fill(Path(ellipseIn: CGRect(x: -reach, y: -reach, width: reach * 2, height: reach * 2)),
                      with: .radialGradient(Gradient(stops: stops), center: .zero, startRadius: 0, endRadius: reach))
            let kick = engine.kickPulse
            let d = 7 + 6 * kick
            inside.fill(Path(ellipseIn: CGRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2)),
                        with: .radialGradient(Gradient(colors: [Theme.heat.opacity(0.5 + 0.5 * max(level, kick)), Theme.heat.opacity(0)]),
                                              center: c, startRadius: 0, endRadius: d))
        } else {
            let msg = engine.enabled ? "Waiting for music" : "Off"
            inside.draw(Text(msg).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.secondary), at: c, anchor: .center)
        }
        // Hz, calm: bottom-right, 4 updates a second, rounded to 5 Hz, held for 1 s, then "–".
        if engine.enabled {
            let shown = engine.hapticHzShown
            let text = shown > 0 ? "\(Int(shown)) Hz" : "–"
            inside.draw(Text(text).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundColor(Theme.secondary),
                        at: CGPoint(x: pad.maxX - 9, y: pad.maxY - 8), anchor: .bottomTrailing)
        }
    }
}

/// A soft radial glow behind the panel, centred on the planet, ~200 pt across: 5 % at rest,
/// up to 10 %, breathing with the trackpad's soundwave.
struct BackgroundGlow: View, Equatable {
    let engine: Engine
    var enabled = true
    static func == (a: BackgroundGlow, b: BackgroundGlow) -> Bool { a.enabled == b.enabled }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !enabled)) { _ in
            Canvas { ctx, size in
                let c = RingSim.shared.ringCenter == .zero ? CGPoint(x: size.width / 2, y: 150) : RingSim.shared.ringCenter
                let beat = engine.enabled ? WavePhase.shared.pulse * min(1, engine.level * 1.4) : 0
                let a = 0.05 + 0.05 * beat
                let r: CGFloat = 200
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                         with: .radialGradient(Gradient(stops: [
                            .init(color: Theme.hot.opacity(a), location: 0),
                            .init(color: Theme.hot.opacity(a * 0.6), location: 0.35),
                            .init(color: Theme.hot.opacity(a * 0.18), location: 0.7),
                            .init(color: Theme.hot.opacity(0), location: 1),
                         ]), center: c, startRadius: 0, endRadius: r))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Soundwave phase for the trackpad visual: accumulated per frame, wavelength eased.
@MainActor
final class WavePhase {
    static let shared = WavePhase()
    private(set) var phase = 0.0
    private(set) var lambda = 20.0
    /// 0...1, the same pulse the trackpad wave shows at its centre (for the window glow).
    var pulse: Double { 0.5 + 0.5 * sin(2 * .pi * phase) }
    private var last = 0.0

    func advance(t: Double, hz: Double) -> (phase: Double, lambda: Double) {
        let dt = last == 0 ? 0 : min(0.1, t - last)
        last = t
        let target = max(6, 30 - log2(max(20, hz) / 20) * 5.5)        // deep = long waves, high = short
        lambda += (target - lambda) * min(1, dt * 3)
        phase += dt * (1.2 + hz * 0.004)                               // waves per second, eased by lambda
        return (phase, lambda)
    }
}

/// Tells a drag from a click: past 3 pt the press moves the window under the pointer.
@MainActor
final class WindowDrag {
    static let shared = WindowDrag()
    private var start: NSPoint?
    private var origin: NSPoint = .zero
    private var window: NSWindow?
    private var moved = false

    func changed() {
        let mouse = NSEvent.mouseLocation
        if start == nil {
            start = mouse
            window = NSApp.currentEvent?.window ?? NSApp.keyWindow
            origin = window?.frame.origin ?? .zero
            moved = false
            return
        }
        guard let s = start else { return }
        let dx = mouse.x - s.x, dy = mouse.y - s.y
        if !moved && hypot(dx, dy) < 3 { return }
        moved = true
        window?.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    /// Ends the press; returns true when it was a drag (so it isn't a click).
    func ended() -> Bool {
        defer { start = nil; window = nil }
        return moved
    }
}

/// Pointer over the widget (no @State: the Command Line Tools lack SwiftUI's macro plugin).
@MainActor
final class WidgetHover: ObservableObject {
    static let shared = WidgetHover()
    @Published var on = false
}

/// Window layout: the full panel, or the floating planet widget. Remembered across launches.
@MainActor
final class LayoutState: ObservableObject {
    static let shared = LayoutState()
    @Published var compact = UserDefaults.standard.bool(forKey: "compact") {
        didSet {
            UserDefaults.standard.set(compact, forKey: "compact")
            onChange?()
        }
    }
    /// Switches between the full panel and the widget window.
    var onChange: (() -> Void)?
    /// Hides every megabass window (the menu-bar icon stays).
    var hideAll: (() -> Void)?
    /// The menu-bar popover opened (true) or closed (false).
    var menuOpen: ((Bool) -> Void)?
}

/// The planet widget: just the planet and its ring, filling a borderless square window that
/// floats in a corner. Controls fade in on hover: transport along the bottom, expand and close on top.
struct WidgetView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var hub: NowPlayingHub
    @ObservedObject private var theme = ThemeAnimator.shared
    @ObservedObject private var hoverState = WidgetHover.shared
    private var hover: Bool { hoverState.on }

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            ZStack {
                // The hero is laid out for 280 pt; scale it to the window.
                PowerRing(engine: engine, planet: PlanetStyle.from(hub.planetKey), draggable: true)
                    .frame(width: 280, height: 280)
                    .scaleEffect(side / 280)
                    .frame(width: side, height: side)
                if hover { controls(side: side).transition(.opacity) }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .environment(\.themeTick, theme.tick)
        .environment(\.colorScheme, .dark)
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hoverState.on = h } }
        .onAppear { hub.startPolling(); hub.applyPalette() }
        .onChange(of: hub.paletteKey) { _ in hub.applyPalette() }
    }

    private func controls(side: CGFloat) -> some View {
        VStack {
            HStack {
                Spacer()
                chip("dice", "New random planet for this song") { hub.rollPlanet() }
                chip("arrow.up.left.and.arrow.down.right", "Open the full panel") { LayoutState.shared.compact = false }
                chip("xmark", "Close the widget") { LayoutState.shared.compact = false; LayoutState.shared.hideAll?() }
            }
            Spacer()
            VStack(spacing: 4) {
                if !hub.now.title.isEmpty {
                    Text(hub.now.title).font(.system(size: max(9, side * 0.045), weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                }
                HStack(spacing: 6) {
                    chip("backward.fill", "Previous track") { hub.prev() }
                    chip(hub.now.playing ? "pause.fill" : "play.fill", hub.now.playing ? "Pause" : "Play") {
                        if hub.now.running { hub.toggle() } else { hub.select(hub.active) }
                    }
                    chip("forward.fill", "Next track") { hub.next() }
                }
            }
        }
        .padding(8)
    }

    private func chip(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.black.opacity(0.55)))
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
