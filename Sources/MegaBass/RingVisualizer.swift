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
        /// Flung into orbit: near circular speed, tiny drag, so it circles and decays slowly.
        var orbiter = false
    }

    var levels: [Double] = []
    var heat: [Double] = []
    /// Outward kick on the ridge from arriving pulses, per band; springs back in ~150 ms.
    var push: [Double] = []
    /// Hot metal: temperature per band, built by hard and sustained hits, cooling over ~1.6 s.
    var temp: [Double] = []
    private var rawPrior: [Double] = []
    /// Tiny sparkles from mega hits (silence to full in one step): fast, short-lived streaks.
    struct Sparkle { var x: Double; var y: Double; var vx: Double; var vy: Double; var life: Double; var age: Double; var size: Double }
    var sparkles: [Sparkle] = []

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
        for p in prominences {
            let age = clock - p.born
            if age < 0.6 { out.append((p.th, p.power * 0.8 * (1 - age / 0.6))) }     // the blast lights the limb
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
            temp = Array(repeating: 0, count: spectrum.count)
            rawPrior = spectrum
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
        spawnProminences(dt)
        prior = levels

        advancePackets(dt)
        advanceMetal(dt, raw: spectrum)
        if grains.isEmpty { grains = (0..<260).map { _ in newGrain(rest: true) } }
        advanceGrains(dt)
        radiate(dt)

        // A kick bursts sparks out of the loudest part of the ridge; strong kicks fling a few into orbit.
        if kick > lastKick + 0.35, let peak = levels.indices.max(by: { levels[$0] < levels[$1] }) {
            explode(at: angle(ofBand: peak), strength: 0.55 + kick * 0.6)
            if kick > 0.6 { launchOrbiters(at: angle(ofBand: peak), count: 2 + Int(kick * 2)) }
        }
        orbitClock -= dt
        if orbitClock <= 0, let hot = levels.indices.filter({ heat[$0] > 0.5 }).randomElement() {
            launchOrbiters(at: angle(ofBand: hot), count: 1)
            orbitClock = rand(0.6, 1.6)
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

    // MARK: Prominences

    /// A solar prominence: a loop (or an open plume) of plasma blasting off the planet's limb where
    /// a band's level shoots up. White-hot at birth, it cools to orange and red and lingers ~2-4 s.
    struct Prominence { var th: Double; var span: Double; var born: Double; var power: Double; var height: Double; var seed: Double; var loop: Bool }
    var prominences: [Prominence] = []
    private var promCool: [Double] = []
    private var promGap = 0.0, promRef = 7.0

    /// How long a prominence lingers, seconds.
    static func linger(_ p: Prominence) -> Double { 1.6 + 2.2 * p.power }

    private func spawnProminences(_ dt: Double) {
        if promCool.count != levels.count { promCool = Array(repeating: 0, count: levels.count) }
        promGap -= dt
        // The fastest-rising loud band this frame, after a 1 s warm-up and at most one every 0.25 s.
        var best: (i: Int, v: Double)?
        for i in levels.indices {
            promCool[i] -= dt
            let v = (levels[i] - prior[i]) / dt                    // level per second, rising
            guard v > 7, levels[i] > 0.35, promCool[i] <= 0 else { continue }
            if best == nil || v > best!.v { best = (i, v) }
        }
        // Sudden means faster than this song's usual: the typical peak speed over ~8 s sets the bar.
        let surprise = best.map { $0.v > 1.3 * promRef } ?? false
        if let b = best { promRef += (b.v - promRef) * min(1, dt / 8) }
        if let b = best, surprise, clock > 1, promGap <= 0, prominences.count < 8 {
            let i = b.i
            for j in max(0, i - 2)...min(levels.count - 1, i + 2) { promCool[j] = max(promCool[j], j == i ? 1.4 : 0.7) }
            promGap = 0.25
            let power = min(1, (b.v - 7) / 10 + 0.3 * levels[i])
            prominences.append(Prominence(th: angle(ofBand: i), span: rand(0.22, 0.5), born: clock, power: power,
                                          height: rand(0.55, 1), seed: rand(0, 100), loop: rand(0, 1) < 0.7))
        }
        prominences.removeAll { clock - $0.born > Self.linger($0) }
    }

    /// Interpolates a per-band array around the lap, wrapping highest into lowest at the seam.
    func sample(_ v: [Double], _ th: Double) -> Double {
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
                g.glow *= exp(-dt / (g.orbiter ? 7 : 2.5))           // a flying spark cools slowly; orbiters slower
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
                // Orbital mechanics in polar form: gravity against the centrifugal term, angular
                // momentum conserved as the radius changes, light drag so orbits decay slowly.
                g.vt *= exp(-(g.orbiter ? g.drag * 0.12 : g.drag) * dt)
                g.vr += (g.vt * g.vt / max(20, g.r) - gravity) * dt
                g.vr = max(-120, min(160, g.vr))
                let rOld = g.r
                g.r += g.vr * dt
                g.vt *= rOld / max(20, g.r)
                g.th += g.vt * dt / max(20, g.r)
                if g.r > escape { grains[i] = newGrain(rest: true); continue }
                let land = surface(g.th) + g.size / 2
                if g.r <= land, g.vr < rising {
                    g.orbiter = false
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

    /// Heats the ridge where it's hit hard and long, lets it cool, makes superhot spans shed embers,
    /// and turns mega hits (a band jumping from near silence to near full) into tiny sparkles.
    private func advanceMetal(_ dt: Double, raw: [Double]) {
        guard temp.count == levels.count else { return }
        for i in temp.indices {
            let lv = levels[i]
            temp[i] += (lv * lv * 0.9 + push[i] * 0.5) * dt * 1.0      // steady 80 % ~ yellow-white, 60 % ~ orange
            temp[i] = min(1.2, temp[i] * exp(-dt / 1.6))
            // Superhot: embers, more the hotter.
            if temp[i] > 0.75, rand(0, 1) < (temp[i] - 0.75) * dt * 24,
               let g = grains.indices.filter({ !grains[$0].air }).randomElement() {
                let th = angle(ofBand: i) + rand(-0.05, 0.05)
                grains[g].th = th; grains[g].r = surface(th) + 0.5
                grains[g].vr = rand(55, 120); grains[g].vt = rand(-10, 10)
                grains[g].air = true; grains[g].spark = rand(0.2, 0.35); grains[g].glow = 1; grains[g].drawn = false
            }
            // Mega hit: silence to full in one step.
            let target = i < raw.count ? pow(max(0, (raw[i] - 0.3) / 0.7), 1.35) : 0
            if i < rawPrior.count, rawPrior[i] < 0.25, target - rawPrior[i] > 0.6 {
                let th = angle(ofBand: i), r0 = surface(th)
                for _ in 0..<18 {
                    let a = th + rand(-0.9, 0.9), sp = rand(80, 220)
                    sparkles.append(Sparkle(x: cos(th) * r0, y: sin(th) * r0, vx: cos(a) * sp, vy: sin(a) * sp,
                                            life: rand(0.15, 0.35), age: 0, size: rand(0.5, 1.0)))
                }
                temp[i] = min(1.2, temp[i] + 0.25)
            }
        }
        rawPrior = raw.map { pow(max(0, ($0 - 0.3) / 0.7), 1.35) }
        for k in sparkles.indices {
            sparkles[k].age += dt
            sparkles[k].x += sparkles[k].vx * dt; sparkles[k].y += sparkles[k].vy * dt
            sparkles[k].vx *= exp(-dt * 3); sparkles[k].vy *= exp(-dt * 3)
        }
        sparkles.removeAll { $0.age > $0.life }
        if sparkles.count > 300 { sparkles.removeFirst(sparkles.count - 300) }
    }

    func temperature(at th: Double) -> Double { sample(temp, th) }

    /// Extra-fast sparks put into orbit above the ridge: 0.95-1.05 x circular speed (bound but
    /// elliptical), random direction, tiny drag; they circle and spiral down over several seconds.
    private var orbitClock = 1.0
    private func launchOrbiters(at th: Double, count: Int) {
        let gm = 120 * base * base
        let free = grains.indices.filter { !grains[$0].air }.shuffled().prefix(count)
        for i in free {
            let r = rand(80, 98)
            let dir: Double = Bool.random() ? 1 : -1
            grains[i].th = th + rand(-0.15, 0.15)
            grains[i].r = r
            grains[i].vt = dir * sqrt(gm / r) * rand(0.95, 1.05)
            grains[i].vr = rand(-6, 6)
            grains[i].air = true
            grains[i].orbiter = true
            grains[i].drag = rand(0.35, 0.75)                         // x0.12 in flight: 0.04-0.09 /s
            grains[i].glow = 1
            grains[i].spark = rand(0.3, 0.5)
            grains[i].age = 0.2
            grains[i].life = 30
            grains[i].drawn = false
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

/// MB_PERF=1: average draw time per frame for each visual, printed every 2 s to stderr.
@MainActor
final class PerfMeter {
    static let shared = PerfMeter()
    static let enabled = ProcessInfo.processInfo.environment["MB_PERF"] != nil
    private var sums: [String: (Double, Int)] = [:]
    private var last = Date()

    func add(_ name: String, _ seconds: Double) {
        var e = sums[name] ?? (0, 0)
        e.0 += seconds; e.1 += 1
        sums[name] = e
        if Date().timeIntervalSince(last) >= 2 {
            let line = sums.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.2f", $0.value.0 / Double(max(1, $0.value.1)) * 1000)) ms x\($0.value.1 / 2)/s" }.joined(separator: "  ")
            FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
            sums.removeAll(); last = Date()
        }
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
struct RingVisualizer: View, Equatable {
    /// Read live inside the timeline; not observed, so engine meter updates don't force redraws.
    let engine: Engine
    var enabled = true
    var afterglow = false
    private let sim = RingSim.shared

    static func == (a: RingVisualizer, b: RingVisualizer) -> Bool { a.enabled == b.enabled && a.afterglow == b.afterglow }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45, paused: !enabled && !afterglow)) { tl in
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let perfStart = PerfMeter.enabled ? Date() : nil
                defer { if let p = perfStart { PerfMeter.shared.add("ring", Date().timeIntervalSince(p)) } }
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

    /// Prominences, additive: a wide soft glow, a mid band and a hot core that starts white (the
    /// hotspot) and cools along the blackbody ramp while the loop rises, drifts and fades.
    private func drawProminences(_ g: GraphicsContext, _ c: CGPoint) {
        for p in sim.prominences {
            let age = sim.clock - p.born, life = RingSim.linger(p)
            let grow = 1 - exp(-age / 0.12)                                  // the blast
            let fade = pow(max(0, 1 - age / life), 1.6)
            let temp = 0.3 + 0.7 * exp(-age / 0.9)                           // white-hot, cooling
            let h = sim.base * (0.3 + 0.6 * p.height * (0.4 + 0.6 * p.power)) * grow * (1 + 0.22 * age / life)
            let foot = sim.base - 3
            let wob = sin(sim.clock * 2.3 + p.seed) * 0.05
            var path = Path()
            if p.loop {
                let a0 = p.th - p.span / 2, a1 = p.th + p.span / 2
                path.move(to: pt(c, a0, foot))
                path.addCurve(to: pt(c, a1, foot),
                              control1: pt(c, p.th - p.span * 0.42 + wob, foot + h * 1.33),
                              control2: pt(c, p.th + p.span * 0.42 + wob, foot + h * 1.33))
            } else {
                let bend = (p.seed.truncatingRemainder(dividingBy: 2) - 1) * p.span
                path.move(to: pt(c, p.th, foot))
                path.addCurve(to: pt(c, p.th + bend * 0.9 + wob, foot + h * 1.25),
                              control1: pt(c, p.th + wob, foot + h * 0.5), control2: pt(c, p.th + bend * 0.4, foot + h))
            }
            let col = Self.blackbody(temp)
            g.stroke(path, with: .color(col.opacity(0.16 * fade)), style: StrokeStyle(lineWidth: 9 + 9 * p.power, lineCap: .round))
            g.stroke(path, with: .color(col.opacity(0.45 * fade)), style: StrokeStyle(lineWidth: 3 + 2.5 * p.power, lineCap: .round))
            g.stroke(path, with: .color(Self.blackbody(min(1, temp + 0.25)).opacity(0.85 * fade)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            if age < 0.25 {                                                   // the blast flash at the limb
                let f = 1 - age / 0.25, q = pt(c, p.th, sim.base), r = 6 + 14 * p.power
                g.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)),
                       with: .radialGradient(Gradient(colors: [Color.white.opacity(0.7 * f), col.opacity(0.3 * f), col.opacity(0)]),
                                             center: q, startRadius: 0, endRadius: r))
            }
        }
    }

    /// Metal glow by temperature: cherry, red, orange, yellow, white.
    static func blackbody(_ t: Double) -> Color {
        let stops: [(Double, Double, Double)] = [(0.35, 0.05, 0.04), (0.8, 0.12, 0.04), (1, 0.45, 0.08), (1, 0.85, 0.35), (1, 0.98, 0.92)]
        let x = max(0, min(1, t)) * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(x)), f = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
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
        // Hot metal too: each takes its band's temperature, hottest where it meets the ridge.
        var hotStalks = ctx
        hotStalks.blendMode = .plusLighter
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
            let tmp = sim.temperature(at: th)
            let a = max(floorFade(lv) * 0.35, min(0.9, tmp * 1.1))
            let foot = pt(c, th, sim.base), head = pt(c, th, tip)
            let heat = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Self.blackbody(tmp * 0.45).opacity(a * 0.35), Self.blackbody(tmp).opacity(a)]),
                startPoint: foot, endPoint: head)
            if tmp > 0.45 {
                hotStalks.stroke(p, with: .color(Self.blackbody(tmp).opacity(0.16 * min(1, tmp))), lineWidth: (1.2 + tmp * 2.2) * 3)
            }
            hotStalks.stroke(p, with: heat, lineWidth: 1.2 + tmp * 2.2)
        }

        drawProminences(hotStalks, c)

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

        // The ridge as hot metal: thickness and colour follow each span's temperature (blackbody:
        // cherry, red, orange, yellow, white), and it keeps glowing a moment after the hit.
        var bloom = ctx
        bloom.blendMode = .plusLighter
        for j in 1..<ridge.count {
            let th = (angles[j - 1] + angles[j]) / 2
            let lv = sim.level(at: th), tmp = sim.temperature(at: th)
            var seg = Path(); seg.move(to: ridge[j - 1]); seg.addLine(to: ridge[j])
            let alpha = max(floorFade(lv) * 0.6, min(1, tmp * 1.3))
            let col = Self.blackbody(tmp)
            if tmp > 0.35 {
                bloom.stroke(seg, with: .color(col.opacity(0.22 * min(1, tmp))), style: StrokeStyle(lineWidth: (1.4 + tmp * 4.6) * 3, lineCap: .round))
            }
            // Additive: light only adds, so cold (dark) metal never draws a dark seam over the glow.
            bloom.stroke(seg, with: .color(col.opacity(alpha)), style: StrokeStyle(lineWidth: 1.4 + tmp * 4.6, lineCap: .round))
        }
        // Tiny sparkles from mega hits: white-hot streaks.
        for s in sim.sparkles {
            let f = 1 - s.age / s.life
            let head = CGPoint(x: c.x + s.x, y: c.y + s.y)
            let tail = CGPoint(x: head.x - s.vx * 0.025, y: head.y - s.vy * 0.025)
            var p = Path(); p.move(to: tail); p.addLine(to: head)
            bloom.stroke(p, with: .linearGradient(Gradient(colors: [Color.white.opacity(0), Color(red: 1, green: 0.95, blue: 0.8).opacity(f)]), startPoint: tail, endPoint: head),
                         style: StrokeStyle(lineWidth: s.size, lineCap: .round))
        }

        // Grains and sparks, drawn as short streaks along their motion.
        for i in sim.grains.indices {
            let g = sim.grains[i]
            let p = pt(c, g.th, g.r)
            let lv = sim.level(at: g.th)
            let color = g.spark > 0 ? Heat.color(min(0.7, 0.35 + g.spark)) : Heat.color(0.3 + sim.heat(at: g.th) * 0.8)
            let visibility = max(g.spark > 0 ? 0.9 * min(1, g.spark / 0.12) : 0, g.glow)
            _ = lv
            let fadeStart = g.orbiter ? 118 : sim.fadeFrom
            let fade = min(1, g.age / 0.15) * max(0, min(1, (sim.escape - g.r) / (sim.escape - fadeStart)))
            let size = g.size + (g.spark > 0 ? 0.6 : 0) + (g.orbiter ? 0.5 : 0)
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
