import AppKit
import MegaBassCore
import SwiftUI

/// Spin of the power-icon feature on the planet's equator. Hovering rotates it to face you.
@MainActor
final class PlanetSpin {
    static let shared = PlanetSpin()
    var lon = 0.0              // icon longitude; 0 faces the camera
    var hover = false
    private var last = 0.0

    func advance(_ t: Double, on: Bool, rate: Double = 0.2) -> Double {
        let dt = last == 0 ? 0 : min(0.1, t - last)
        last = t
        if !on {
            lon = 0                                            // off: icon faces you, easy to find
        } else if hover {
            // Turn forward to the nearest facing position and hold it there.
            let target = (lon / (2 * .pi)).rounded(.up) * 2 * .pi
            lon += (target - lon) * min(1, dt * 7)
            if abs(target - lon) < 0.002 { lon = target }
        } else {
            lon += dt * rate
        }
        return lon
    }
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

    private func draw(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = Double(radius)
        let on = engine.enabled || alwaysOn
        let kick = on ? engine.kickPulse : 0
        let disc = Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        let hot = on ? Theme.hot : Color(white: 0.22), heat = on ? Theme.heat : Color(white: 0.30)
        let deep = mix(hot, .black, 0.55)
        let st = style
        let atm = st.atmosphere

        // Rings (if this planet has them): the far half goes behind the planet.
        if st.rings { drawRings(ctx, c: c, R: R, front: false, color: heat, on: on) }

        // Thin atmosphere: a tight bright shell on the limb plus two faint outer layers.
        if on {
            let r2 = R * 1.1
            let shell = Gradient(stops: [
                .init(color: heat.opacity(0), location: 0.96 / 1.1),
                .init(color: heat.opacity(min(1, (0.42 + 0.3 * kick) * atm)), location: 1.0 / 1.1),
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
        let spin = PlanetSpin.shared.advance(t, on: on, rate: st.spin)
        // The surface leans with the planet's axial tilt.
        surface.translateBy(x: c.x, y: c.y); surface.rotate(by: .radians(st.tilt)); surface.translateBy(x: -c.x, y: -c.y)

        let look = Self.colors(st.kind)
        func tint(_ col: Color) -> Color { on ? mix(col, hot, 0.15) : mix(col, Color(white: 0.25), 0.7) }

        if st.kind == .gasGiant || st.kind == .toxic {
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
                    let lon = asin(max(-1, min(1, x / ring))) + spin * (1 + 0.04 * Double(i))
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
        if facing > 0 {
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

        // Sphere shading: a soft specular highlight top-left, the night side bottom-right.
        let light = CGPoint(x: c.x - R * 0.38, y: c.y - R * 0.42)
        surface.fill(disc, with: .radialGradient(Gradient(colors: [.white.opacity(on ? 0.42 : 0.12), .white.opacity(0)]),
                                                 center: light, startRadius: 0, endRadius: R * 0.75))
        surface.fill(disc, with: .radialGradient(Gradient(stops: [
            .init(color: .black.opacity(0), location: 0.45),
            .init(color: .black.opacity(on ? 0.55 : 0.75), location: 0.85),
            .init(color: .black.opacity(on ? 0.8 : 0.9), location: 1),
        ]), center: CGPoint(x: c.x - R * 0.3, y: c.y - R * 0.3), startRadius: 0, endRadius: R * 1.45))

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

        // Limb: the thin bright edge of the atmosphere on the lit side.
        if on {
            ctx.stroke(disc, with: .linearGradient(Gradient(colors: [mix(heat, .white, 0.5).opacity(0.9), heat.opacity(0.0)]),
                                                   startPoint: CGPoint(x: c.x - R, y: c.y - R), endPoint: CGPoint(x: c.x + R * 0.4, y: c.y + R * 0.4)),
                       lineWidth: 1.4)
        }

        // Rings: the near half crosses in front of the planet.
        if st.rings { drawRings(ctx, c: c, R: R, front: true, color: heat, on: on) }
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
        }
    }

    /// Thin ellipses at the ring's tilt; `front` draws the half nearer the camera.
    private func drawRings(_ ctx: GraphicsContext, c: CGPoint, R: Double, front: Bool, color: Color, on: Bool) {
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: .radians(style.ringTilt))
        g.clip(to: Path(CGRect(x: -R * 2, y: front ? 0 : -R * 2, width: R * 4, height: R * 2)))
        let inner = R * 1.18, outer = R * (1.18 + style.ringWidth)
        let lines = 6
        for k in 0..<lines {
            let rx = inner + (outer - inner) * Double(k) / Double(lines - 1), ry = rx * 0.24
            let alpha = (on ? 0.5 : 0.18) * (0.5 + 0.5 * sin(Double(k) * 2.1 + style.ringWidth * 9)) * (front ? 1 : 0.6)
            g.stroke(Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)), with: .color(color.opacity(alpha)), lineWidth: 1.6)
        }
    }
}
