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

    func advance(_ t: Double, on: Bool) -> Double {
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
            lon += dt * 0.35
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !engine.enabled)) { tl in
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
        let on = engine.enabled
        let kick = on ? engine.kickPulse : 0
        let disc = Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        let hot = on ? Theme.hot : Color(white: 0.22), heat = on ? Theme.heat : Color(white: 0.30)
        let deep = mix(hot, .black, 0.55)

        // Atmosphere halo, outside the disc: brighter on the lit (top-left) side, flares on kicks.
        if on {
            let glow = Gradient(stops: [
                .init(color: heat.opacity(0), location: 0.80),
                .init(color: heat.opacity(0.55 + 0.35 * kick), location: 0.84),
                .init(color: hot.opacity(0.18 + 0.2 * kick), location: 0.92),
                .init(color: hot.opacity(0), location: 1),
            ])
            let r2 = R / 0.82
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r2, y: c.y - r2, width: r2 * 2, height: r2 * 2)),
                     with: .radialGradient(glow, center: CGPoint(x: c.x - R * 0.08, y: c.y - R * 0.08), startRadius: 0, endRadius: r2))
        }

        // Surface: latitude bands with wavy edges, each flowing at its own speed.
        var surface = ctx
        surface.clip(to: disc)
        surface.fill(disc, with: .color(deep))
        let bands = 9
        let palette = [deep, hot, mix(hot, heat, 0.5), heat, mix(heat, .white, 0.25), heat, mix(hot, heat, 0.3), hot, deep]
        for i in 0..<bands {
            let y0 = -R + Double(i) * 2 * R / Double(bands)
            let speed = (i % 2 == 0 ? 1.0 : -0.7) * (0.25 + 0.08 * Double(i))
            let phase = t * speed + Double(i) * 1.7
            var p = Path()
            let steps = 24
            for s in 0...steps {
                let x = -R + Double(s) / Double(steps) * 2 * R
                let y = y0 + sin(x / R * 3 + phase) * R * 0.05 + sin(x / R * 7 - phase * 1.3) * R * 0.02
                if s == 0 { p.move(to: CGPoint(x: c.x + x, y: c.y + y)) } else { p.addLine(to: CGPoint(x: c.x + x, y: c.y + y)) }
            }
            p.addLine(to: CGPoint(x: c.x + R, y: c.y + R)); p.addLine(to: CGPoint(x: c.x - R, y: c.y + R)); p.closeSubpath()
            surface.fill(p, with: .color(palette[i].opacity(0.9)))
        }
        // A storm drifting across the face, squeezed toward the limb like a real feature on a sphere.
        let lon = (t * 0.25).truncatingRemainder(dividingBy: 2 * .pi) - .pi
        if cos(lon) > 0 {
            let sx = sin(lon) * R * 0.85, w = R * 0.34 * cos(lon), h = R * 0.16
            surface.fill(Path(ellipseIn: CGRect(x: c.x + sx - w / 2, y: c.y + R * 0.28 - h / 2, width: w, height: h)),
                         with: .color(mix(heat, .white, 0.35).opacity(0.75 * cos(lon))))
        }

        // The power icon, a feature on the equator: foreshortened toward the limb, hidden round the back.
        let iconLon = PlanetSpin.shared.advance(t, on: on)
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

        // Limb: the thin bright edge of the atmosphere on the lit side.
        if on {
            ctx.stroke(disc, with: .linearGradient(Gradient(colors: [mix(heat, .white, 0.5).opacity(0.9), heat.opacity(0.0)]),
                                                   startPoint: CGPoint(x: c.x - R, y: c.y - R), endPoint: CGPoint(x: c.x + R * 0.4, y: c.y + R * 0.4)),
                       lineWidth: 1.4)
        }
    }
}
