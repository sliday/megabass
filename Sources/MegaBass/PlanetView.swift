import AppKit
import MegaBassCore
import SwiftUI

/// The planet's rotation: a heavy body. Its speed follows the song's intensity with slow inertia.
/// On every beat it headbangs: the top tips toward you on a damped spring (harder with Overdrive),
/// while the spin itself stays steady. Hovering turns the power icon to face you.
@MainActor
final class PlanetSpin {
    static let shared = PlanetSpin()
    var lon = 0.0              // icon longitude; 0 faces the camera
    var hover = false
    /// Angular speed (rad/s) and the blur it implies, for the renderer.
    private(set) var omega = 0.2
    private var nod = 0.0, nodV = 0.0, lastKick = 0.0
    private var last = 0.0
    private var intensity = SongIntensity()

    // Beat following: the tempo and grid come from the engine's TempoTracker.
    private(set) var bpm = 0.0
    /// The phase-locked headbang: nod (radians) and drop (points), and how hard it bangs now.
    private var headNod = 0.0, headBob = 0.0, bangAmp = 0.0
    /// The planet's own beat clock (0..<1 per two beats), eased toward the tracker's grid, and the
    /// tracker's confidence, smoothed: an unclear beat fades the headbang out instead of jerking.
    private var bangPhase = 0.0, sureness = 0.0
    /// Headbang body motion, applied to the whole planet system: sideways rock and a downward bob.
    private(set) var wobble = 0.0, bob = 0.0
    private var bobV = 0.0

    /// Advances the spin. `rate` is the planet's own base speed; `energy` the song's loudness;
    /// `kick` the kick pulse; `headbang` whether Overdrive is on; `beat` the tempo grid and `now`
    /// the time in its base (`Clock`). Returns the angle to draw.
    func advance(_ t: Double, on: Bool, rate: Double = 0.2, energy: Double = 0, kick: Double = 0, headbang: Bool = false,
                 beat: TempoTracker.Beat = .init(), now: Double = 0) -> Double {
        let dt = last == 0 ? 0 : min(0.1, t - last)
        last = t
        if !on {
            lon = 0; omega = rate; nod = 0; nodV = 0; wobble = 0; bob = 0; bobV = 0   // off: still, icon faces you
            headNod = 0; headBob = 0; bangAmp = 0
            return 0
        }
        if hover {
            let target = (lon / (2 * .pi)).rounded(.up) * 2 * .pi
            lon += (target - lon) * min(1, dt * 7)
            if abs(target - lon) < 0.002 { lon = target }
            omega = rate
            nod *= exp(-dt * 8); headNod *= exp(-dt * 8); headBob *= exp(-dt * 8)
            return lon
        }
        // Heavy: speed follows the song's overall intensity, 0.4-3x the base rate, over ~3 s.
        let target = rate * (0.4 + 2.6 * intensity.step(energy: energy, dt: dt))
        omega += (target - omega) * min(1, dt / 3)
        lon += omega * dt
        // Tempo from the audio (TempoTracker): beats and half-time "bangs" in speaker time. The head
        // follows the grid directly: fully down exactly on each bang (a quick swing down, a slower
        // rise), with a smaller dip on the beats between. Read 40 ms ahead: a frame reaches the
        // screen about that long after it is drawn.
        let loud = min(1, energy * 2.5)
        let hasTempo = beat.bpm > 0 && beat.confidence > 0.03
        bpm = hasTempo ? beat.bpm : 0
        var sway = 0.0
        // How sure the beat is (~1.5 s smoothing): below ~0.05 confidence the head stays still.
        let sure = hasTempo ? max(0, min(1, (beat.confidence - 0.05) / 0.08)) : 0
        sureness += (sure - sureness) * min(1, dt / 1.5)
        var ampTarget = loud > 0.08 ? (0.11 + 0.1 * loud) * (headbang ? 1.6 : 1) * sureness : 0
        if hasTempo {
            let p = beat.period
            // Own clock: run at the tracked tempo and ease toward the tracker's grid over ~0.3 s, so a
            // re-anchored or flipped grid never snaps the head; a big correction also eases the nod off.
            let target = ((now - beat.bangAt) / (2 * p)).truncatingRemainder(dividingBy: 1)
            var err = target - bangPhase
            err -= err.rounded()                                    // -0.5 ... 0.5
            if abs(err) > 0.2 { ampTarget *= 0.3 }
            bangPhase += dt / (2 * p) + err * min(1, dt * 3.3)
            bangPhase -= bangPhase.rounded(.down)
            let at = 0.04 / (2 * p)                                  // a frame reaches the screen ~40 ms later
            var u = bangPhase + at
            u -= u.rounded()                                         // -0.5 ... 0.5 of a bang period
            var v = 2 * (bangPhase + at)
            v -= v.rounded()                                         // -0.5 ... 0.5 of a beat
            let bang = Self.down(u * 2 * p, period: 2 * p), each = Self.down(v * p, period: p)
            bangAmp += (ampTarget - bangAmp) * min(1, dt / 0.6)
            headNod = bangAmp * bang
            headBob = bangAmp / 0.2 * (3.5 * bang + 1.2 * each)
            sway = sin(2 * .pi * bangPhase) * sureness              // left on one beat, right on the next
        } else {
            bangAmp += (0 - bangAmp) * min(1, dt / 0.6)
            headNod *= exp(-dt * 3); headBob *= exp(-dt * 3)
        }
        lastKick = kick
        nodV += (-70 * nod - 9 * nodV) * dt
        nod += nodV * dt
        // Bob: a quick dip on the beat, sprung back up. Rock: side to side across two beats.
        bobV += (-180 * bob - 16 * bobV) * dt
        bob += bobV * dt
        let rock = sway * 0.06 * loud
        wobble += (rock - wobble) * min(1, dt * 8)
        return lon
    }

    /// The headbang nod (radians): positive tips the planet's top toward you.
    var pitch: Double { max(-0.45, min(0.45, nod + headNod)) }
    /// How far the planet system drops (points, down positive).
    var drop: Double { bob + headBob }

    /// Headbang shape against time since the nearest grid point: 1 fully down on the beat, a quick
    /// swing down (~110 ms) and a slower rise (~240 ms).
    static func down(_ x: Double, period: Double) -> Double {
        var u = x.truncatingRemainder(dividingBy: period)
        if u < 0 { u += period }
        if u > period / 2 { u -= period }
        return u < 0 ? exp(-pow(u / 0.11, 2)) : exp(-pow(u / 0.24, 2))
    }
    /// How open the ring plane looks (minor/major axis), widening as the planet nods toward you.
    var ringOpen: Double { max(0.05, min(0.62, sin(0.2424 + pitch))) }

    /// How far the surface turns in one frame, as a fraction of a full turn (for motion blur).
    var blurTurn: Double { abs(omega) / 30 / (2 * .pi) }
}

/// The song's overall intensity, 0...1: loudness over ~2 s against the song's own quiet and loud
/// parts (a floor and a peak that adapt over ~30 s), scaled by absolute level so silence stays slow.
/// A steady song sits near the middle; its chorus pushes toward 1, a quiet verse toward 0.
struct SongIntensity {
    private(set) var value = 0.0
    private var smooth = 0.0, floor = 0.0, peak = 0.0, seeded = false

    mutating func step(energy e: Double, dt: Double) -> Double {
        smooth += (e - smooth) * min(1, dt / 2)
        if !seeded, smooth > 0.02 { floor = smooth; peak = smooth; seeded = true }
        peak = max(smooth, peak - dt * 0.008)
        floor = min(smooth, floor + dt * 0.008)
        let span = max(0.15, peak - floor)
        let rel = max(0, min(1, 0.5 + (smooth - (peak + floor) / 2) / span))
        value = min(1, smooth / 0.35) * (0.35 + 0.65 * rel)
        return value
    }
}

/// The power button as a small gas giant: banded surface in the station's palette that flows like
/// a rotating atmosphere, a drifting storm, sphere shading lit from the top-left, and an atmosphere
/// halo that flares on kicks. Dark and still when megabass is off.
struct PlanetView: View, Equatable {
    @Environment(\.planetPixelScale) private var pixelScale
    @Environment(\.planetEdge) private var edge

    /// An additive layer whose content fades to nothing before the canvas edge (see PlanetEdge).
    private func fadedGlow(_ ctx: GraphicsContext, size: CGSize) -> GraphicsContext {
        var g = ctx
        let rect = CGRect(origin: .zero, size: size)
        switch edge {
        case .radial:
            let c = CGPoint(x: size.width / 2, y: size.height / 2), lim = min(size.width, size.height) / 2
            g.clipToLayer { m in
                m.fill(Path(rect), with: .radialGradient(Gradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.62),
                                                                          .init(color: .white.opacity(0), location: 0.98)]),
                                                         center: c, startRadius: 0, endRadius: lim))
            }
        case .box:
            let fade = Gradient(stops: [.init(color: .white.opacity(0), location: 0), .init(color: .white, location: 0.16),
                                        .init(color: .white, location: 0.84), .init(color: .white.opacity(0), location: 1)])
            g.clipToLayer { m in m.fill(Path(rect), with: .linearGradient(fade, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))) }
            g.clipToLayer { m in m.fill(Path(rect), with: .linearGradient(fade, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))) }
        }
        g.blendMode = .plusLighter
        return g
    }
    /// Read live inside the timeline; not observed, so engine meter updates don't force redraws.
    let engine: Engine
    var radius: CGFloat = 48
    var style = PlanetStyle.from("megabass")
    /// Draw lit even when megabass is off (gallery).
    var alwaysOn = false
    /// On/off, passed in so the view redraws when it changes (and pauses its timeline when off).
    var enabled = true

    static func == (a: PlanetView, b: PlanetView) -> Bool {
        a.radius == b.radius && a.style == b.style && a.alwaysOn == b.alwaysOn && a.enabled == b.enabled
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !enabled && !alwaysOn)) { tl in
            Canvas { ctx, size in
                draw(ctx, size: size, t: tl.date.timeIntervalSinceReferenceDate)
            }
        }
        .allowsHitTesting(false)
    }

    private func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let x = NSColor(a).usingColorSpace(.sRGB) ?? .black, y = NSColor(b).usingColorSpace(.sRGB) ?? .black
        return Color(red: x.redComponent + (y.redComponent - x.redComponent) * t,
                     green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                     blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t)
    }

    /// The brighter of the palette pair (by luminance): the power icon's light.
    private func brightest(_ a: Color, _ b: Color) -> Color {
        func lum(_ c: Color) -> Double { let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray; return 0.299 * n.redComponent + 0.587 * n.greenComponent + 0.114 * n.blueComponent }
        return lum(a) >= lum(b) ? a : b
    }

    /// Overall loudness as sunlight: quiet passages dim the planet, loud ones bring full day.
    private func sunlight(on: Bool) -> Double {
        guard on, !alwaysOn else { return 1 }
        let e = OrbitSim.shared.energy
        let t = max(0, min(1, (e - 0.03) / 0.32))
        return 0.25 + 0.75 * t * t * (3 - 2 * t)
    }

    /// One frame: advance the orbits once, then draw the planet, cross-fading from the previous
    /// style for 1.2 s when the station or song changes.
    private func draw(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let perfStart = PerfMeter.enabled ? Date() : nil
        defer { if let p = perfStart { PerfMeter.shared.add("planet", Date().timeIntervalSince(p)) } }
        let on = engine.enabled || alwaysOn
        _ = WavePhase.shared.advance(t: t, hz: engine.hapticHz)          // rings pulse with the trackpad wave
        if !alwaysOn { OrbitSim.shared.addVoices(engine.takeVoices()) }
        OrbitSim.shared.step(t: t, kick: on ? engine.kickPulse : 0, levels: on ? RingSim.shared.levels : [], R: Double(radius), on: on,
                             now: Clock.now())
        // Headbang body motion: the whole system (planet, rings, moons) rocks and bobs as one.
        var ctx = ctx
        if !alwaysOn {
            let s = PlanetSpin.shared
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.translateBy(x: c.x, y: c.y + s.drop)
            ctx.rotate(by: .radians(s.wobble))
            ctx.translateBy(x: -c.x, y: -c.y)
        }
        guard !alwaysOn, let (from, p) = PlanetMorph.shared.update(to: style, t: t) else {
            drawPlanet(ctx, size: size, t: t, st: style)
            return
        }
        var old = ctx; old.opacity = 1 - p
        drawPlanet(old, size: size, t: t, st: from)
        var new = ctx; new.opacity = p
        drawPlanet(new, size: size, t: t, st: style)
    }

    private func drawPlanet(_ ctx: GraphicsContext, size: CGSize, t: Double, st: PlanetStyle) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = Double(radius)
        let on = engine.enabled || alwaysOn
        let kick = on ? engine.kickPulse : 0
        let disc = Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        let hot = on ? Theme.hot : Color(white: 0.22), heat = on ? Theme.heat : Color(white: 0.30)
        let deep = mix(hot, .black, 0.55)
        let atm = st.atmosphere

        // Rings (if this planet has them): the far half goes behind the planet.
        if st.rings { drawRings(ctx, c: c, R: R, front: false, color: heat, on: on, st: st) }
        drawMoons(ctx, c: c, R: R, front: false, color: heat, on: on, st: st)

        // Stars: light rays radiating from the core, slowly turning, longer with the bass, in a corona.
        if st.kind == .star {
            let tintStar = [0xFF5A3A, 0xFF9A3A, 0xFFD86A, 0xFFF4D6, 0xBFD8FF].map { Palettes.hex(UInt32($0)) }[st.starClass]
            let rays = fadedGlow(ctx, size: size)
            let bass = on ? OrbitSim.shared.groups[0] : 0.2
            let corona = R * 1.9
            rays.fill(Path(ellipseIn: CGRect(x: c.x - corona, y: c.y - corona, width: corona * 2, height: corona * 2)),
                      with: .radialGradient(Gradient(colors: [tintStar.opacity(0.5), tintStar.opacity(0.12), tintStar.opacity(0)]), center: c, startRadius: R * 0.9, endRadius: corona))
            let count = 18
            for k in 0..<count {
                let a = Double(k) / Double(count) * 2 * .pi + t * 0.05 + sin(Double(k) * 7.3) * 0.12
                let len = R * (1.3 + 0.35 * sin(t * 1.1 + Double(k) * 2.4) + bass * 0.7)
                let w = 0.09 + 0.04 * sin(Double(k) * 3.1)
                var ray = Path()
                ray.move(to: CGPoint(x: c.x + cos(a - w) * R * 0.85, y: c.y + sin(a - w) * R * 0.85))
                ray.addLine(to: CGPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len))
                ray.addLine(to: CGPoint(x: c.x + cos(a + w) * R * 0.85, y: c.y + sin(a + w) * R * 0.85))
                ray.closeSubpath()
                rays.fill(ray, with: .radialGradient(Gradient(colors: [tintStar.opacity(on ? 0.55 : 0.2), tintStar.opacity(0)]), center: c, startRadius: R * 0.85, endRadius: len))
            }
        }

        // Mirror ball: its facets throw beams of light through a haze. Each facet turns with the ball and
        // reflects the light (up left, in front), so the beams sweep, stretch and blink out as facets
        // pass the light; louder music and kicks brighten them.
        if st.kind == .disco {
            let glow = fadedGlow(ctx, size: size)
            let e = on ? min(1, OrbitSim.shared.energy * 2.2) : 0
            let haze = mix(heat, .white, 0.4), fogR = R * 2.3
            glow.fill(Path(ellipseIn: CGRect(x: c.x - fogR, y: c.y - fogR, width: fogR * 2, height: fogR * 2)),
                      with: .radialGradient(Gradient(colors: [haze.opacity(on ? 0.1 + 0.12 * e : 0.03), haze.opacity(0)]),
                                            center: c, startRadius: R * 0.8, endRadius: fogR))
            let L = (x: -0.45 / 1.0, y: -0.5 / 1.0, z: 0.74 / 1.0)
            let ln = sqrt(L.x * L.x + L.y * L.y + L.z * L.z)
            let l = (x: L.x / ln, y: L.y / ln, z: L.z / ln)
            var rng = PlanetStyle.SplitMix64(state: PlanetStyle.fnv1a(st.key + "facets"))
            let turn = PlanetSpin.shared.lon
            for _ in 0..<32 {
                let th = rng.range(-1, 1), a = rng.range(0, 2 * .pi) + turn, pick = rng.unit()
                let n = (x: cos(th) * sin(a), y: -sin(th), z: cos(th) * cos(a))
                let lit = n.x * l.x + n.y * l.y + n.z * l.z
                guard n.z > 0.05, lit > 0.2 else { continue }
                // The incoming light (-l) reflected about the facet normal.
                let r = (x: -l.x + 2 * lit * n.x, y: -l.y + 2 * lit * n.y)
                let flat = hypot(r.x, r.y)
                guard flat > 0.15 else { continue }
                let dir = (x: r.x / flat, y: r.y / flat)
                let start = CGPoint(x: c.x + n.x * R, y: c.y + n.y * R)
                let len = R * (0.7 + 1.5 * flat)
                let end = CGPoint(x: start.x + dir.x * len, y: start.y + dir.y * len)
                let w = R * 0.07 * (0.6 + flat)
                var beam = Path()
                beam.move(to: start)
                beam.addLine(to: CGPoint(x: end.x - dir.y * w, y: end.y + dir.x * w))
                beam.addLine(to: CGPoint(x: end.x + dir.y * w, y: end.y - dir.x * w))
                beam.closeSubpath()
                let col = pick < 0.5 ? Color.white : (pick < 0.75 ? hot : heat)
                let s = min(1, (lit - 0.2) * 1.6) * (on ? 0.4 + 0.45 * e + 0.35 * kick : 0.08)
                glow.fill(beam, with: .linearGradient(Gradient(colors: [col.opacity(s), col.opacity(0)]), startPoint: start, endPoint: end))
                let tip = CGPoint(x: start.x + dir.x * len * 0.7, y: start.y + dir.y * len * 0.7)
                var core = Path(); core.move(to: start); core.addLine(to: tip)
                glow.stroke(core, with: .linearGradient(Gradient(colors: [Color.white.opacity(min(1, s * 1.5)), Color.white.opacity(0)]),
                                                        startPoint: start, endPoint: tip), lineWidth: 0.7)
                let sr = 3 + 3 * s
                glow.fill(Path(ellipseIn: CGRect(x: end.x - sr, y: end.y - sr, width: sr * 2, height: sr * 2)),
                          with: .radialGradient(Gradient(colors: [col.opacity(s * 0.8), col.opacity(0)]), center: end, startRadius: 0, endRadius: sr))
            }
        }

        // Thin atmosphere: a tight bright shell on the limb plus two faint outer layers.
        if on && st.kind != .star {
            let r2 = R * 1.1
            let shell = Gradient(stops: [
                .init(color: heat.opacity(0), location: 0.96 / 1.1),
                .init(color: heat.opacity(min(1, (0.42 + 0.3 * kick) * atm * (0.45 + 0.55 * sunlight(on: on)))), location: 1.0 / 1.1),
                .init(color: hot.opacity(min(1, (0.1 + 0.15 * kick) * atm)), location: 1.04 / 1.1),
                .init(color: hot.opacity(0), location: 1),
            ])
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r2, y: c.y - r2, width: r2 * 2, height: r2 * 2)),
                     with: .radialGradient(shell, center: c, startRadius: 0, endRadius: r2))
            for (k, lr) in [R * 1.035, R * 1.07].enumerated() {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - lr, y: c.y - lr, width: lr * 2, height: lr * 2)),
                           with: .color(heat.opacity(k == 0 ? 0.16 : 0.08)), lineWidth: 0.6)
            }
        }

        // Surface: latitude bands with wavy edges, each flowing at its own speed.
        var surface = ctx
        surface.clip(to: disc)
        surface.fill(disc, with: .color(deep))
        // Rotation reads as a sphere: features live in latitude/longitude, so they move fast across
        // the middle and bunch up at the limbs. The surface and the power icon share one spin.
        var spin = PlanetSpin.shared.advance(t, on: on, rate: st.spin, energy: OrbitSim.shared.energy,
                                             kick: kick, headbang: engine.overdrive > 0, beat: engine.tempo, now: Clock.now())
        // The eyeball does not spin: it looks (at the pointer, or around).
        let eye = st.kind == .eyeball
        if eye { EyeLook.shared.advance(t: t); spin = EyeLook.shared.lon }
        // The surface leans with the planet's axial tilt.
        surface.translateBy(x: c.x, y: c.y); surface.rotate(by: .radians(st.tilt)); surface.translateBy(x: -c.x, y: -c.y)

        let look = Self.colors(st.kind)
        func tint(_ col: Color) -> Color { on ? mix(col, hot, 0.15) : mix(col, Color(white: 0.25), 0.7) }

        // Crisp fractal surface (see PlanetTexture); the vector look below is the fallback while it bakes.
        let textured: Bool
        if let tex = PlanetTextures.shared.texture(for: st, hot: Theme.hot, heat: Theme.heat),
           let img = PlanetTextures.shared.render(tex, radius: R, tilt: st.tilt, spin: spin, on: on,
                                                  rim: heat, grade: st.kind == .star || st.kind.isCurio || !on ? nil : (hot, heat),
                                                  flares: on ? RingSim.shared.planetLights() + impactLights(st) : [], flareColor: mix(heat, .white, 0.35),
                                                  icon: true, sun: Float(sunlight(on: on)), iconColor: brightest(hot, heat),
                                                  blur: eye ? 0 : Float(PlanetSpin.shared.blurTurn), pitch: PlanetSpin.shared.pitch + (eye ? EyeLook.shared.pitch : 0),
                                                  liquid: Float(0.45 - 1.2 * min(1, OrbitSim.shared.energy * 2.2) * (on ? 1 : 0.3)),   // quiet: a quarter full; loud: ~90 %
                                                  time: OrbitSim.shared.time,
                                                  wobble: Float(0.08 + 0.25 * min(1, OrbitSim.shared.energy * 2.2) + 0.3 * kick),
                                                  pixelScale: pixelScale) {
            var disc2 = ctx
            disc2.clip(to: disc)
            disc2.draw(Image(decorative: img, scale: 2), in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
            textured = true
        } else {
            textured = false
        }

        if textured {
        } else if st.kind == .gasGiant || st.kind == .toxic {
            // Banded worlds: wavy latitude bands (station palette for gas giants, sulphur for toxic).
            let tones = st.kind == .gasGiant
                ? [deep, hot, mix(hot, heat, 0.5), heat, mix(heat, .white, 0.25), mix(hot, heat, 0.3)]
                : [tint(look.base), tint(look.land), tint(look.land2), tint(look.base)]
            let bands = st.bands
            let palette = (0..<bands).map { i in tones[(i * 5 + bands * 3 + Int(st.detail)) % tones.count] }
            for i in 0..<bands {
                let y0 = -R + Double(i) * 2 * R / Double(bands)
                let ring = sqrt(max(1, R * R - y0 * y0))
                var p = Path()
                let steps = 28
                for s in 0...steps {
                    let x = -R + Double(s) / Double(steps) * 2 * R
                    let lon = asin(max(-1, min(1, x / ring))) - spin * (1 + 0.04 * Double(i))   // turns with the icon
                    let y = y0 + sin(lon * 3 + Double(i) * 1.7) * R * st.wave + sin(lon * st.detail - Double(i)) * R * st.wave * 0.35
                    if s == 0 { p.move(to: CGPoint(x: c.x + x, y: c.y + y)) } else { p.addLine(to: CGPoint(x: c.x + x, y: c.y + y)) }
                }
                p.addLine(to: CGPoint(x: c.x + R * 1.3, y: c.y + R * 1.3)); p.addLine(to: CGPoint(x: c.x - R * 1.3, y: c.y + R * 1.3)); p.closeSubpath()
                surface.fill(p, with: .color(palette[i].opacity(0.9)))
            }
            for storm in st.storms {
                let lon = (spin + storm.lon).truncatingRemainder(dividingBy: 2 * .pi)
                guard cos(lon) > 0 else { continue }
                let ly = storm.lat * R, ring = sqrt(max(1, R * R - ly * ly))
                let sx = sin(lon) * ring * 0.95, w = R * storm.size * cos(lon), h = R * storm.size * 0.42
                surface.fill(Path(ellipseIn: CGRect(x: c.x + sx - w / 2, y: c.y + ly - h / 2, width: w, height: h)),
                             with: .color(mix(st.kind == .toxic ? tint(look.land2) : heat, .white, 0.35).opacity(0.75 * cos(lon))))
            }
        } else {
            // Rocky worlds: base, then features projected on the turning sphere.
            surface.fill(Path(CGRect(x: c.x - R * 1.3, y: c.y - R * 1.3, width: R * 2.6, height: R * 2.6)), with: .color(tint(look.base)))
            func project(_ lat: Double, _ lon: Double, _ size: Double, faster: Double = 1, stretch: Double = 1) -> (CGRect, Double)? {
                let l = lon + spin * faster
                let vis = cos(lat) * cos(l)
                guard vis > -0.05 else { return nil }
                let x = c.x + R * cos(lat) * sin(l), y = c.y - R * sin(lat)
                let w = 2 * R * size * max(0.08, cos(l)) * stretch, h = 2 * R * size * max(0.12, cos(lat)) / stretch
                return (CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h), min(1, max(0, vis * 3)))
            }
            for b in st.blobs {
                guard let (r, a) = project(b.lat, b.lon, b.size) else { continue }
                surface.fill(Path(ellipseIn: r), with: .color(tint(mix(look.land, look.land2, b.shade)).opacity(0.95 * a)))
            }
            for cr in st.craters {
                guard let (r, a) = project(cr.lat, cr.lon, cr.size) else { continue }
                surface.fill(Path(ellipseIn: r), with: .color(.black.opacity(0.28 * a)))
                surface.stroke(Path(ellipseIn: r.offsetBy(dx: -0.6, dy: -0.6)), with: .color(.white.opacity(0.18 * a)), lineWidth: 0.8)
            }
            if !st.cracks.isEmpty {
                var cracks = surface
                if look.glow != nil && on { cracks.blendMode = .plusLighter }
                for line in st.cracks {
                    var path = Path(); var started = false
                    for pt in line {
                        let l = pt.lon + spin
                        if cos(pt.lat) * cos(l) <= 0 { started = false; continue }
                        let q = CGPoint(x: c.x + R * cos(pt.lat) * sin(l), y: c.y - R * sin(pt.lat))
                        if started { path.addLine(to: q) } else { path.move(to: q); started = true }
                    }
                    let col = look.glow.map { on ? $0 : Color(white: 0.4) } ?? mix(look.land, .black, 0.3)
                    cracks.stroke(path, with: .color(col.opacity(0.85)), style: StrokeStyle(lineWidth: look.glow == nil ? 0.8 : 1.6, lineCap: .round, lineJoin: .round))
                    if look.glow != nil && on {
                        cracks.stroke(path, with: .color(col.opacity(0.25)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            if st.caps > 0 && st.kind != .ice {
                let edge = R * cos(st.caps * 1.4)
                for top in [true, false] {
                    var cap = Path()
                    let y0 = top ? c.y - edge : c.y + edge
                    cap.move(to: CGPoint(x: c.x - R, y: y0))
                    for k in 0...16 {
                        let x = -R + Double(k) / 16 * 2 * R
                        cap.addLine(to: CGPoint(x: c.x + x, y: y0 + sin(x / R * 5 + spin * 2) * R * 0.03))
                    }
                    cap.addLine(to: CGPoint(x: c.x + R, y: top ? c.y - R * 1.3 : c.y + R * 1.3))
                    cap.addLine(to: CGPoint(x: c.x - R, y: top ? c.y - R * 1.3 : c.y + R * 1.3)); cap.closeSubpath()
                    surface.fill(cap, with: .color(Color(white: 0.95).opacity(on ? 0.9 : 0.5)))
                }
            }
            for cl in st.clouds {
                // Clouds stretch into streaks along their latitude.
                guard let (r, a) = project(cl.lat, cl.lon, cl.size, faster: 1.25, stretch: 2.4) else { continue }
                surface.fill(Path(roundedRect: r, cornerRadius: r.height / 2), with: .color(look.cloud.opacity((on ? 0.42 : 0.2) * a)))
            }
        }

        // The power icon, a feature on the equator: foreshortened toward the limb, hidden round the back.
        let iconLon = spin
        let facing = cos(iconLon)
        if facing > 0 && !textured {                  // textured planets carry the icon as a surface decal
            var icon = ctx
            icon.clip(to: disc)
            icon.translateBy(x: c.x + sin(iconLon) * R * 0.88, y: c.y)
            icon.scaleBy(x: max(0.05, facing), y: 1)
            icon.opacity = pow(facing, 0.6)
            let glyph = icon.resolve(Text(Image(systemName: "power")).font(.system(size: R * 0.62, weight: .bold))
                .foregroundColor(on ? .white : Color(white: 0.55)))
            icon.addFilter(.shadow(color: .black.opacity(0.45), radius: 2, y: 1))
            icon.draw(glyph, at: .zero, anchor: .center)
        }

        // Sphere shading: a soft specular highlight top-left, the night side bottom-right
        // (textured planets are lit per pixel, so they only get a gentler highlight).
        let light = CGPoint(x: c.x - R * 0.38, y: c.y - R * 0.42)
        surface.fill(disc, with: .radialGradient(Gradient(colors: [.white.opacity(on ? (textured ? 0.18 : 0.42) : 0.12), .white.opacity(0)]),
                                                 center: light, startRadius: 0, endRadius: R * 0.75))
        if !textured { surface.fill(disc, with: .radialGradient(Gradient(stops: [
            .init(color: .black.opacity(0), location: 0.45),
            .init(color: .black.opacity(on ? 0.55 : 0.75), location: 0.85),
            .init(color: .black.opacity(on ? 0.8 : 0.9), location: 1),
        ]), center: CGPoint(x: c.x - R * 0.3, y: c.y - R * 0.3), startRadius: 0, endRadius: R * 1.45)) }

        // Plasma globe: filaments crackle from the central electrode to the glass, brighter with the music.
        if st.kind == .plasma {
            var arc = ctx
            arc.blendMode = .plusLighter
            let tt = OrbitSim.shared.time, e = on ? min(1, OrbitSim.shared.energy * 2.2) : 0.15
            let col = mix(heat, .white, 0.35), a0 = 0.4 + 0.6 * e
            for k in 0..<7 {
                let a = Double(k) * 2 * .pi / 7 + tt * (0.25 + 0.1 * sin(Double(k) * 1.7)) + 0.6 * sin(tt * 0.7 + Double(k) * 2.3)
                let end = CGPoint(x: c.x + cos(a) * R * 0.96, y: c.y + sin(a) * R * 0.96)
                let path = Self.bolt(from: c, to: end)
                arc.stroke(path, with: .color(col.opacity(0.25 * a0)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                arc.stroke(path, with: .color(Color.white.opacity(0.85 * a0)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
                arc.fill(Path(ellipseIn: CGRect(x: end.x - 6, y: end.y - 6, width: 12, height: 12)),
                         with: .radialGradient(Gradient(colors: [Color.white.opacity(0.6 * a0), col.opacity(0)]), center: end, startRadius: 0, endRadius: 6))
            }
            let cr = R * 0.22
            arc.fill(Path(ellipseIn: CGRect(x: c.x - cr, y: c.y - cr, width: cr * 2, height: cr * 2)),
                     with: .radialGradient(Gradient(colors: [Color.white.opacity(0.9), col.opacity(0.6 * a0), col.opacity(0)]), center: c, startRadius: 0, endRadius: cr))
        }
        // Flares: pulses leaving the surface and sparks skimming it light the planet and its
        // atmosphere layers where they are.
        if on {
            var glow = ctx
            glow.blendMode = .plusLighter
            for l in RingSim.shared.planetLights() {
                let p = CGPoint(x: c.x + cos(l.th) * R, y: c.y + sin(l.th) * R)
                let lr = R * (0.35 + 0.3 * l.power)
                glow.fill(Path(ellipseIn: CGRect(x: p.x - lr, y: p.y - lr, width: lr * 2, height: lr * 2)),
                          with: .radialGradient(Gradient(colors: [mix(heat, .white, 0.4).opacity(0.55 * l.power), heat.opacity(0)]),
                                                center: p, startRadius: 0, endRadius: lr))
                for lr2 in [R * 1.035, R * 1.07] {
                    var arc = Path()
                    arc.addArc(center: c, radius: lr2, startAngle: .radians(l.th - 0.35), endAngle: .radians(l.th + 0.35), clockwise: false)
                    glow.stroke(arc, with: .color(heat.opacity(0.6 * l.power)), lineWidth: 1)
                }
            }
        }

        // Ring shadow: the ring band cast onto the planet. Light comes from the top-left, so the
        // shadow is the band shifted down-right, clipped to the disc, soft; the gap lets light through.
        // Only the front half casts onto the face you see (the back half's shadow lands on the far side).
        if st.rings {
            var sh = ctx
            sh.clip(to: disc)
            sh.addFilter(.blur(radius: 1.6))
            sh.translateBy(x: c.x + R * 0.16, y: c.y + R * 0.2)
            sh.rotate(by: .radians(planeTilt(st)))
            let inner = R * 1.18, outer = R * (1.18 + st.ringWidth)
            sh.clip(to: Path(CGRect(x: -outer * 1.1, y: 0, width: outer * 2.2, height: outer * 2)))
            var band = Path()
            band.addEllipse(in: CGRect(x: -outer, y: -outer * ringOpen, width: outer * 2, height: outer * ringOpen * 2))
            band.addEllipse(in: CGRect(x: -inner, y: -inner * ringOpen, width: inner * 2, height: inner * ringOpen * 2))
            if st.ringGap >= 0 {
                let g0 = inner + (outer - inner) * Double(st.ringGap) / Double(st.ringLines - 1)
                let g1 = inner + (outer - inner) * Double(st.ringGap + 1) / Double(st.ringLines - 1)
                band.addEllipse(in: CGRect(x: -g1, y: -g1 * ringOpen, width: g1 * 2, height: g1 * ringOpen * 2))
                band.addEllipse(in: CGRect(x: -g0, y: -g0 * ringOpen, width: g0 * 2, height: g0 * ringOpen * 2))
            }
            sh.fill(band, with: .color(.black.opacity(on ? 0.42 : 0.22)), style: FillStyle(eoFill: true))
        }

        // Moon shadows on the surface: light comes from the top-left, so a moon in front of the
        // disc throws a soft shadow down-right, further the higher it floats above the surface.
        if on {
            var sh = ctx
            sh.clip(to: disc)
            for m in moons(st, R: R) where sin(m.angle) > 0 {
                let p = moonPoint(m, tilt: planeTilt(st))
                guard hypot(p.x, p.y) < R + m.size else { continue }
                let lift = sin(m.angle) * m.radius * 0.5
                let q = CGPoint(x: c.x + p.x + lift * 0.42, y: c.y + p.y + lift * 0.42)
                let r = m.size * 2.4
                sh.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(Gradient(colors: [.black.opacity(0.45), .black.opacity(0)]), center: q, startRadius: 0, endRadius: r))
            }
        }

        // Limb: the thin bright edge of the atmosphere on the lit side.
        if on {
            ctx.stroke(disc, with: .linearGradient(Gradient(colors: [mix(heat, .white, 0.5).opacity(0.9), heat.opacity(0.0)]),
                                                   startPoint: CGPoint(x: c.x - R, y: c.y - R), endPoint: CGPoint(x: c.x + R * 0.4, y: c.y + R * 0.4)),
                       lineWidth: 1.4)
        }

        // Rings: the near half crosses in front of the planet.
        if st.rings { drawRings(ctx, c: c, R: R, front: true, color: heat, on: on, st: st) }
        drawMoons(ctx, c: c, R: R, front: true, color: heat, on: on, st: st)
    }

    /// Base colours per planet type: base (ocean/ground), two land tones, clouds, and a glow for
    /// cracks that emit light (lava, radiation).
    static func colors(_ k: PlanetStyle.Kind) -> (base: Color, land: Color, land2: Color, cloud: Color, glow: Color?) {
        let h = Palettes.hex
        switch k {
        case .gasGiant: return (h(0x553366), h(0x885599), h(0xAA77BB), .white, nil)
        case .terran:   return (h(0x1E4E8C), h(0x3F7D3A), h(0xA08B5B), .white, nil)
        case .ocean:    return (h(0x155E9A), h(0x4C8C4A), h(0x8FB36A), .white, nil)
        case .jungle:   return (h(0x1F5C7A), h(0x2F6B2F), h(0x4E8F35), .white, nil)
        case .desert:   return (h(0xC49A5B), h(0x9C6E3C), h(0xD9B77E), h(0xF3E3C8), nil)
        case .tundra:   return (h(0x8FA6B3), h(0x6E7F86), h(0xA9BAC2), .white, nil)
        case .ice:      return (h(0xCFE6F5), h(0xB5D4EA), h(0xE6F2FA), .white, h(0x6FA4CF))
        case .barren:   return (h(0x7A7672), h(0x5B5855), h(0x9A9590), .white, nil)
        case .radiated: return (h(0x3A3F1E), h(0x4E5527), h(0x2E3216), h(0xD8F27A), h(0xC6FF3A))
        case .toxic:    return (h(0x6D7A1E), h(0xB8C23A), h(0x8C9A2A), h(0xE2E86A), nil)
        case .inferno:  return (h(0x2A1512), h(0x3F1D16), h(0x1C0E0C), h(0x5A3A30), h(0xFF6A1A))
        case .star:     return (h(0xFFB347), h(0xFF8A2A), h(0xFFD27A), h(0xFFF0C0), h(0xFFF4D6))
        case .crystal:  return (h(0x1A2233), h(0x2A3550), h(0x6A7FA8), .white, h(0xB8C8FF))
        case .eightBall: return (h(0x0C0C0E), h(0x161618), h(0x0C0C0E), .white, nil)
        case .mana:     return (h(0x1A2A6A), h(0x2A4AC8), h(0x4A7AFF), .white, h(0x6A9AFF))
        case .disco:    return (h(0xA8ACB2), h(0xC8CCD2), h(0x7A7E84), .white, nil)
        case .eyeball:  return (h(0xEFE8E0), h(0xD8CFC4), h(0xB0282A), .white, nil)
        case .plasma:   return (h(0x0A0A14), h(0x14142A), h(0x2A2A50), .white, h(0xC88CFF))
        case .pearl:    return (h(0xF1EAE0), h(0xE4DCD2), h(0xD8E4F0), .white, nil)
        case .mercury:  return (h(0x9AA0A8), h(0x6A7078), h(0xC8CED6), .white, nil)
        }
    }

    // MARK: Rings and moons (from the Fable brainstorm: kick moon, band-per-line rings, shepherds)

    /// Satellite impacts as surface lights: the screen angle of each strike, fading over 0.8 s.
    private func impactLights(_ st: PlanetStyle) -> [(th: Double, power: Double)] {
        let o = OrbitSim.shared, tilt = planeTilt(st)
        return o.impacts.map { imp in
            let x = cos(imp.angle), y = sin(imp.angle) * ringOpen
            let th = atan2(x * sin(tilt) + y * cos(tilt), x * cos(tilt) - y * sin(tilt))
            return (th: th, power: 2.5 * imp.power * max(0, 1 - (o.time - imp.at) / 0.8))
        }
    }

    /// The orbital plane: the ring's tilt, or a gentler version of the axial tilt without rings.
    private func planeTilt(_ st: PlanetStyle) -> Double { st.rings ? st.ringTilt : st.tilt * 0.6 }
    /// The ring plane's opening, following the headbang nod.
    private var ringOpen: Double { PlanetSpin.shared.ringOpen }

    /// The moons on this planet: kick moon always, shepherds on ringed planets.
    private struct Moon { var angle: Double; var radius: Double; var size: Double; var glow: Double; var trail: [OrbitSim.Sample]; var springy = false; var lift = 0.0; var rocket = false; var energy: Double? = nil }
    private func moons(_ st: PlanetStyle, R: Double) -> [Moon] {
        let o = OrbitSim.shared
        var out = [Moon(angle: o.moonAngle, radius: R * 1.72 + o.spring, size: 3.2, glow: 0.5 + o.flash, trail: o.moonTrail, springy: true)]
        if st.rings {
            out.append(Moon(angle: o.innerAngle, radius: R * 1.18, size: 1.8, glow: 0.3 + o.groups[0], trail: o.innerTrail))
            out.append(Moon(angle: o.outerAngle, radius: R * (1.18 + st.ringWidth), size: 1.6, glow: 0.3 + o.groups[5], trail: o.outerTrail))
        }
        for v in o.voiceMoons {
            let energy = max(0, min(1, (v.size - 1.3) / 1.4))           // the note's strength
            out.append(Moon(angle: v.angle, radius: v.r, size: v.size, glow: v.falling ? 0.9 : 0.25 + 0.5 * energy, trail: v.trail, springy: true,
                            lift: v.lift, rocket: !v.inserted && !v.falling, energy: energy))
        }
        return out
    }
    /// A jagged bolt from `a` to `b`: four rounds of midpoint displacement, halving each round.
    private static func bolt(from a: CGPoint, to b: CGPoint) -> Path {
        var pts = [a, b]
        var amp = Double(hypot(b.x - a.x, b.y - a.y)) * 0.22
        for _ in 0..<4 {
            var next = [pts[0]]
            for i in 1..<pts.count {
                let p = pts[i - 1], q = pts[i]
                let dx = Double(q.x - p.x), dy = Double(q.y - p.y), len = max(0.001, hypot(dx, dy))
                let off = Double.random(in: -amp...amp)
                next.append(CGPoint(x: Double(p.x + q.x) / 2 - dy / len * off, y: Double(p.y + q.y) / 2 + dx / len * off))
                next.append(q)
            }
            pts = next
            amp *= 0.5
        }
        var path = Path()
        path.addLines(pts)
        return path
    }

    /// A point on the orbital plane in screen space (relative to the planet centre).
    private func moonPoint(_ m: Moon, tilt: Double) -> CGPoint {
        let x = cos(m.angle) * m.radius, y = sin(m.angle) * m.radius * ringOpen
        return CGPoint(x: x * cos(tilt) - y * sin(tilt), y: x * sin(tilt) + y * cos(tilt))
    }

    /// Ring lines follow six band groups; a kick sends a brightness ripple outward, 35 ms per line.
    private func drawRings(_ ctx: GraphicsContext, c: CGPoint, R: Double, front: Bool, color: Color, on: Bool, st style: PlanetStyle) {
        let orbit = OrbitSim.shared
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: .radians(planeTilt(style)))
        g.clip(to: Path(CGRect(x: -R * 3, y: front ? 0 : -R * 3, width: R * 6, height: R * 3)))
        let inner = R * 1.18, outer = R * (1.18 + style.ringWidth)
        let lines = style.ringLines
        let wave = WavePhase.shared
        for k in 0..<lines where k != style.ringGap && k != style.ringGap + 1 {
            let x = Double(k) / Double(lines - 1)
            let lv = on ? orbit.groups[min(5, k * 6 / lines)] : 0
            // Kick ripple: inner line to outer, 35 ms per line, swelling each by 3 %.
            let since = orbit.time - orbit.kickAt - x * 0.21
            let bump = on && since >= 0 && since < 0.07 ? sin(.pi * since / 0.07) : 0
            // Haptic waves: brightness travels outward across the lines with the trackpad's soundwave.
            let pulse = on ? (0.5 + 0.5 * sin(2 * .pi * (x * 1.6 - wave.phase))) * min(1, (orbit.groups[0] + 0.15) * 1.6) : 0
            let rx = (inner + (outer - inner) * x) * (1 + 0.03 * bump), ry = rx * ringOpen
            let base = on ? 0.3 + 0.6 * lv : 0.14
            let alpha = min(1, base * (0.55 + 0.45 * pulse) + 0.5 * bump) * (front ? 1 : 0.6)
            let tint = mix(color, .white, min(0.6, 0.25 * pulse + 0.35 * bump))
            g.stroke(Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)),
                     with: .color(tint.opacity(alpha)), lineWidth: on ? 0.9 + 1.4 * lv + bump + 0.6 * pulse : 1.2)
        }
        // Shepherd wakes: a bright 30° smear along the line their moon rides.
        if on && style.rings {
            for w in orbit.wakes {
                let age = orbit.time - w.at
                guard age < 0.3 else { continue }
                let rx = w.outer ? outer : inner, ry = rx * ringOpen
                var arc = Path()
                for j in 0...12 {
                    let a = w.angle - 0.52 * Double(j) / 12
                    let p = CGPoint(x: cos(a) * rx, y: sin(a) * ry)
                    if j == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
                }
                g.stroke(arc, with: .color(Color.white.opacity(0.8 * (1 - age / 0.3))), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
    }

    /// Kick moon and shepherds with their trails; `front` draws what is on the near side of the orbit.
    private func drawMoons(_ ctx: GraphicsContext, c: CGPoint, R: Double, front: Bool, color: Color, on: Bool, st style: PlanetStyle) {
        let orbit = OrbitSim.shared
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: .radians(planeTilt(style)))
        for m in moons(style, R: R) {
            // Voice satellites take their colour from the palette by the note's energy (soft notes the
            // heat accent, strong ones the hot accent), paler for higher notes.
            let mc = m.energy.map { mix(mix(color, Theme.hot, $0), .white, m.lift * 0.35) } ?? mix(color, .white, m.lift * 0.5)
            // Trail: the orbit the moon actually travelled (kick jumps included), drawn as continuous
            // lines, never dots. Points are filled in every 0.03 rad so fast moons follow the orbit's
            // curve; each side of the planet is one connected path; three layered strokes taper it.
            if on, m.trail.count > 1 {
                var pts: [(p: CGPoint, ageFrac: Double, side: Bool)] = []
                for i in 1..<m.trail.count {
                    let a = m.trail[i - 1], b = m.trail[i]
                    let ra = m.springy ? a.radius : m.radius, rb = m.springy ? b.radius : m.radius
                    let steps = max(1, Int(abs(b.angle - a.angle) / 0.03))
                    for k in 0..<steps {
                        let f = Double(k) / Double(steps)
                        let ang = a.angle + (b.angle - a.angle) * f, rad = ra + (rb - ra) * f
                        let age = orbit.time - (a.t + (b.t - a.t) * f)
                        guard age < 0.9 else { continue }
                        pts.append((CGPoint(x: cos(ang) * rad, y: sin(ang) * rad * ringOpen), age / 0.9, sin(ang) >= 0))
                    }
                }
                let tint = mix(mc, .white, orbit.speed * 0.5)
                let strength = 0.45 + orbit.speed * 0.5
                // Ten layers: each newer slice adds a little width and light, so the taper is smooth.
                let layers = (0..<10).map { k -> (cut: Double, w: Double, a: Double) in
                    let f = Double(k) / 9
                    return (cut: 1 - f * 0.9, w: 0.25 + 0.75 * f, a: (0.3 + 0.7 * f) / 3.2)
                }
                for layer in layers {
                    var path = Path(); var open = false
                    for q in pts {
                        if q.side == front && q.ageFrac <= layer.cut {
                            if open { path.addLine(to: q.p) } else { path.move(to: q.p); open = true }
                        } else { open = false }
                    }
                    g.stroke(path, with: .color(tint.opacity(min(1, strength * layer.a))),
                             style: StrokeStyle(lineWidth: m.size * 0.75 * layer.w + 0.3, lineCap: .round, lineJoin: .round))
                }
            }
            guard (sin(m.angle) >= 0) == front else { continue }
            let p = CGPoint(x: cos(m.angle) * m.radius, y: sin(m.angle) * m.radius * ringOpen)
            if m.rocket, on, m.trail.count > 1 {
                // The rocket's flame, pointing back along its climb, flickering.
                let b = m.trail[m.trail.count - 2]
                let q = CGPoint(x: cos(b.angle) * b.radius, y: sin(b.angle) * b.radius * ringOpen)
                let len = max(0.001, hypot(p.x - q.x, p.y - q.y))
                let fl = 8 + 6 * Double.random(in: 0...1)
                let tip = CGPoint(x: p.x - (p.x - q.x) / len * fl, y: p.y - (p.y - q.y) / len * fl)
                var flame = Path(); flame.move(to: tip); flame.addLine(to: p)
                var fire = g
                fire.blendMode = .plusLighter
                fire.stroke(flame, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.4, blue: 0.1).opacity(0), Color(red: 1, green: 0.85, blue: 0.5)]),
                                                         startPoint: tip, endPoint: p),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            // Faster moons shine brighter: whiter core, bigger, stronger halo.
            let fast = on ? orbit.speed : 0
            let glow = on ? m.glow + fast * 0.9 : 0.15
            let color = mc
            let d = m.size * (2 + fast * 1.6)
            g.fill(Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: d * 2, height: d * 2)),
                   with: .radialGradient(Gradient(colors: [color.opacity(min(1, 0.35 * glow)), color.opacity(0)]), center: p, startRadius: 0, endRadius: d))
            g.fill(Path(ellipseIn: CGRect(x: p.x - m.size, y: p.y - m.size, width: m.size * 2, height: m.size * 2)),
                   with: .radialGradient(Gradient(colors: [.white, mix(color, .white, 0.3 + fast * 0.5), mix(color, .black, 0.5 - fast * 0.35)]),
                                         center: CGPoint(x: p.x - m.size * 0.4, y: p.y - m.size * 0.4), startRadius: 0, endRadius: m.size * 1.6))
        }
        // Satellite impacts: a flash on the face and a wide ring, fading over 0.8 s.
        if front && on {
            var flash = g
            flash.blendMode = .plusLighter
            for imp in orbit.impacts {
                let age = orbit.time - imp.at, f = max(0, 1 - age / 0.8)
                let p = CGPoint(x: cos(imp.angle) * R * 0.97, y: sin(imp.angle) * R * 0.97 * ringOpen)
                let bloom = 10 + 10 * imp.power
                flash.fill(Path(ellipseIn: CGRect(x: p.x - bloom, y: p.y - bloom, width: bloom * 2, height: bloom * 2)),
                           with: .radialGradient(Gradient(colors: [mix(color, .white, 0.5).opacity(0.45 * f * f), color.opacity(0)]),
                                                 center: p, startRadius: 0, endRadius: bloom))
                let gr = 4 + 8 * imp.power * (0.4 + 0.6 * f)
                flash.fill(Path(ellipseIn: CGRect(x: p.x - gr, y: p.y - gr, width: gr * 2, height: gr * 2)),
                           with: .radialGradient(Gradient(colors: [Color.white.opacity(f * f), mix(color, .white, 0.4).opacity(0.6 * f), color.opacity(0)]),
                                                 center: p, startRadius: 0, endRadius: gr))
            }
        }
        // Impact debris: short white-hot streaks along their flight, cooling to the palette.
        if front && on && !orbit.debris.isEmpty {
            var sparks = g
            sparks.blendMode = .plusLighter
            for d in orbit.debris {
                let f = max(0, 1 - (orbit.time - d.born) / d.life)
                let head = CGPoint(x: d.x, y: d.y), tail = CGPoint(x: d.x - d.vx * 0.04, y: d.y - d.vy * 0.04)
                var p = Path(); p.move(to: tail); p.addLine(to: head)
                let hot: Color
                switch d.kind {
                case .blast: hot = mix(color, .white, 0.3 + 0.7 * f).opacity(f)
                case .rock: hot = Color(red: 0.42, green: 0.36, blue: 0.32).opacity(0.85 * min(1, f * 2))
                case .exhaust: hot = Color(red: 1, green: 0.55 + 0.4 * f, blue: 0.2 + 0.5 * f).opacity(f)
                case .stage: hot = Color(white: 0.75).opacity(0.7)
                }
                (d.kind == .rock ? g : sparks).stroke(p, with: .linearGradient(Gradient(colors: [hot.opacity(0), hot]), startPoint: tail, endPoint: head),
                              style: StrokeStyle(lineWidth: d.size, lineCap: .round))
            }
        }
        // Thunderbolts: a satellite near a prominence's fountain arcs to the nearest hot spark. The
        // sparks live in the ring view, centred on the same point, so they map into this frame by
        // undoing the orbital plane's tilt. Re-jagged every frame and not every frame lit: flicker.
        if front && on {
            let ring = RingSim.shared
            if !ring.sprinkles.isEmpty {
                let tilt = planeTilt(style), ct = cos(-tilt), sn = sin(-tilt)
                let hot = ring.sprinkles.filter { ring.clock - $0.born < 1 }.map { q -> CGPoint in
                    let sx = cos(q.th) * q.r, sy = sin(q.th) * q.r
                    return CGPoint(x: sx * ct - sy * sn, y: sx * sn + sy * ct)
                }
                var zap = g
                zap.blendMode = .plusLighter
                var bolts = 0
                for m in moons(style, R: R) where m.energy != nil && sin(m.angle) >= 0 && bolts < 6 {
                    let mp = CGPoint(x: cos(m.angle) * m.radius, y: sin(m.angle) * m.radius * ringOpen)
                    var best: CGPoint?, bestD = 24.0
                    for p in hot {
                        let d = hypot(p.x - mp.x, p.y - mp.y)
                        if d < bestD { bestD = d; best = p }
                    }
                    guard let to = best, Double.random(in: 0...1) < 0.75 else { continue }
                    bolts += 1
                    let path = Self.bolt(from: mp, to: to), f = 0.5 + 0.5 * (1 - bestD / 24)
                    let tint = mix(mix(color, Theme.hot, m.energy ?? 0), .white, 0.5)
                    zap.stroke(path, with: .color(tint.opacity(0.35 * f)), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    zap.stroke(path, with: .color(Color.white.opacity(0.95 * f)), style: StrokeStyle(lineWidth: 0.7, lineCap: .round, lineJoin: .round))
                    let r = 3.5 * f
                    zap.fill(Path(ellipseIn: CGRect(x: to.x - r, y: to.y - r, width: r * 2, height: r * 2)),
                             with: .radialGradient(Gradient(colors: [Color.white.opacity(0.8 * f), tint.opacity(0)]), center: to, startRadius: 0, endRadius: r))
                }
            }
        }
        // Kicks and launches: a soft puff of light where the moon is, no outline.
        if front && on {
            var puff = g
            puff.blendMode = .plusLighter
            for s in orbit.shocks {
                let age = orbit.time - s.at
                guard age < 0.2 else { continue }
                let f = 1 - age / 0.2, r = 4 + 8 * age / 0.2
                let p = CGPoint(x: s.x, y: s.y)
                puff.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                          with: .radialGradient(Gradient(colors: [Color.white.opacity(0.45 * f), color.opacity(0)]), center: p, startRadius: 0, endRadius: r))
            }
        }
    }
}

/// How large the planet is drawn relative to the panel (the widget scales it): the render skips
/// pixels that would not reach the screen.
private struct PlanetPixelScaleKey: EnvironmentKey { static let defaultValue = 1.0 }
extension EnvironmentValues {
    var planetPixelScale: Double {
        get { self[PlanetPixelScaleKey.self] }
        set { self[PlanetPixelScaleKey.self] = newValue }
    }
}

/// How light that reaches past the planet (rays, haze) fades out before the canvas edge: toward the
/// box's sides in the panel, in a circle in the floating widget.
enum PlanetEdge { case box, radial }
private struct PlanetEdgeKey: EnvironmentKey { static let defaultValue = PlanetEdge.box }
extension EnvironmentValues {
    var planetEdge: PlanetEdge {
        get { self[PlanetEdgeKey.self] }
        set { self[PlanetEdgeKey.self] = newValue }
    }
}

/// Where the eyeball looks: at the pointer when it is over the panel, otherwise idle glances. It
/// moves in quick darts (saccades) and holds, with tiny jitters, as real eyes do.
@MainActor
final class EyeLook {
    static let shared = EyeLook()
    private(set) var lon = 0.0, pitch = 0.0
    private var target = (lon: 0.0, pitch: 0.0), wander = (lon: 0.0, pitch: 0.0)
    private var nextGlance = 0.0, last = 0.0

    func advance(t: Double) {
        let dt = last == 0 ? 0 : min(0.1, t - last)
        last = t
        var goal = wander
        let ring = RingSim.shared
        if let p = ring.cursor {
            let dx = p.x - ring.ringCenter.x, dy = p.y - ring.ringCenter.y
            goal = (max(-0.75, min(0.75, dx / 160)), max(-0.45, min(0.45, dy / 200)))
        } else if t > nextGlance {
            wander = (Double.random(in: -0.5...0.5), Double.random(in: -0.3...0.3))
            nextGlance = t + Double.random(in: 0.8...2.6)
        }
        // Dart when the goal has moved; otherwise hold with a tiny tremor.
        if hypot(goal.lon - target.lon, goal.pitch - target.pitch) > 0.05 { target = goal }
        lon += (target.lon - lon) * min(1, dt * 16) + Double.random(in: -0.002...0.002)
        pitch += (target.pitch - pitch) * min(1, dt * 16)
    }
}

/// Cross-fade between planet styles: remembers the outgoing style for 1.2 s after a change.
@MainActor
final class PlanetMorph {
    static let shared = PlanetMorph()
    private var current: PlanetStyle?
    private var previous: PlanetStyle?
    private var changedAt = 0.0

    /// Returns the outgoing style and the progress (0...1, eased) while a change is under way.
    func update(to style: PlanetStyle, t: Double) -> (PlanetStyle, Double)? {
        if current == nil { current = style }
        if current != style { previous = current; current = style; changedAt = t }
        guard let from = previous else { return nil }
        let x = min(1, (t - changedAt) / 1.2)
        if x >= 1 { previous = nil; return nil }
        return (from, x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2)
    }
}

/// Orbit state for the rings and moons, advanced once per planet frame.
@MainActor
final class OrbitSim {
    static let shared = OrbitSim()
    struct Wake { var at: Double; var angle: Double; var outer: Bool }
    struct Sample { var angle: Double; var radius: Double; var t: Double }
    var moonTrail: [Sample] = [], innerTrail: [Sample] = [], outerTrail: [Sample] = []
    private var trailR = 0.0
    var time = 0.0
    var kickAt = -10.0
    var groups = [Double](repeating: 0, count: 6)
    var moonAngle = 0.4, innerAngle = 1.0, outerAngle = 3.0
    var spring = 0.0, flash = 0.0
    var energy = 0.0
    /// Orbital pace (rad/s) and how fast that is, 0 drifting ... 1 flat out: faster moons shine brighter.
    var pace = 0.4
    var speed: Double { max(0, min(1, (pace - 0.4) / 2.2)) }
    var shocks: [(at: Double, x: Double, y: Double)] = []
    var wakes: [Wake] = []
    private var springV = 0.0, lastKick = 0.0, prior = [Double](repeating: 0, count: 6)

    func step(t: Double, kick: Double, levels: [Double], R: Double, on: Bool, now: Double = 0) {
        let dt = time == 0 ? 0 : min(0.1, t - time)
        time = t
        // Six band groups, low to high; with nothing coming in (off) they fade out.
        if levels.isEmpty {
            for k in 0..<6 { groups[k] *= exp(-dt * 3) }
        } else {
            let n = levels.count
            for k in 0..<6 {
                let a = k * n / 6, b = max(a + 1, (k + 1) * n / 6)
                let v = levels[a..<b].reduce(0, +) / Double(b - a)
                groups[k] += (v - groups[k]) * min(1, dt * 12)
            }
        }
        // Orbital speed follows the song's overall intensity (loudness across all bands, ~1.5 s
        // smoothing): calm passages drift, loud ones whip the moons round, and the fixed-length
        // trail stretches on its own.
        let loud = groups.reduce(0, +) / Double(groups.count)
        energy += (loud - energy) * min(1, dt / 1.5)
        pace = 0.4 + energy * 2.2
        moonAngle += dt * pace
        innerAngle += dt * pace * 1.5          // inner orbits run faster (Kepler)
        outerAngle += dt * pace * 0.9
        // Kick: fling the moon outward, flash, and fire a shock ring where it is.
        if on && kick > lastKick + 0.35 {
            kickAt = t
            springV += 160
            flash = 1
            let r = R * 1.72 + spring
            shocks.append((t, cos(moonAngle) * r, sin(moonAngle) * r * 0.24))
        }
        lastKick = kick
        let acc = -250 * spring - 14 * springV                    // ~250 ms settle, slight overshoot
        springV += acc * dt
        spring += springV * dt
        flash *= exp(-dt / 0.2)
        // Shepherd wakes when their band group jumps.
        for (k, outer) in [(0, false), (5, true)] where on && groups[k] - prior[k] > 0.12 {
            wakes.append(Wake(at: t, angle: outer ? outerAngle : innerAngle, outer: outer))
        }
        prior = groups
        // Trails: the positions actually flown, kept for 0.9 s.
        moonTrail.append(Sample(angle: moonAngle, radius: R * 1.72 + spring, t: t))
        innerTrail.append(Sample(angle: innerAngle, radius: R * 1.18, t: t))
        outerTrail.append(Sample(angle: outerAngle, radius: R * 1.48, t: t))
        for k in [0, 1, 2] {
            switch k {
            case 0: moonTrail.removeAll { t - $0.t > 0.9 }
            case 1: innerTrail.removeAll { t - $0.t > 0.6 }
            default: outerTrail.removeAll { t - $0.t > 0.6 }
            }
        }
        shocks.removeAll { t - $0.at > 0.25 }
        wakes.removeAll { t - $0.at > 0.35 }
        stepVoices(t: t, dt: dt, now: now, R: R, on: on)
    }

    // MARK: Voice satellites

    /// A satellite born from a prominent voice: launched off the face you see when the note sounds,
    /// it climbs to an orbit set by the note's pitch, then decays and drops back onto the planet.
    struct VoiceMoon {
        var angle: Double, r: Double, vr = 0.0, target: Double, size: Double, lift: Double
        var born: Double, life: Double, falling = false, trail: [Sample] = []
        var inserted = false
    }
    /// At most 10 in orbit; the oldest falls to make room.
    private(set) var voiceMoons: [VoiceMoon] = []
    /// Where satellites hit (angle on the orbital plane), for the flash and the surface light.
    private(set) var impacts: [(at: Double, angle: Double, power: Double)] = []
    /// Debris in orbital-plane screen space around the planet centre. Each piece rises from a
    /// point on the surface along `d` (outward) to height `h` under gravity `g` and lands when h < 0;
    /// `o` drifts sideways at `l`. Kinds: blast sparks, rocket exhaust (weightless), spent stages.
    struct Debris {
        enum Kind { case blast, rock, exhaust, stage }
        var bx: Double, by: Double, dx: Double, dy: Double, h: Double, vh: Double, g: Double
        var ox = 0.0, oy = 0.0, lx: Double, ly: Double, born: Double, life: Double, size: Double, kind: Kind
        var x: Double { bx + dx * h + ox }
        var y: Double { by + dy * h + oy }
        var vx: Double { dx * vh + lx }
        var vy: Double { dy * vh + ly }
    }
    private(set) var debris: [Debris] = []

    /// A burst of blast sparks from a surface point.
    private func sparks(at px: Double, _ py: Double, count: Int, speed: ClosedRange<Double>, t: Double) {
        let d = hypot(px, py)
        var ox = d > 1 ? px / d : 0, oy = d > 1 ? py / d : -1
        oy -= 0.7                                                    // a little upward on screen
        let n = max(0.01, hypot(ox, oy)); ox /= n; oy /= n
        for _ in 0..<count {
            let side = Double.random(in: -45...45), rock = Double.random(in: 0...1) < 0.6
            debris.append(Debris(bx: px, by: py, dx: ox, dy: oy, h: 0, vh: Double.random(in: speed) * (rock ? 0.8 : 1), g: 300,
                                 lx: -oy * side, ly: ox * side, born: t, life: 1.6,
                                 size: rock ? Double.random(in: 0.5...1.0) : Double.random(in: 0.35...0.8), kind: rock ? .rock : .blast))
        }
    }
    private var pendingVoices: [VoiceSpotter.Event] = []

    func addVoices(_ events: [VoiceSpotter.Event]) { pendingVoices += events }

    private func stepVoices(t: Double, dt: Double, now: Double, R: Double, on: Bool) {
        // Births when the note leaves the speakers.
        while on, let e = pendingVoices.first, e.time <= now {
            pendingVoices.removeFirst()
            guard now - e.time < 1 else { continue }
            if voiceMoons.filter({ !$0.falling }).count >= 10, let k = voiceMoons.firstIndex(where: { !$0.falling }) {
                voiceMoons[k].falling = true
            }
            let a = Double.random(in: 0.35...(.pi - 0.35))            // from the face you see
            voiceMoons.append(VoiceMoon(angle: a, r: R, target: R * (1.4 + 0.9 * e.pitch), size: 1.3 + 1.4 * e.strength,
                                        lift: e.pitch, born: t, life: 8 + 10 * e.strength))
            shocks.append((t, cos(a) * R, sin(a) * R * 0.24))
        }
        if !on { pendingVoices.removeAll() }
        for k in voiceMoons.indices {
            var m = voiceMoons[k]
            if !on || t - m.born > m.life { m.falling = true }
            let open = PlanetSpin.shared.ringOpen
            let before = (x: cos(m.angle) * m.r, y: sin(m.angle) * m.r * open)
            var climb = 1.0
            if m.falling {
                m.vr -= R * 1.2 * dt                                    // the orbit decays ever faster
                m.r += m.vr * dt
            } else if !m.inserted {
                // A tiny rocket: slow off the pad, faster, then curving into orbit as it gains speed.
                let u = min(1, (t - m.born) / 1.3)
                m.r = R + (m.target - R) * u * u * (3 - 2 * u)
                climb = 0.25 + 0.75 * u
                if u >= 1 {
                    m.inserted = true
                    // The spent stage drops away and falls back onto the planet.
                    let mx = cos(m.angle) * m.r, my = sin(m.angle) * m.r * open
                    let sx = cos(m.angle) * R, sy = sin(m.angle) * R * open
                    let hd = max(0.5, hypot(mx - sx, my - sy))
                    for _ in 0..<2 {
                        debris.append(Debris(bx: sx, by: sy, dx: (mx - sx) / hd, dy: (my - sy) / hd, h: hd, vh: Double.random(in: -5...15), g: 140,
                                             lx: Double.random(in: -12...12), ly: Double.random(in: -12...12), born: t, life: 4,
                                             size: Double.random(in: 1.2...1.8), kind: .stage))
                    }
                }
            } else {
                m.r += (m.target - m.r) * min(1, dt * 2.5)
            }
            m.angle += dt * climb * min(7, pace * pow(R * 1.72 / max(R, m.r), 1.5))     // Kepler: low runs fast
            if !m.inserted && !m.falling {
                // Exhaust: sparks shed behind the rocket.
                let now = (x: cos(m.angle) * m.r, y: sin(m.angle) * m.r * open)
                let mvx = now.x - before.x, mvy = now.y - before.y, mv = max(0.001, hypot(mvx, mvy))
                for _ in 0..<3 {
                    let back = Double.random(in: 20...55), j = Double.random(in: -12...12)
                    debris.append(Debris(bx: now.x, by: now.y, dx: 0, dy: 0, h: 0, vh: 0, g: 0,
                                         lx: -mvx / mv * back - mvy / mv * j, ly: -mvy / mv * back + mvx / mv * j,
                                         born: t, life: Double.random(in: 0.25...0.45), size: Double.random(in: 0.7...1.3), kind: .exhaust))
                }
            }
            m.trail.append(Sample(angle: m.angle, radius: m.r, t: t))
            m.trail.removeAll { t - $0.t > 0.9 }
            voiceMoons[k] = m
        }
        // Impact on the face you see; a satellite still behind the planet skims round to the front.
        for k in voiceMoons.indices.reversed() where voiceMoons[k].falling && voiceMoons[k].r <= R {
            if sin(voiceMoons[k].angle) > 0.15 {
                let a = voiceMoons[k].angle, power = min(1, 0.5 + voiceMoons[k].size / 5)
                impacts.append((t, a, power))
                // The blast: sparks spray from the strike and fall back onto the surface.
                let open = PlanetSpin.shared.ringOpen
                // Meteorite debris: many tiny chips of dark rock and hot sparks, thrown a short way.
                sparks(at: cos(a) * R * 0.97, sin(a) * R * 0.97 * open, count: 26 + Int(14 * power),
                       speed: (25 * (0.6 + 0.4 * power))...(85 * (0.6 + 0.4 * power)), t: t)
                voiceMoons.remove(at: k)
            } else {
                voiceMoons[k].r = R; voiceMoons[k].vr = 0
            }
        }
        impacts.removeAll { t - $0.at > 0.8 }
        // Debris: up and back down onto the surface; a spent stage lands with a little burst.
        var landed: [(Double, Double)] = []
        for k in debris.indices {
            var p = debris[k]
            p.vh -= p.g * dt
            p.h += p.vh * dt
            p.ox += p.lx * dt; p.oy += p.ly * dt
            p.lx *= exp(-dt * 1.5); p.ly *= exp(-dt * 1.5)
            if p.kind == .stage && p.h < 0 { landed.append((p.bx + p.ox, p.by + p.oy)) }
            debris[k] = p
        }
        debris.removeAll { ($0.kind != .exhaust && $0.h < 0) || t - $0.born > $0.life }
        for (x, y) in landed { sparks(at: x, y, count: 5, speed: 15...45, t: t) }
    }
}
