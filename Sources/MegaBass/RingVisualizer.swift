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
    }

    var levels: [Double] = []
    var heat: [Double] = []
    private var prior: [Double] = []
    var grains: [Grain] = []
    var clock: Double = 0
    private var last: Double = 0
    private var lastKick: Double = 0
    private var rng = SystemRandomNumberGenerator()

    /// Geometry, in points from the ring centre.
    let base: Double = 57          // ridge baseline, just outside the 96 pt button
    let depth: Double = 23         // how far a full-scale band reaches outward
    let outer: Double = 82         // grains stay inside the frame

    func rand(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b, using: &rng) }

    /// Advances the smoothed levels, band heat and grains to `now`.
    func step(now: Double, spectrum: [Double], kick: Double) {
        let dt = last == 0 ? 1.0 / 45 : min(0.05, max(0.001, now - last))
        last = now
        clock += dt
        if levels.count != spectrum.count {
            levels = spectrum; prior = spectrum; heat = Array(repeating: 0, count: spectrum.count)
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

        if grains.isEmpty { grains = (0..<140).map { _ in newGrain(rest: true) } }
        advanceGrains(dt)

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

    /// The ridge's radius at an angle.
    func surface(_ th: Double) -> Double { base + pow(max(0, min(1, level(at: th))), 0.85) * depth }

    // MARK: Grains (vizamp Sand, in polar form: outward is "up", gravity pulls to the button)

    private func newGrain(rest: Bool) -> Grain {
        let th = rand(-.pi, .pi), size = rand(0.9, 1.7)
        let r = surface(th) + size / 2 + (rest ? 0 : rand(1, 3))
        return Grain(th: th, r: r, vr: rest ? 0 : rand(4, 12), vt: rest ? 0 : rand(-8, 8), air: !rest, size: size,
                     age: rest ? rand(0, 1) : 0, life: rand(7.5, 22), spark: 0, ground: surface(th),
                     restitution: rand(0.35, 0.65), drag: rand(0.45, 0.9), px: 0, py: 0, drawn: false)
    }

    private func advanceGrains(_ dt: Double) {
        let gravity = 155.0
        for i in grains.indices {
            var g = grains[i]
            g.age += dt
            g.spark = max(0, g.spark - dt)
            if g.age > g.life || !g.r.isFinite { grains[i] = newGrain(rest: false); continue }
            let ground = surface(g.th)
            let rising = (ground - g.ground) / dt                 // outward speed of the ridge here
            if !g.air {
                if rising > 7 {
                    let kick = min(65, rising * 1.1 + 4)
                    g.air = true; g.vr = kick / 1.5; g.vt = rand(-0.18, 0.18) * kick
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
                if g.r > outer { g.r = outer; g.vr = min(0, g.vr) }
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
        for i in nearest.prefix(6 + Int(strength * 4)) {
            grains[i].vr = (rand(28, 50) * min(1.4, strength)) / 1.5
            grains[i].vt = rand(-30, 30)
            grains[i].air = true
            grains[i].spark = rand(0.2, 0.34)
        }
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
        TimelineView(.animation(minimumInterval: 1.0 / 45, paused: !engine.enabled)) { tl in
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                guard engine.enabled else { drawIdle(ctx, c); return }
                sim.step(now: tl.date.timeIntervalSinceReferenceDate, spectrum: engine.spectrum, kick: engine.kickPulse)
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
            var p = Path(); p.move(to: pt(c, th, 60)); p.addLine(to: pt(c, th, 65))
            ctx.stroke(p, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }

    private func draw(_ ctx: GraphicsContext, _ c: CGPoint) {
        let steps = 120
        let angles = (0...steps).map { -Double.pi / 2 + Double($0) / Double(steps) * 2 * .pi }
        let ridge = angles.map { pt(c, $0, sim.surface($0)) }

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
            let visibility = g.spark > 0 ? 0.9 * min(1, g.spark / 0.12) : floorFade(lv) * (g.air ? 0.85 : 0.4)
            let fade = min(1, g.age / 0.15)
            let size = g.size + (g.spark > 0 ? 0.6 : 0)
            if g.drawn, hypot(p.x - g.px, p.y - g.py) > 0.3, hypot(p.x - g.px, p.y - g.py) < 12 {
                var s = Path(); s.move(to: CGPoint(x: g.px, y: g.py)); s.addLine(to: p)
                ctx.stroke(s, with: .color(color.opacity(visibility * fade)), style: StrokeStyle(lineWidth: size, lineCap: .round))
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)), with: .color(color.opacity(visibility * fade)))
            }
            sim.grains[i].px = p.x; sim.grains[i].py = p.y; sim.grains[i].drawn = true
        }
    }
}
