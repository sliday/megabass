import AppKit
import MegaBassCore
import SwiftUI

/// The planet's rotation: a heavy body. Its speed follows the song's intensity with inertia; with
/// Overdrive on, every kick makes it headbang (a forward nod on a damped spring). Hovering turns
/// the power icon to face you.
@MainActor
final class PlanetSpin {
    static let shared = PlanetSpin()
    var lon = 0.0              // icon longitude; 0 faces the camera
    var hover = false
    /// Angular speed (rad/s) and the blur it implies, for the renderer.
    private(set) var omega = 0.2
    private var nod = 0.0, nodV = 0.0, lastKick = 0.0
    private var last = 0.0

    /// Advances the spin. `rate` is the planet's own base speed; `energy` the song's loudness;
    /// `kick` the kick pulse; `headbang` whether Overdrive is on. Returns the angle to draw.
    func advance(_ t: Double, on: Bool, rate: Double = 0.2, energy: Double = 0, kick: Double = 0, headbang: Bool = false) -> Double {
        let dt = last == 0 ? 0 : min(0.1, t - last)
        last = t
        if !on {
            lon = 0; omega = rate; nod = 0; nodV = 0                // off: icon faces you, easy to find
            return 0
        }
        if hover {
            let target = (lon / (2 * .pi)).rounded(.up) * 2 * .pi
            lon += (target - lon) * min(1, dt * 7)
            if abs(target - lon) < 0.002 { lon = target }
            omega = rate
            nod *= exp(-dt * 8)
            return lon + nod
        }
        // Heavy: speed eases toward 0.6-4x the base rate over ~2.5 s.
        let target = rate * (0.6 + min(1, energy * 2.8) * 3.4)
        omega += (target - omega) * min(1, dt / 2.5)
        lon += omega * dt
        // Headbang: a kick kicks the nod forward; a stiff, damped spring brings it back.
        if headbang && kick > lastKick + 0.35 { nodV += 2.6 * kick }
        lastKick = kick
        nodV += (-70 * nod - 9 * nodV) * dt
        nod += nodV * dt
        return lon + nod
    }

    /// How far the surface turns in one frame, as a fraction of a full turn (for motion blur).
    var blurTurn: Double { (abs(omega) + abs(nodV)) / 30 / (2 * .pi) }
}

/// The power button as a small gas giant: banded surface in the station's palette that flows like
/// a rotating atmosphere, a drifting storm, sphere shading lit from the top-left, and an atmosphere
/// halo that flares on kicks. Dark and still when megabass is off.
struct PlanetView: View {
    @ObservedObject var engine: Engine
    var radius: CGFloat = 48
    var style = PlanetStyle.from("megabass")
    /// Draw lit even when megabass is off (gallery).
    var alwaysOn = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !engine.enabled && !alwaysOn)) { tl in
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
        let on = engine.enabled || alwaysOn
        OrbitSim.shared.step(t: t, kick: on ? engine.kickPulse : 0, levels: on ? RingSim.shared.levels : [], R: Double(radius), on: on)
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
            var rays = ctx
            rays.blendMode = .plusLighter
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
        let spin = PlanetSpin.shared.advance(t, on: on, rate: st.spin, energy: OrbitSim.shared.energy,
                                             kick: kick, headbang: engine.overdrive > 0)
        // The surface leans with the planet's axial tilt.
        surface.translateBy(x: c.x, y: c.y); surface.rotate(by: .radians(st.tilt)); surface.translateBy(x: -c.x, y: -c.y)

        let look = Self.colors(st.kind)
        func tint(_ col: Color) -> Color { on ? mix(col, hot, 0.15) : mix(col, Color(white: 0.25), 0.7) }

        // Crisp fractal surface (see PlanetTexture); the vector look below is the fallback while it bakes.
        let textured: Bool
        if let tex = PlanetTextures.shared.texture(for: st, hot: Theme.hot, heat: Theme.heat),
           let img = PlanetTextures.shared.render(tex, radius: R, tilt: st.tilt, spin: spin, on: on,
                                                  rim: heat, grade: st.kind == .star || !on ? nil : (hot, heat),
                                                  flares: on ? RingSim.shared.planetLights() : [], flareColor: mix(heat, .white, 0.35),
                                                  icon: true, sun: Float(sunlight(on: on)), iconColor: brightest(hot, heat),
                                                  blur: Float(PlanetSpin.shared.blurTurn)) {
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
        }
    }

    // MARK: Rings and moons (from the Fable brainstorm: kick moon, band-per-line rings, shepherds)

    /// The orbital plane: the ring's tilt, or a gentler version of the axial tilt without rings.
    private func planeTilt(_ st: PlanetStyle) -> Double { st.rings ? st.ringTilt : st.tilt * 0.6 }

    /// The moons on this planet: kick moon always, shepherds on ringed planets.
    private struct Moon { var angle: Double; var radius: Double; var size: Double; var glow: Double; var trail: [OrbitSim.Sample]; var springy = false }
    private func moons(_ st: PlanetStyle, R: Double) -> [Moon] {
        let o = OrbitSim.shared
        var out = [Moon(angle: o.moonAngle, radius: R * 1.72 + o.spring, size: 3.2, glow: 0.5 + o.flash, trail: o.moonTrail, springy: true)]
        if st.rings {
            out.append(Moon(angle: o.innerAngle, radius: R * 1.18, size: 1.8, glow: 0.3 + o.groups[0], trail: o.innerTrail))
            out.append(Moon(angle: o.outerAngle, radius: R * (1.18 + st.ringWidth), size: 1.6, glow: 0.3 + o.groups[5], trail: o.outerTrail))
        }
        return out
    }
    /// A point on the orbital plane in screen space (relative to the planet centre).
    private func moonPoint(_ m: Moon, tilt: Double) -> CGPoint {
        let x = cos(m.angle) * m.radius, y = sin(m.angle) * m.radius * 0.24
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
        let lines = 6
        for k in 0..<lines {
            let lv = on ? orbit.groups[k] : 0
            let since = orbit.time - orbit.kickAt - Double(k) * 0.035
            let bump = on && since >= 0 && since < 0.07 ? sin(.pi * since / 0.07) : 0
            let rx = (inner + (outer - inner) * Double(k) / Double(lines - 1)) * (1 + 0.03 * bump), ry = rx * 0.24
            let base = on ? 0.15 + 0.6 * lv : 0.12
            let alpha = min(1, base + 0.5 * bump) * (front ? 1 : 0.6)
            g.stroke(Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)),
                     with: .color(color.opacity(alpha)), lineWidth: on ? 0.6 + 1.0 * lv + bump : 1.2)
        }
        // Shepherd wakes: a bright 30° smear along the line their moon rides.
        if on && style.rings {
            for w in orbit.wakes {
                let age = orbit.time - w.at
                guard age < 0.3 else { continue }
                let rx = w.outer ? outer : inner, ry = rx * 0.24
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
            // Trail: the orbit the moon actually travelled (kick jumps included), fading over 0.9 s,
            // each piece on the side of the planet it was on.
            if on, m.trail.count > 1 {
                for i in 1..<m.trail.count {
                    let a = m.trail[i - 1], b = m.trail[i]
                    guard (sin(b.angle) >= 0) == front else { continue }
                    let age = orbit.time - b.t
                    guard age < 0.9 else { continue }
                    var seg = Path()
                    // The kick moon's trail keeps its recorded radius (kick jumps); shepherds ride their ring edge.
                    let ra = m.springy ? a.radius : m.radius, rb = m.springy ? b.radius : m.radius
                    seg.move(to: CGPoint(x: cos(a.angle) * ra, y: sin(a.angle) * ra * 0.24))
                    seg.addLine(to: CGPoint(x: cos(b.angle) * rb, y: sin(b.angle) * rb * 0.24))
                    g.stroke(seg, with: .color(mix(color, .white, orbit.speed * 0.5).opacity(min(1, (0.45 + orbit.speed * 0.5) * (1 - age / 0.9)))), style: StrokeStyle(lineWidth: m.size * 0.7 * (1 - age / 0.9) + 0.3, lineCap: .round))
                }
            }
            guard (sin(m.angle) >= 0) == front else { continue }
            let p = CGPoint(x: cos(m.angle) * m.radius, y: sin(m.angle) * m.radius * 0.24)
            // Faster moons shine brighter: whiter core, bigger, stronger halo.
            let fast = on ? orbit.speed : 0
            let glow = on ? m.glow + fast * 0.9 : 0.15
            let d = m.size * (2 + fast * 1.6)
            g.fill(Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: d * 2, height: d * 2)),
                   with: .radialGradient(Gradient(colors: [color.opacity(min(1, 0.35 * glow)), color.opacity(0)]), center: p, startRadius: 0, endRadius: d))
            g.fill(Path(ellipseIn: CGRect(x: p.x - m.size, y: p.y - m.size, width: m.size * 2, height: m.size * 2)),
                   with: .radialGradient(Gradient(colors: [.white, mix(color, .white, 0.3 + fast * 0.5), mix(color, .black, 0.5 - fast * 0.35)]),
                                         center: CGPoint(x: p.x - m.size * 0.4, y: p.y - m.size * 0.4), startRadius: 0, endRadius: m.size * 1.6))
        }
        // Shock rings from the kick moon: 0 to 10 pt over 200 ms, fading.
        if front && on {
            for s in orbit.shocks {
                let age = orbit.time - s.at
                guard age < 0.2 else { continue }
                let r = 2 + 10 * age / 0.2
                g.stroke(Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)),
                         with: .color(Color.white.opacity(0.7 * (1 - age / 0.2))), lineWidth: 1.2)
            }
        }
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

    func step(t: Double, kick: Double, levels: [Double], R: Double, on: Bool) {
        let dt = time == 0 ? 0 : min(0.1, t - time)
        time = t
        // Six band groups, low to high.
        if !levels.isEmpty {
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
    }
}
