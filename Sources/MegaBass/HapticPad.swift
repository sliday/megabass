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
        .frame(height: compact ? 6 : 58)
        .accessibilityElement()
        .accessibilityLabel("Trackpad haptics")
        .accessibilityValue(engine.hapticHz > 0 ? "\(Int(engine.hapticHz)) hertz, \(engine.hapticRate) pulses a second" : "quiet")
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let level = engine.enabled ? engine.level : 0
        let hz = engine.hapticHz
        if compact {
            // A thin level line for the compact view.
            let w = size.width * min(1, level * 1.3)
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: size.height / 2 - 1.5, width: size.width, height: 3), cornerRadius: 1.5), with: .color(.white.opacity(0.1)))
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: size.height / 2 - 1.5, width: w, height: 3), cornerRadius: 1.5), with: .color(Theme.hot))
            return
        }
        // The pad: a trackpad-shaped tile on the left, shaking with the level.
        let padW: CGFloat = 86, padH: CGFloat = 54
        let shake = level * 1.6
        let jx = engine.enabled ? CGFloat(sin(t * 61) * shake) : 0, jy = engine.enabled ? CGFloat(cos(t * 47) * shake * 0.6) : 0
        let pad = CGRect(x: 2 + jx, y: (size.height - padH) / 2 + jy, width: padW, height: padH)
        let shape = Path(roundedRect: pad, cornerRadius: 9)
        ctx.fill(shape, with: .linearGradient(Gradient(colors: [Color(white: 0.24), Color(white: 0.14)]),
                                             startPoint: CGPoint(x: pad.minX, y: pad.minY), endPoint: CGPoint(x: pad.maxX, y: pad.maxY)))
        ctx.stroke(shape, with: .color(.white.opacity(0.14 + 0.4 * level)), lineWidth: 1)
        // Ripples from the centre: spacing shrinks and speed grows with frequency.
        var inside = ctx
        inside.clip(to: shape)
        if hz > 0 && level > 0.02 {
            let c = CGPoint(x: pad.midX, y: pad.midY)
            let spacing = max(4, 22 - log2(max(20, hz) / 20) * 4.5)        // 20 Hz wide rings, 1 kHz tight
            let speed = 18 + hz * 0.08
            let phase = (t * speed).truncatingRemainder(dividingBy: spacing)
            var r = phase
            while r < 60 {
                let a = (1 - r / 60) * min(1, level * 1.6)
                inside.stroke(Path(ellipseIn: CGRect(x: c.x - r * 1.5, y: c.y - r, width: r * 3, height: r * 2)),
                              with: .color(Theme.hot.opacity(a)), lineWidth: 1.4)
                r += spacing
            }
            inside.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)),
                        with: .color(Theme.heat.opacity(0.4 + 0.6 * level)))
        }
        // The words.
        let x = pad.maxX + 12
        let big = hz > 0 && level > 0.02 ? "\(Int(hz.rounded())) Hz" : (engine.enabled ? "quiet" : "off")
        ctx.draw(Text(big).font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundColor(.white),
                 at: CGPoint(x: x, y: size.height / 2 - 9), anchor: .leading)
        let small = hz > 0 && level > 0.02
            ? [engine.note.split(separator: "·").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "", "\(engine.hapticRate) pulses/s"].filter { !$0.isEmpty }.joined(separator: " · ")
            : "the trackpad follows the music"
        ctx.draw(Text(small).font(.system(size: 11)).foregroundColor(Theme.secondary),
                 at: CGPoint(x: x, y: size.height / 2 + 11), anchor: .leading)
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
