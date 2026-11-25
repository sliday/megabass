import AppKit
import MegaBassCore
import SwiftUI

// The particle ridge from vizamp (github.com/sliday/vizamp, Ridge view), bent into a circle around
// the power button: the spectrum is the ridge, bands heat up as they move, grains sit on the ridge,
// get thrown outward when it jumps and fall back toward the button. Kicks burst sparks.

/// Simulation state. A class (not @State: the Command Line Tools lack SwiftUI's macro plugin).
@MainActor
final class RingSim {
    static let shared = RingSim()

    struct Grain {
        var th: Double, r: Double, vr: Double, vt: Double
        var air: Bool, size: Double, age: Double, life: Double
        var spark: Double, ground: Double, restitution: Double, drag: Double
        var px: Double, py: Double, drawn: Bool
        /// Own brightness: a launched spark stays lit while it flies; resting grains follow the music slowly.
        var glow: Double = 0
    }

    var levels: [Double] = []
    var heat: [Double] = []
    /// Outward kick on the ridge from arriving pulses, per band; springs back in ~150 ms.
    var push: [Double] = []

    /// A bright packet racing up a stalk from the planet to the ridge (vizamp's Pulse + Impact).
    struct Packet { var stalk: Int; var travel: Double; var speed: Double; var energy: Double }
    static let stalks = 48
    var packets: [Packet] = []
    private var stalkPrior = [Double](repeating: 0, count: RingSim.stalks)
    private var stalkCooldown = [Double](repeating: 0, count: RingSim.stalks)
    func stalkAngle(_ i: Int) -> Double { -.pi / 2 + Double(i) / Double(Self.stalks) * 2 * .pi }

    /// Background stars in unit coordinates (-1...1), drifting very slowly around the centre.
    struct Star { var x: Double; var y: Double; var size: Double; var phase: Double }
    lazy var stars: [Star] = (0..<90).map { _ in
        Star(x: rand(-1, 1), y: rand(-1, 1), size: rand(0.5, 1.4), phase: rand(0, 2 * .pi))
    }

    /// Light falling on the planet: pulses leaving the surface and bright sparks skimming it.
    /// Angle and strength 0...1, strongest first.
    func planetLights() -> [(th: Double, power: Double)] {
        var out: [(Double, Double)] = []
        for p in packets where p.travel < 0.4 {
            out.append((stalkAngle(p.stalk), p.energy * (1 - p.travel / 0.4)))
        }
        for g in grains where g.air && g.glow > 0.3 && g.r < base + 16 {
            out.append((g.th, g.glow * 0.35 * (1 - (g.r - base) / 16)))
        }
        return Array(out.sorted { $0.1 > $1.1 }.prefix(24)).map { (th: $0.0, power: $0.1) }
    }
    private var prior: [Double] = []
    var grains: [Grain] = []
    var clock: Double = 0
    /// Pointer and ring centre in the panel's coordinates; MilkDrop's flow leans toward the pointer.
    var cursor: CGPoint?
    var ringCenter: CGPoint = .zero
    private var flow = CGVector.zero
    /// Recent ridge shapes (newest last) for the afterimage; vizamp fades its canvas instead of clearing.
    var ghosts: [[CGPoint]] = []
    private var last: Double = 0
    private var lastKick: Double = 0
    private var rng = SystemRandomNumberGenerator()

    /// Geometry, in points from the ring centre.
    let base: Double = 51          // ridge baseline, hugging the 96 pt button
    let depth: Double = 24         // how far a full-scale band reaches outward
    let escape: Double = 135       // grains flying past this are recycled
    let fadeFrom: Double = 82      // and fade out from here

    func rand(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b, using: &rng) }

    /// Advances the smoothed levels, band heat and grains to `now`.
    func step(now: Double, spectrum: [Double], kick: Double) {
        let dt = last == 0 ? 1.0 / 45 : min(0.05, max(0.001, now - last))
        last = now
        clock += dt
        if levels.count != spectrum.count {
            levels = spectrum; prior = spectrum; heat = Array(repeating: 0, count: spectrum.count)
            push = Array(repeating: 0, count: spectrum.count)
        }
        // Ease toward the 30 Hz spectrum so the ridge moves at frame rate.
        // Contrast: the spectrum is auto-gained over 60 dB, so most bands sit mid-scale. Below 30 %
        // is floor; the rest is stretched so loud bands stand out as peaks, as in vizamp.
        let k = min(1, dt * 22)
        for i in levels.indices {
            let target = pow(max(0, (spectrum[i] - 0.3) / 0.7), 1.35)
            levels[i] += (target - levels[i]) * k
        }
        // Heat (vizamp Heat.advance): fast moves heat a band up in 25 ms, it cools over 280 ms.
        for i in levels.indices {
            let speed = abs(levels[i] - prior[i]) / dt
            let target = 1 - exp(-speed * 0.22)
            heat[i] += (target - heat[i]) * (1 - exp(-dt / (target > heat[i] ? 0.025 : 0.28)))
        }
        prior = levels

        advancePackets(dt)
        if grains.isEmpty { grains = (0..<260).map { _ in newGrain(rest: true) } }
        advanceGrains(dt)
        radiate(dt)

        // A kick bursts sparks out of the loudest part of the ridge.
        if kick > lastKick + 0.35, let peak = levels.indices.max(by: { levels[$0] < levels[$1] }) {
            explode(at: angle(ofBand: peak), strength: 0.55 + kick * 0.6)
        }
        lastKick = kick
    }

    // MARK: Geometry

    /// One lap, not a mirror: bass at 12 o'clock, rising clockwise through the mids to the highs,
    /// and the highs close back into the bass at the top.
    func angle(ofBand i: Int) -> Double {
        -.pi / 2 + Double(i) / Double(max(1, levels.count)) * 2 * .pi
    }

    /// Position around the ring, 0 at 12 o'clock to 1 just before it, clockwise.
    func lap(_ th: Double) -> Double {
        var a = (th + .pi / 2).truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return a / (2 * .pi)
    }

    /// Interpolates a per-band array around the lap, wrapping highest into lowest at the seam.
    private func sample(_ v: [Double], _ th: Double) -> Double {
        guard v.count > 1 else { return 0 }
        let x = lap(th) * Double(v.count)
        let i = Int(x) % v.count, f = x - Double(Int(x))
        return v[i] * (1 - f) + v[(i + 1) % v.count] * f
    }

    /// Level at an angle, 0...1.
    func level(at th: Double) -> Double { sample(levels, th) }

    func heat(at th: Double) -> Double { sample(heat, th) }

    /// The ridge's radius at an angle, plus any kick from pulses that just hit it.
    func surface(_ th: Double) -> Double {
        base + pow(max(0, min(1, level(at: th))), 0.85) * depth + sample(push, th) * depth * 0.55
    }

    private func band(at th: Double) -> Int { min(levels.count - 1, Int(lap(th) * Double(levels.count))) }

    /// Spawns, moves and lands pulses. A stalk fires when its band jumps, and also at a rate set by
    /// its loudness, so loud stalks keep pulsing; landing pushes the ridge out, heats it, throws sparks.
    private func advancePackets(_ dt: Double) {
        guard !levels.isEmpty else { return }
        for i in push.indices { push[i] *= exp(-dt / 0.15) }
        for i in 0..<Self.stalks {
            let th = stalkAngle(i), lv = level(at: th)
            let rise = lv - stalkPrior[i]
            stalkPrior[i] = lv
            stalkCooldown[i] -= dt
            guard stalkCooldown[i] <= 0, lv > 0.08 else { continue }
            let onset = rise > 0.06
            if onset || rand(0, 1) < lv * 1.6 * dt {
                packets.append(Packet(stalk: i, travel: 0, speed: rand(5, 8), energy: min(1, (onset ? rise * 5 : 0) + lv * 0.5)))
                stalkCooldown[i] = rand(0.1, 0.18)
            }
        }
        var landed: [Packet] = []
        for k in packets.indices.reversed() {
            packets[k].travel += dt * packets[k].speed
            if packets[k].travel >= 1 { landed.append(packets[k]); packets.remove(at: k) }
        }
        for p in landed {
            let th = stalkAngle(p.stalk), b = band(at: th)
            push[b] = min(0.9, push[b] + p.energy * 0.6)
            heat[b] = min(1, heat[b] + p.energy * 0.5)
            hit(at: th, energy: p.energy)
        }
        if packets.count > 120 { packets.removeFirst(packets.count - 120) }
    }

    /// A few sparks knocked off the ridge where a pulse lands.
    private func hit(at th: Double, energy: Double) {
        let near = grains.indices.filter { !grains[$0].air && angularDistance(grains[$0].th, th) < 0.12 }.prefix(2 + Int(energy * 4))
        for i in near {
            grains[i].vr = rand(50, 100) * (0.6 + energy)
            grains[i].vt = rand(-25, 25)
            grains[i].air = true
            grains[i].spark = rand(0.15, 0.3)
            grains[i].glow = 1
        }
    }

    // MARK: Grains (vizamp Sand, in polar form: outward is "up", gravity pulls to the button)

    private func newGrain(rest: Bool) -> Grain {
        let th = rand(-.pi, .pi), size = rand(0.9, 1.7)
        let r = surface(th) + size / 2 + (rest ? 0 : rand(1, 3))
        return Grain(th: th, r: r, vr: rest ? 0 : rand(4, 12), vt: rest ? 0 : rand(-8, 8), air: !rest, size: size,
                     age: rest ? rand(0, 1) : 0, life: rand(7.5, 22), spark: 0, ground: surface(th),
                     restitution: rand(0.35, 0.65), drag: rand(0.25, 0.6), px: 0, py: 0, drawn: false,
                     glow: 0)
    }

    private func advanceGrains(_ dt: Double) {
        for i in grains.indices {
            var g = grains[i]
            g.age += dt
            g.spark = max(0, g.spark - dt)
            // Recycle only grains that are resting and already dark: nothing pops in or out.
            if (g.age > g.life && !g.air && g.glow < 0.03) || !g.r.isFinite { grains[i] = newGrain(rest: true); continue }
            // The button is a planet: pull grows toward it (inverse square, ~120 pt/s² at the surface).
            let gravity = 120 * pow(base / max(base * 0.8, g.r), 2)
            if g.air {
                g.glow *= exp(-dt / 2.5)                              // a flying spark cools slowly
            } else {
                let target = floorFade(level(at: g.th)) * 0.45
                g.glow += (target - g.glow) * (1 - exp(-dt / (target > g.glow ? 0.15 : 1.2)))
            }
            let ground = surface(g.th)
            let rising = (ground - g.ground) / dt                 // outward speed of the ridge here
            if !g.air {
                if rising > 7 {
                    let kick = min(110, rising * 1.8 + 8)
                    g.air = true; g.vr = kick; g.vt = rand(-0.18, 0.18) * kick
                    g.glow = max(g.glow, 0.85)
                } else if g.ground - ground > 0.45 {
                    g.air = true; g.vr = 0
                } else {
                    g.r = ground + g.size / 2
                }
            }
            if g.air {
                g.vt *= exp(-g.drag * dt)
                g.vr = max(-72, g.vr - gravity * dt)
                g.r += g.vr * dt
                g.th += g.vt * dt / max(20, g.r)
                if g.r > escape { grains[i] = newGrain(rest: true); continue }
                let land = surface(g.th) + g.size / 2
                if g.r <= land, g.vr < rising {
                    g.r = land
                    g.vr = -g.vr * g.restitution
                    g.vt *= 0.78
                    if abs(g.vr - rising) < 9 { g.air = false; g.vr = 0 }
                }
            }
            g.ground = surface(g.th)
            grains[i] = g
        }
    }

    private func explode(at th: Double, strength: Double) {
        let nearest = grains.indices.sorted { angularDistance(grains[$0].th, th) < angularDistance(grains[$1].th, th) }
        for i in nearest.prefix(14 + Int(strength * 10)) {
            grains[i].vr = rand(80, 160) * min(1.4, strength)
            grains[i].vt = rand(-50, 50)
            grains[i].air = true
            grains[i].spark = rand(0.2, 0.34)
            grains[i].glow = 1
        }
    }

    /// Hot bands shed embers straight outward (vizamp's radiate), a few per second per hot zone.
    private var radiateClock = 0.0
    private func radiate(_ dt: Double) {
        radiateClock -= dt
        guard radiateClock <= 0, !levels.isEmpty else { return }
        radiateClock = rand(0.04, 0.09)
        let hot = levels.indices.filter { heat[$0] > 0.25 && levels[$0] > 0.15 }
        guard let band = hot.randomElement(), let i = grains.indices.filter({ !grains[$0].air }).randomElement() else { return }
        let th = angle(ofBand: band) + rand(-0.06, 0.06)
        grains[i].th = th
        grains[i].r = surface(th) + 0.5
        grains[i].vr = rand(60, 130) * (0.5 + heat[band])
        grains[i].vt = rand(-6, 6)
        grains[i].air = true
        grains[i].spark = rand(0.15, 0.3)
        grains[i].glow = 0.9
        grains[i].drawn = false
    }

    private func floorFade(_ v: Double) -> Double { let t = min(1, max(0, v / 0.09)); return t * t * (3 - 2 * t) }

    // MARK: MilkDrop feedback

    /// MilkDrop's core trick: each frame redraws the previous one slightly zoomed (radial expansion only), faded,
    /// then adds the new shapes, so everything leaves a swirling tunnel of echoes. Kept at 1x
    /// (soft, like MilkDrop) in an offscreen bitmap the size of the visualizer.
    private var feedback: CGContext?
    private var feedbackSize = 0

    func feedbackFrame(ridge: [CGPoint], size: CGSize, hot: Color, heat: Color) -> CGImage? {
        let n = Int((size.width / 2).rounded())                 // half resolution: soft like MilkDrop, 4x cheaper
        if feedback == nil || feedbackSize != n {
            feedback = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            feedbackSize = n
        }
        guard let fb = feedback else { return nil }
        let w = CGFloat(n), c = CGPoint(x: w / 2, y: w / 2)
        let bass = levels.prefix(max(1, levels.count / 5)).reduce(0, +) / Double(max(1, levels.count / 5))

        // 1. The previous frame, expanded radially from the centre, faded.
        let prev = fb.makeImage()
        fb.clear(CGRect(x: 0, y: 0, width: w, height: w))
        // Flow: lean the expansion toward the pointer (eased), relax to purely radial without it.
        var target = CGVector.zero
        if let p = cursor {
            let dx = p.x - ringCenter.x, dy = p.y - ringCenter.y, d = max(1, hypot(dx, dy))
            let m = min(1, d / 110)
            target = CGVector(dx: dx / d * m, dy: dy / d * m)
        }
        flow.dx += (target.dx - flow.dx) * 0.08
        flow.dy += (target.dy - flow.dy) * 0.08
        if let prev {
            fb.saveGState()
            fb.interpolationQuality = .low
            let shift = 2.4 * w / size.width                     // up to 2.4 pt a frame, in buffer pixels
            fb.translateBy(x: c.x + flow.dx * shift, y: c.y - flow.dy * shift)   // CG y is flipped
            let zoom = CGFloat(1.012 + bass * 0.03)
            fb.scaleBy(x: zoom, y: zoom)
            fb.translateBy(x: -c.x, y: -c.y)
            fb.setAlpha(0.9)
            fb.draw(prev, in: CGRect(x: 0, y: 0, width: w, height: w))
            fb.restoreGState()
        }

        // 2. This frame's ridge and sparks, added as light, colours drifting between the palette pair.
        fb.setBlendMode(.plusLighter)
        let mix = 0.5 + 0.5 * sin(clock * 0.6)
        let a = NSColor(hot).usingColorSpace(.sRGB) ?? .systemPink, b = NSColor(heat).usingColorSpace(.sRGB) ?? .orange
        let ink = CGColor(srgbRed: a.redComponent * (1 - mix) + b.redComponent * mix,
                          green: a.greenComponent * (1 - mix) + b.greenComponent * mix,
                          blue: a.blueComponent * (1 - mix) + b.blueComponent * mix, alpha: 1)
        let k = w / size.width                                   // view points -> buffer pixels
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * k, y: w - p.y * k) }   // CG's origin is bottom-left
        if let first = ridge.first {
            fb.beginPath(); fb.move(to: flip(first))
            for p in ridge.dropFirst() { fb.addLine(to: flip(p)) }
            fb.setStrokeColor(ink.copy(alpha: 0.18 + bass * 0.5)!)
            fb.setLineWidth(1.4)
            fb.strokePath()
        }
        for g in grains where g.air && g.glow > 0.05 {
            let p = flip(CGPoint(x: size.width / 2 + cos(g.th) * g.r, y: size.height / 2 + sin(g.th) * g.r))
            fb.setFillColor(ink.copy(alpha: g.glow * 0.55)!)
            fb.fillEllipse(in: CGRect(x: p.x - 0.8, y: p.y - 0.8, width: 1.6, height: 1.6))
        }
        // 3. Round vignette inside the loop: echoes fade before the square edge, never a hard cut.
        fb.setBlendMode(.destinationIn)
        let vignette = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0),
        ] as CFArray, locations: [0, 0.55, 1])!
        fb.drawRadialGradient(vignette, startCenter: c, startRadius: 0, endCenter: c, endRadius: w / 2, options: [])
        fb.setBlendMode(.normal)
        return fb.makeImage()
    }

    private func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
        return min(d, 2 * .pi - d)
    }
}

/// vizamp's dark heat palette: ember → orange → cream → ice → lilac.
enum Heat {
    static let stops: [(Double, Double, Double)] = [(0.38, 0.055, 0.025), (0.91, 0.24, 0.07), (1, 0.64, 0.24), (1, 0.93, 0.78), (0.69, 0.84, 1), (0.94, 0.76, 1)]
    static func color(_ heat: Double) -> Color {
        if heat > 0.8 {
            let t = min(1, (heat - 0.8) / 0.2), a = stops[4], b = stops[5]
            return Color(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t)
        }
        let at = max(0, min(1, heat / 0.8)) * 4, i = min(3, Int(at)), f = at - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }
}

/// The ring itself.
struct RingVisualizer: View {
    @ObservedObject var engine: Engine
    private let sim = RingSim.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45, paused: !engine.enabled && !engine.afterglow)) { tl in
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                if !engine.enabled { drawIdle(ctx, c) }
                guard engine.enabled || engine.afterglow else { return }
                // Switched off: keep simulating with silence so whatever is in flight falls back.
                let input = engine.enabled ? engine.spectrum : Array(repeating: 0, count: max(1, engine.spectrum.count))
                sim.step(now: tl.date.timeIntervalSinceReferenceDate, spectrum: input, kick: engine.enabled ? engine.kickPulse : 0)
                draw(ctx, c)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func pt(_ c: CGPoint, _ th: Double, _ r: Double) -> CGPoint {
        CGPoint(x: c.x + cos(th) * r, y: c.y + sin(th) * r)
    }

    private func floorFade(_ v: Double) -> Double { let t = min(1, max(0, v / 0.09)); return t * t * (3 - 2 * t) }

    private func drawIdle(_ ctx: GraphicsContext, _ c: CGPoint) {
        for i in 0..<48 {
            let th = Double(i) / 48 * 2 * .pi
            var p = Path(); p.move(to: pt(c, th, 54)); p.addLine(to: pt(c, th, 59))
            ctx.stroke(p, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }

    private func draw(_ ctx: GraphicsContext, _ c: CGPoint) {
        let steps = 120
        let angles = (0...steps).map { -Double.pi / 2 + Double($0) / Double(steps) * 2 * .pi }
        let ridge = angles.map { pt(c, $0, sim.surface($0)) }

        // Stars: outside the MilkDrop loop so they never smear; twinkle and drift around the planet.
        let starSpin = sim.clock * 0.006
        for s in sim.stars {
            let x = s.x * cos(starSpin) - s.y * sin(starSpin), y = s.x * sin(starSpin) + s.y * cos(starSpin)
            let p = CGPoint(x: c.x + x * c.x, y: c.y + y * c.y)
            let d = hypot(p.x - c.x, p.y - c.y)
            guard d > sim.base + 4 else { continue }
            let edge = max(0, min(1, (c.x - d) / 30))            // fade toward the square's edge
            let a = (0.25 + 0.25 * sin(sim.clock * 1.3 + s.phase)) * edge
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - s.size / 2, y: p.y - s.size / 2, width: s.size, height: s.size)), with: .color(.white.opacity(a)))
        }

        // MilkDrop layer underneath: echoes of past frames expanding outward.
        if let echo = sim.feedbackFrame(ridge: ridge, size: CGSize(width: c.x * 2, height: c.y * 2), hot: Theme.hot, heat: Theme.heat) {
            ctx.draw(Image(decorative: echo, scale: 1), in: CGRect(x: 0, y: 0, width: c.x * 2, height: c.y * 2))
        }

        // Wash between the baseline and the ridge.
        var wash = Path()
        wash.addLines(ridge); wash.closeSubpath()
        wash.addEllipse(in: CGRect(x: c.x - sim.base, y: c.y - sim.base, width: sim.base * 2, height: sim.base * 2))
        ctx.fill(wash, with: .color(Theme.hot.opacity(0.10)), style: FillStyle(eoFill: true))

        // Stalks: radial columns from the baseline to the ridge, swaying at band-dependent rates.
        for i in 0..<48 {
            let th = -Double.pi / 2 + Double(i) / 48 * 2 * .pi
            let lv = sim.level(at: th)
            let tip = sim.surface(th), rise = tip - sim.base
            guard rise > 0.4 else { continue }
            let fraction = sim.lap(th)
            let rate = 0.6 * pow(45 * pow(10000.0 / 45, fraction) / 45, 0.32)
            let sway = sin(sim.clock * .pi * 2 * rate + Double(i) * 2.39996323) * min(1.1, rise * 0.14) / sim.base
            var p = Path()
            p.move(to: pt(c, th, sim.base))
            p.addCurve(to: pt(c, th, tip), control1: pt(c, th + sway * 0.65, sim.base + rise * 0.35), control2: pt(c, th - sway, sim.base + rise * 0.75))
            ctx.stroke(p, with: .color(Theme.hot.opacity(floorFade(lv) * 0.45)), lineWidth: 1.5)
        }

        // Pulses racing up the stalks: white-hot throbbing dots with a short tail.
        for p in sim.packets {
            let th = sim.stalkAngle(p.stalk)
            let tip = sim.surface(th)
            let r = sim.base + (tip - sim.base) * p.travel
            let tailR = max(sim.base, r - 9 * p.speed / 6)
            let head = pt(c, th, r), tail = pt(c, th, tailR)
            let throb = 0.75 + 0.25 * sin(sim.clock * 40 + Double(p.stalk))
            let color = Heat.color(min(1, 0.55 + p.energy * 0.45))
            var streak = Path(); streak.move(to: tail); streak.addLine(to: head)
            ctx.stroke(streak, with: .linearGradient(Gradient(colors: [color.opacity(0), color.opacity(0.8 * throb)]), startPoint: tail, endPoint: head),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            let d = 2.2 + 1.6 * p.energy * throb
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - d / 2, y: head.y - d / 2, width: d, height: d)), with: .color(.white.opacity(0.95 * throb)))
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - d, y: head.y - d, width: d * 2, height: d * 2)), with: .color(color.opacity(0.3 * throb)))
        }

        // Motion blur on the ridge: the last frames' shapes, fainter with age.
        for (k, ghost) in sim.ghosts.enumerated() where ghost.count == ridge.count {
            let age = Double(sim.ghosts.count - k)                // 1 = previous frame
            var p = Path(); p.addLines(ghost); p.closeSubpath()
            ctx.stroke(p, with: .color(Heat.color(0.45).opacity(0.22 / age)), style: StrokeStyle(lineWidth: 2.2 + age * 0.6, lineCap: .round, lineJoin: .round))
        }
        sim.ghosts.append(ridge)
        if sim.ghosts.count > 4 { sim.ghosts.removeFirst() }

        // The ridge line, each segment in its band's heat colour.
        for j in 1..<ridge.count {
            let th = (angles[j - 1] + angles[j]) / 2
            let lv = sim.level(at: th), h = sim.heat(at: th)
            var seg = Path(); seg.move(to: ridge[j - 1]); seg.addLine(to: ridge[j])
            let alpha = floorFade(lv) * (0.55 + 0.45 * min(1, h / 0.65))
            ctx.stroke(seg, with: .color(Heat.color(0.25 + h * 0.9).opacity(alpha)), style: StrokeStyle(lineWidth: 1.6 + h * 1.4, lineCap: .round))
        }

        // Grains and sparks, drawn as short streaks along their motion.
        for i in sim.grains.indices {
            let g = sim.grains[i]
            let p = pt(c, g.th, g.r)
            let lv = sim.level(at: g.th)
            let color = g.spark > 0 ? Heat.color(min(0.7, 0.35 + g.spark)) : Heat.color(0.3 + sim.heat(at: g.th) * 0.8)
            let visibility = max(g.spark > 0 ? 0.9 * min(1, g.spark / 0.12) : 0, g.glow)
            _ = lv
            let fade = min(1, g.age / 0.15) * max(0, min(1, (sim.escape - g.r) / (sim.escape - sim.fadeFrom)))
            let size = g.size + (g.spark > 0 ? 0.6 : 0)
            // Motion blur: a streak back along the velocity (radial + tangential) over ~90 ms,
            // transparent at the tail, full colour at the head.
            let blur = 0.09
            let tail = pt(c, g.th - g.vt * blur / max(20, g.r), g.r - g.vr * blur)
            let length = hypot(p.x - tail.x, p.y - tail.y)
            if g.air, length > 1.2 {
                var s = Path(); s.move(to: tail); s.addLine(to: p)
                let alpha = visibility * fade
                ctx.stroke(s, with: .linearGradient(Gradient(colors: [color.opacity(0), color.opacity(alpha * 0.55), color.opacity(alpha)]),
                                                     startPoint: tail, endPoint: p),
                           style: StrokeStyle(lineWidth: size, lineCap: .round))
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)), with: .color(color.opacity(visibility * fade)))
            }
            sim.grains[i].px = p.x; sim.grains[i].py = p.y; sim.grains[i].drawn = true
        }
    }
}
