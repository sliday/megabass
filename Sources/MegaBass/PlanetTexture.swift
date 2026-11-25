import AppKit
import Foundation
import SwiftUI
import simd

/// Crisp planet surfaces from fractal noise. Each style bakes, once and off the main thread, a
/// 1024x512 latitude/longitude texture: fractal Brownian motion (6 octaves of 3D value noise sampled
/// on the sphere itself, so no seams and no pinched poles), ridged noise for cracks and ridges, and
/// domain warping for swirls; type rules turn that into oceans, coasts, dunes, ice, lava, craters.
/// Every frame then maps each disc pixel back to latitude/longitude (spin + axial tilt), samples it
/// and lights it per pixel: a table lookup, so rotation costs almost nothing.
final class PlanetTexture: @unchecked Sendable {
    static let W = 768, H = 384
    let surface: [SIMD3<Float>]      // albedo
    let clouds: [Float]              // cloud cover 0...1 (drifts faster than the ground)
    let glow: [SIMD3<Float>]         // emissive light (lava, radiation, star seams, city lights)
    let hasGlow: Bool
    let height: [Float]              // relief for bump lighting
    let spec: [Float]                // specular strength (water and ice shine, rock doesn't)
    let kind: PlanetStyle.Kind

    // MARK: Noise

    private init(surface: [SIMD3<Float>], clouds: [Float], glow: [SIMD3<Float>], hasGlow: Bool, height: [Float], spec: [Float], kind: PlanetStyle.Kind) {
        self.surface = surface; self.clouds = clouds; self.glow = glow; self.hasGlow = hasGlow
        self.height = height; self.spec = spec; self.kind = kind
    }

    /// Cellular (Worley) noise on the sphere: distances to the nearest and second-nearest feature
    /// points. F2 - F1 is small along the seams between cells: the plates of a star.
    private static func worley(_ perm: Perm, _ p: SIMD3<Float>, freq: Float) -> (Float, Float) {
        let q = p * freq
        let cx = Int(floor(q.x)), cy = Int(floor(q.y)), cz = Int(floor(q.z))
        var f1: Float = 9, f2: Float = 9
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
            let x = cx + dx, y = cy + dy, z = cz + dz
            let jitter = SIMD3<Float>(lattice(perm, x, y, z), lattice(perm, x + 31, y + 17, z + 5), lattice(perm, x + 7, y + 43, z + 29))
            let d = simd_length(SIMD3<Float>(Float(x), Float(y), Float(z)) + jitter - q)
            if d < f1 { f2 = f1; f1 = d } else if d < f2 { f2 = d }
        }}}
        return (f1, f2)
    }

    private static func makePerm(_ seed: UInt64) -> [Int] {
        var r = PlanetStyle.SplitMix64(state: seed)
        var p = Array(0..<256)
        for i in stride(from: 255, to: 0, by: -1) { p.swapAt(i, Int(r.next() % UInt64(i + 1))) }
        return p + p
    }

    typealias Perm = UnsafePointer<Int32>

    @inline(__always) private static func lattice(_ perm: Perm, _ x: Int, _ y: Int, _ z: Int) -> Float {
        Float(perm[Int(perm[Int(perm[x & 255]) + (y & 255)]) + (z & 255)]) * (1 / 255)
    }

    /// Smooth 3D value noise, 0...1.
    private static func noise(_ perm: Perm, _ x: Float, _ y: Float, _ z: Float) -> Float {
        let xi = Int(floor(x)), yi = Int(floor(y)), zi = Int(floor(z))
        let xf = x - floor(x), yf = y - floor(y), zf = z - floor(z)
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf), w = zf * zf * (3 - 2 * zf)
        func l(_ a: Int, _ b: Int, _ c: Int) -> Float { lattice(perm, xi + a, yi + b, zi + c) }
        let x00 = l(0, 0, 0) + (l(1, 0, 0) - l(0, 0, 0)) * u, x10 = l(0, 1, 0) + (l(1, 1, 0) - l(0, 1, 0)) * u
        let x01 = l(0, 0, 1) + (l(1, 0, 1) - l(0, 0, 1)) * u, x11 = l(0, 1, 1) + (l(1, 1, 1) - l(0, 1, 1)) * u
        let y0 = x00 + (x10 - x00) * v, y1 = x01 + (x11 - x01) * v
        return y0 + (y1 - y0) * w
    }

    /// Fractal Brownian motion: octaves of noise, each twice the frequency and half the amplitude.
    private static func fbm(_ perm: Perm, _ p: SIMD3<Float>, octaves: Int, freq: Float) -> Float {
        var sum: Float = 0, amp: Float = 0.5, f = freq, norm: Float = 0
        for o in 0..<octaves {
            sum += amp * noise(perm, p.x * f + Float(o) * 17.3, p.y * f, p.z * f)
            norm += amp; amp *= 0.5; f *= 2.03
        }
        return sum / norm
    }

    /// Ridged multifractal: sharp crests where the noise crosses its middle (cracks, ridges, veins).
    private static func ridged(_ perm: Perm, _ p: SIMD3<Float>, octaves: Int, freq: Float) -> Float {
        var sum: Float = 0, amp: Float = 0.5, f = freq, norm: Float = 0
        for o in 0..<octaves {
            let n = 1 - abs(noise(perm, p.x * f, p.y * f + Float(o) * 9.1, p.z * f) * 2 - 1)
            sum += amp * n * n
            norm += amp; amp *= 0.5; f *= 2.1
        }
        return sum / norm
    }

    // MARK: Bake

    typealias RGB = SIMD3<Float>
    static func hexF(_ v: UInt32) -> RGB { RGB(Float(v >> 16 & 0xFF) / 255, Float(v >> 8 & 0xFF) / 255, Float(v & 0xFF) / 255) }

    static func bake(style st: PlanetStyle, hot: RGB, heat: RGB) -> PlanetTexture {
        let permArray = makePerm(PlanetStyle.fnv1a(st.key)).map { Int32($0) }
        let permPtr = UnsafeMutablePointer<Int32>.allocate(capacity: permArray.count)
        permPtr.initialize(from: permArray, count: permArray.count)
        defer { permPtr.deallocate() }
        let perm = Perm(permPtr)
        let W = Self.W, H = Self.H
        var surface = [RGB](repeating: .zero, count: W * H)
        var clouds = [Float](repeating: 0, count: W * H)
        var glow = [RGB](repeating: .zero, count: W * H)
        var height = [Float](repeating: 0, count: W * H)
        var spec = [Float](repeating: 0, count: W * H)
        let hasGlow = [PlanetStyle.Kind.inferno, .radiated, .star, .terran, .jungle, .ocean, .crystal, .mana, .disco, .eyeball, .plasma].contains(st.kind)
        let starTint: RGB = [hexF(0xFF5A3A), hexF(0xFF9A3A), hexF(0xFFD86A), hexF(0xFFF4D6), hexF(0xBFD8FF)][st.starClass]
        func hex(_ v: UInt32) -> RGB { RGB(Float(v >> 16 & 0xFF) / 255, Float(v >> 8 & 0xFF) / 255, Float(v & 0xFF) / 255) }
        func mix(_ a: RGB, _ b: RGB, _ t: Float) -> RGB { a + (b - a) * max(0, min(1, t)) }
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
        // Craters at hashed points on the sphere.
        var r = PlanetStyle.SplitMix64(state: PlanetStyle.fnv1a(st.key + "craters"))
        let craterCount: Int = switch st.kind { case .barren: 70; case .desert, .radiated: 22; case .inferno, .ice: 12; default: 0 }
        let craters: [(p: RGB, r: Float)] = (0..<craterCount).map { _ in
            let z = Float(r.range(-1, 1)), a = Float(r.range(0, 2 * .pi)), s = sqrt(1 - z * z)
            return (RGB(s * cos(a), s * sin(a), z), Float(pow(r.unit(), 2.2) * 0.16 + 0.015))
        }
        let tint: Float = 0.12
        // A detail layer from another noise family, multiplied in for variety (its own hash, so the
        // rest of the style stays as it was): cells, veins, marble, strata or speckle.
        var lr = PlanetStyle.SplitMix64(state: PlanetStyle.fnv1a(st.key + "layer"))
        let layerPick = lr.unit()
        let layer: Int = switch st.kind {
        case .star, .crystal, .eightBall, .mana, .disco, .eyeball, .plasma, .pearl, .mercury: 0
        case .gasGiant: layerPick < 0.4 ? 0 : (layerPick < 0.7 ? 3 : 4)
        default: layerPick < 0.2 ? 0 : 1 + Int(min(4.999, (layerPick - 0.2) / 0.8 * 5))
        }
        let layerMix = Float(lr.range(0.3, 0.6)), layerFreq = Float(lr.range(2.5, 6))
        let layerOff = Float(lr.range(0, 50))

        DispatchQueue.concurrentPerform(iterations: H) { y in
            let lat = (0.5 - (Float(y) + 0.5) / Float(H)) * .pi
            for x in 0..<W {
                let lon = (Float(x) + 0.5) / Float(W) * 2 * .pi
                let p = RGB(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
                // Domain warp: bend the coordinates by noise for organic coasts and swirls.
                let warp = RGB(fbm(perm, p + 3.1, octaves: 2, freq: 1.6), fbm(perm, p + 7.7, octaves: 2, freq: 1.6), fbm(perm, p + 1.3, octaves: 2, freq: 1.6)) - 0.5
                let q = p + warp * 0.55
                let h = fbm(perm, q, octaves: 6, freq: 1.9)              // height
                let fine = fbm(perm, p, octaves: 4, freq: 9)             // grain
                let ridge = ridged(perm, q, octaves: 4, freq: 2.4)
                let absLat = abs(lat) / (.pi / 2)
                var col: RGB
                var emit = RGB.zero
                var relief = h + ridge * 0.25 + (fine - 0.5) * 0.15
                var shine: Float = 0.06
                switch st.kind {
                case .terran, .ocean, .jungle:
                    let sea: Float = st.kind == .ocean ? 0.6 : (st.kind == .jungle ? 0.4 : 0.5)
                    if h < sea {
                        col = mix(hex(0x0B2A5B), hex(0x2F7FB8), smooth(sea - 0.18, sea, h))            // deep to shallow
                        col = mix(col, hex(0x6FC3D8), smooth(sea - 0.012, sea, h) * 0.6)                // surf line
                        relief = sea; shine = 1                                                           // flat, glossy water
                    } else {
                        // City lights on land, seen only on the night side.
                        let city = smooth(0.66, 0.74, fbm(perm, p, octaves: 2, freq: 28)) * smooth(sea + 0.02, sea + 0.1, h) * (1 - smooth(0.75, 0.85, (h - sea) / (1 - sea)))
                        emit = RGB(1, 0.78, 0.42) * city * 0.9
                        let up = (h - sea) / (1 - sea)
                        let low = st.kind == .jungle ? hex(0x1F5A1F) : hex(0x3E7A35)
                        col = mix(low, st.kind == .jungle ? hex(0x2E7A2A) : hex(0x8C7A4A), smooth(0.05, 0.45, up + (fine - 0.5) * 0.3))
                        col = mix(col, hex(0x6B5A44), smooth(0.45, 0.75, up + ridge * 0.25))           // highlands
                        col = mix(col, hex(0xF2F4F6), smooth(0.78, 0.92, up + ridge * 0.15))           // peaks
                    }
                    let cap = Float(st.caps)
                    if cap > 0 { col = mix(col, hex(0xEEF4F8), smooth(1 - cap * 0.9, 1 - cap * 0.75, absLat + (fine - 0.5) * 0.12)) }
                case .desert:
                    let dunes = 0.5 + 0.5 * sin((q.x * 9 + q.z * 5 + h * 6) * 2.2)
                    col = mix(hex(0xA9743E), hex(0xE2BE84), smooth(0.2, 0.9, h * 0.6 + dunes * 0.4))
                    col = mix(col, hex(0x7C5230), smooth(0.62, 0.82, ridge) * 0.55)
                case .tundra:
                    col = mix(hex(0x5E6E76), hex(0xA9BAC2), smooth(0.3, 0.7, h + (fine - 0.5) * 0.2))
                    col = mix(col, hex(0xF0F5F8), smooth(0.55, 0.7, h * 0.5 + absLat * 0.8 + (fine - 0.5) * 0.15))
                case .ice:
                    shine = 0.6
                    col = mix(hex(0xB8D6EC), hex(0xF2F8FC), smooth(0.25, 0.8, h + (fine - 0.5) * 0.2))
                    col = mix(col, hex(0x5E95C4), smooth(0.86, 0.97, ridge) * 0.8)                     // fractures
                case .barren:
                    col = mix(hex(0x55524E), hex(0x9C978F), smooth(0.2, 0.85, h * 0.7 + fine * 0.3))
                case .radiated:
                    col = mix(hex(0x2A2E14), hex(0x5C6430), smooth(0.25, 0.8, h * 0.7 + fine * 0.3))
                    let vein = smooth(0.74, 0.9, ridge)
                    emit = hex(0xC6FF3A) * vein * 1.5
                case .toxic:
                    let band = 0.5 + 0.5 * sin(lat * 9 + (h - 0.5) * 7)
                    col = mix(hex(0x5E6A18), hex(0xC8D04A), smooth(0.2, 0.9, band * 0.7 + fine * 0.3))
                case .inferno:
                    col = mix(hex(0x150A08), hex(0x3A1F18), smooth(0.2, 0.8, h * 0.6 + fine * 0.4))
                    let lava = smooth(0.7, 0.88, ridge) + smooth(0.66, 0.8, h) * 0.7
                    emit = mix(hex(0xFF3A0E), hex(0xFFD27A), smooth(0.88, 0.98, ridge)) * min(1.6, lava * 1.4)
                case .star:
                    // Plates of cooler crust; the seams between them blaze with light from the core.
                    let (f1, f2) = worley(perm, q, freq: 5.5)
                    let seam = 1 - smooth(0.0, 0.09, f2 - f1)
                    let (g1, g2) = worley(perm, p, freq: 17)
                    let small = 1 - smooth(0.0, 0.07, g2 - g1)
                    col = starTint * (0.35 + 0.35 * h + 0.2 * (1 - f1))
                    emit = mix(starTint, RGB(1, 1, 0.95), 0.6) * (seam * 1.4 + small * 0.45)
                    relief = 0.5 + (1 - seam) * 0.25 + (1 - f1) * 0.15
                    shine = 0
                case .crystal:
                    // Clear glass, a slow mist swirling inside lit in the palette.
                    let m = fbm(perm, q * 1.4 + warp * 1.5, octaves: 5, freq: 2)
                    let mist = smooth(0.45, 0.85, m)
                    col = mix(hex(0x0C1018), hot * 0.25, 0.5)
                    emit = mix(hot, RGB(1, 1, 1), 0.35) * mist * 0.75 + heat * 0.12 * (1 - absLat)
                    relief = 0.5; shine = 1
                case .eightBall:
                    // Glossy black; a white disc opposite the power icon with an 8 (two rings) on it.
                    col = hex(0x0A0A0C); relief = 0.5; shine = 1
                    let d = acos(max(-1, min(1, -p.x)))                            // from longitude 180°, equator
                    if d < 0.52 {
                        let u = -p.y / 0.5, v = p.z / 0.5
                        func ring(_ cy: Float, _ rr: Float) -> Float { smooth(0.075, 0.045, abs(hypot(u, v - cy) - rr)) }
                        let ink = max(ring(0.27, 0.2), ring(-0.22, 0.25))
                        col = mix(col, mix(hex(0xF4F1EA), hex(0x0A0A0C), ink), smooth(0.52, 0.49, d))
                        shine = 0.8
                    }
                case .mana:
                    // The liquid: a glowing swirl (the render fills it to a level that follows the song).
                    let m = fbm(perm, q * 1.6 + warp * 2, octaves: 5, freq: 2.2)
                    let swirl = 0.5 + 0.5 * sin(lon * 3 + m * 9)
                    col = mix(hot * 0.35, heat * 0.6, swirl)
                    emit = mix(hot, heat, swirl) * (0.45 + 0.6 * smooth(0.5, 0.85, m))
                    relief = 0.5 + (m - 0.5) * 0.1; shine = 0.8
                case .disco:
                    // Mirror tiles in rows, grout between; some catch the palette, a few glint.
                    let rows: Float = 26
                    let rf = (lat / .pi + 0.5) * rows, row = floor(rf)
                    let cols = max(6, floor(cos((row + 0.5) / rows * .pi - .pi / 2) * 52))
                    let cf = lon / (2 * .pi) * cols, cell = floor(cf)
                    let fr = rf - row, fc = cf - cell
                    func hsh(_ k: Float) -> Float { let x = sin(row * 127.1 + cell * 311.7 + k * 74.7) * 43758.5453; return x - floor(x) }
                    let grout = fr < 0.08 || fr > 0.92 || fc < 0.08 || fc > 0.92
                    let tone = 0.55 + 0.45 * hsh(1), pick = hsh(2)
                    let silver = hex(0xC8CCD2) * tone
                    let tile = pick < 0.16 ? mix(silver, hot, 0.6) : (pick < 0.28 ? mix(silver, heat, 0.6) : silver)
                    col = grout ? hex(0x222428) : tile
                    relief = grout ? 0.35 : 0.5 + (hsh(3) - 0.5) * 0.25
                    shine = grout ? 0 : 1
                    if !grout && hsh(4) > 0.95 { emit = RGB(1, 1, 1) * 0.9 }
                case .eyeball:
                    // After real-time eye shaders: a warm off-white sclera that reddens toward the back with
                    // a vein network; an iris (sized like a real one) of radial fibres, a collarette ring,
                    // dark crypts and two tones; a dark limbal ring; a wet cornea. The iris sits where the
                    // power icon is, and the eye turns to look at you (see EyeLook).
                    let d = acos(max(-1, min(1, p.x)))
                    col = mix(hex(0xEDE3D9), hex(0xD8B4A8), smooth(1.1, 2.6, d)) * (0.94 + 0.06 * fine)
                    let veins = smooth(0.76, 0.9, ridged(perm, q * 1.2, octaves: 4, freq: 3.2))
                    let fineVeins = smooth(0.8, 0.93, ridged(perm, q * 2.6 + 4, octaves: 3, freq: 5))
                    col = mix(col, hex(0x9E2228), max(veins * 0.75, fineVeins * 0.45) * smooth(0.65, 1.9, d))
                    shine = 0.55
                    relief = 0.5 + 0.12 * smooth(0.62, 0, d)                                  // the cornea's bulge
                    if d < 0.6 {
                        let t = d / 0.55, phi = atan2(p.z, p.y)
                        let fib = fbm(perm, SIMD3(cos(phi) * 6, sin(phi) * 6, t * 1.5), octaves: 3, freq: 2)
                        let collar = smooth(0.06, 0, abs(t - 0.38 - 0.03 * sin(phi * 9)))
                        let crypt = worley(perm, SIMD3(cos(phi) * 4, sin(phi) * 4, t * 3), freq: 3).0
                        let zone = mix(mix(heat, hex(0xC88A3A), 0.45), hot * 0.7, smooth(0.32, 0.46, t))
                        var iris = zone * (0.5 + 0.7 * fib) + mix(heat, RGB(1, 1, 1), 0.3) * collar * 0.25
                        iris = iris * (1 - 0.5 * smooth(0.14, 0.04, crypt) * smooth(0.4, 0.55, t))   // crypts
                        iris = iris * (1 - 0.75 * smooth(0.78, 1, t))                               // limbal ring
                        col = mix(col, iris, smooth(0.58, 0.53, d))
                        col = mix(col, hex(0x030303), smooth(0.21, 0.19, d))                         // pupil
                        emit = iris * 0.3 * smooth(0.55, 0.3, d) * smooth(0.19, 0.23, d)
                        shine = 1
                    }
                case .mercury:
                    // Liquid metal: the look comes from reflections in the render.
                    col = hex(0x9AA0A8); relief = 0.5; shine = 1
                case .plasma:
                    // Dark glass; the filaments are drawn live over it.
                    col = hex(0x07070D) + heat * 0.05
                    emit = heat * 0.06 * (1 - absLat * 0.5)
                    relief = 0.5; shine = 1
                case .pearl:
                    // Nacre: cream with a thin-film shimmer of every hue.
                    let t = fbm(perm, q, octaves: 3, freq: 2.5) * 1.6 + lat * 0.8
                    let ir = RGB(0.5 + 0.5 * cos(2 * .pi * t), 0.5 + 0.5 * cos(2 * .pi * (t + 0.33)), 0.5 + 0.5 * cos(2 * .pi * (t + 0.67)))
                    col = mix(hex(0xF1EAE0), ir, 0.22) * (0.95 + 0.05 * fine)
                    relief = 0.5 + (fine - 0.5) * 0.04; shine = 0.9
                case .gasGiant:
                    // Turbulent bands: latitude bent by the domain warp and the height field.
                    let latW = lat + warp.z * 0.45 + (h - 0.5) * Float(st.wave) * 6
                    let band = 0.5 + 0.5 * sin(latW * Float(st.bands) * 1.6 + (fine - 0.5) * 1.5)
                    let deep = hot * 0.45
                    col = mix(mix(deep, hot, smooth(0.15, 0.55, band)), mix(heat, RGB(1, 1, 1), 0.25), smooth(0.55, 0.95, band + (fine - 0.5) * 0.25))
                }
                // Craters: a dark bowl with a bright rim.
                for c in craters {
                    let d = simd_length(p - c.p)
                    if d < c.r * 1.25 {
                        let bowl = 1 - smooth(c.r * 0.55, c.r, d), rim = smooth(c.r * 0.8, c.r, d) * (1 - smooth(c.r, c.r * 1.25, d))
                        col = col * (1 - 0.4 * bowl) + RGB(repeating: 0.25) * rim
                    }
                }
                if st.kind != .gasGiant && st.kind != .star && !st.kind.isCurio { col = mix(col, hot, tint) }     // a hint of the station palette
                if st.kind == .gasGiant { shine = 0.15 }
                if !st.kind.isCurio { col = col * (0.88 + 0.24 * fine) }                       // fine grain
                if layer > 0 {
                    let lp = p + layerOff
                    let d: Float
                    switch layer {
                    case 1: let w = worley(perm, lp, freq: layerFreq); d = smooth(0, 0.12, w.1 - w.0)          // cells
                    case 2: d = 1 - ridged(perm, q + layerOff, octaves: 3, freq: layerFreq)                   // veins
                    case 3: d = 0.5 + 0.5 * sin(layerFreq * (p.z * 2 + fbm(perm, q + layerOff, octaves: 3, freq: 2) * 5))   // marble
                    case 4: d = fbm(perm, SIMD3(lp.x * 0.5, lp.y * 0.5, lp.z * 7), octaves: 4, freq: layerFreq * 0.6)       // strata
                    default: d = smooth(0.55, 0.75, fbm(perm, lp, octaves: 3, freq: layerFreq * 4))         // speckle
                    }
                    col = col * ((1 - layerMix) + layerMix * (0.45 + 1.1 * d))                // multiply
                    relief += (d - 0.5) * layerMix * 0.6
                }
                let i = y * W + x
                surface[i] = col
                glow[i] = emit
                height[i] = relief
                spec[i] = shine
                if st.kind == .terran || st.kind == .ocean || st.kind == .jungle || st.kind == .tundra || st.kind == .toxic {
                    let cl = fbm(perm, p * 1.3 + warp * 1.2 + 11, octaves: 4, freq: 2.6)
                    clouds[i] = smooth(st.kind == .toxic ? 0.45 : 0.55, 0.75, cl) * (st.kind == .toxic ? 0.6 : 0.85)
                }
            }
        }
        return PlanetTexture(surface: surface, clouds: clouds, glow: glow, hasGlow: hasGlow, height: height, spec: spec, kind: st.kind)
    }
}

/// Bakes textures off the main thread and renders the lit, rotating disc each frame.
@MainActor
final class PlanetTextures {
    static let shared = PlanetTextures()
    private var cache: [String: PlanetTexture] = [:]
    private var baking: Set<String> = []
    private let queue = DispatchQueue(label: "megabass.planet-bake", qos: .userInitiated)

    // Per-pixel sphere mapping for the current disc size and tilt.
    private var mapKey = ""
    private var latIdx: [Int32] = [], lonBase: [Float] = [], light: [Float] = [], inside: [Bool] = []
    private var normal: [SIMD3<Float>] = [], east: [SIMD3<Float>] = [], north: [SIMD3<Float>] = [], cosLat: [Float] = []
    private var latF: [Float] = []

    /// The power glyph as an alpha bitmap, drawn once; the renderer wraps it onto the sphere.
    private static let glyphSize = 128
    private lazy var glyph: [Float] = {
        let n = Self.glyphSize
        var px = [UInt8](repeating: 0, count: n * n)
        let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(n) * 0.78, weight: .bold)
        guard let img = NSImage(systemSymbolName: "power", accessibilityDescription: nil)?.withSymbolConfiguration(cfg),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return [Float](repeating: 0, count: n * n) }
        let w = CGFloat(cg.width), h = CGFloat(cg.height), k = min(CGFloat(n) * 0.86 / w, CGFloat(n) * 0.86 / h)
        let r = CGRect(x: (CGFloat(n) - w * k) / 2, y: (CGFloat(n) - h * k) / 2, width: w * k, height: h * k)
        ctx.clip(to: r, mask: cg)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(r)
        return px.map { Float($0) / 255 }
    }()

    @inline(__always) private func glyphAt(_ u: Float, _ v: Float) -> Float {
        let n = Self.glyphSize
        guard u >= 0, u < 1, v >= 0, v < 1 else { return 0 }
        return glyph[Int(v * Float(n)) * n + Int(u * Float(n))]
    }
    private var pixels: [UInt32] = []
    private var side = 0
    private var mapTilt = Double.nan

    private static func rgb(_ c: Color) -> SIMD3<Float> {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        return SIMD3(Float(n.redComponent), Float(n.greenComponent), Float(n.blueComponent))
    }

    /// The texture for a style. Never flickers: an exact hit returns at once; a new palette version
    /// of a planet keeps showing the previous one while it bakes; a planet seen for the first time is
    /// baked right here (6-15 ms, once) so the vector fallback never flashes.
    private var latest: [String: PlanetTexture] = [:]      // newest texture per planet
    private var order: [String] = []                       // cache keys, oldest first

    func texture(for st: PlanetStyle, hot: Color, heat: Color) -> PlanetTexture? {
        // Gas giants take their colours from the palette, so the palette is part of their key.
        let q = (Self.rgb(hot) * Float(12)).rounded(.toNearestOrEven)
        let key = st.kind == .gasGiant ? st.key + "|\(q)" : st.key
        if let t = cache[key] { latest[st.key] = t; return t }
        let h = Self.rgb(hot), e = Self.rgb(heat)
        if let prev = latest[st.key] {
            if !baking.contains(key) {
                baking.insert(key)
                queue.async {
                    let tex = PlanetTexture.bake(style: st, hot: h, heat: e)
                    DispatchQueue.main.async { self.baking.remove(key); self.store(tex, key: key, planet: st.key) }
                }
            }
            return prev
        }
        let t0 = Date()
        let tex = PlanetTexture.bake(style: st, hot: h, heat: e)
        if ProcessInfo.processInfo.environment["MB_PERF"] != nil {
            FileHandle.standardError.write("first bake \(st.kind.rawValue) \(Int(Date().timeIntervalSince(t0) * 1000)) ms\n".data(using: .utf8)!)
        }
        store(tex, key: key, planet: st.key)
        return tex
    }

    private func store(_ tex: PlanetTexture, key: String, planet: String) {
        cache[key] = tex
        latest[planet] = tex
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 6 { cache.removeValue(forKey: order.removeFirst()) }    // ~13 MB each; oldest first, never all
    }

    /// Renders the disc (2x resolution) into an image: texture lookup, clouds, per-pixel light, glow.
    /// `rim`: atmosphere colour at the limb. `grade`: the palette pair the surface is toned toward.
    func render(_ tex: PlanetTexture, radius R: Double, tilt: Double, spin: Double, on: Bool,
                rim rimColor: Color = .white, grade: (Color, Color)? = nil,
                flares: [(th: Double, power: Double)] = [], flareColor: Color = .white, icon: Bool = false,
                sun: Float = 1, iconColor: Color = .white, blur: Float = 0, pitch: Double = 0,
                liquid: Float = 2, time: Double = 0, wobble: Float = 0) -> CGImage? {
        let n = Int(R * 4)                                   // diameter at 2x
        let q = (pitch / 0.004).rounded()                    // the map rebuilds only while the nod moves
        let key = "\(n)|\(tilt)|\(q)"
        if key != mapKey { buildMap(n: n, tilt: tilt, pitch: q * 0.004); mapKey = key }
        let W = PlanetTexture.W
        // Minus spin: the surface turns rightward, the same way as the power icon.
        let shift = -Float(spin / (2 * .pi)) * Float(W)
        let cloudShift = -Float(spin * 1.25 / (2 * .pi)) * Float(W)
        let H = PlanetTexture.H
        let L = simd_normalize(SIMD3<Float>(-0.45, -0.5, 0.74)), V = SIMD3<Float>(0, 0, 1)
        let half = simd_normalize(L + V)
        let rimTint = Self.rgb(rimColor)
        let star = tex.kind == .star
        let mana = tex.kind == .mana, tt = Float(time.truncatingRemainder(dividingBy: 1000))
        let eye = tex.kind == .eyeball, mercury = tex.kind == .mercury
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
        // Flares as point lights just beyond the limb, a little toward the viewer (unit-sphere space).
        let flareTint = Self.rgb(flareColor)
        let lights: [(pos: SIMD3<Float>, power: Float)] = flares.prefix(6).map { f in
            (SIMD3(Float(cos(f.th)) * 1.12, Float(sin(f.th)) * 1.12, 0.3), Float(f.power))
        }
        // Colour grade: split-tone shadows toward the darkened first palette colour, highlights
        // toward the second, keeping luminance, so the planet sits inside the station's theme.
        let gradeLo = grade.map { Self.rgb($0.0) * 0.55 }, gradeHi = grade.map { Self.rgb($0.1) }
        // Power-icon decal on the equator at texture longitude 0: it turns with the surface, bends
        // over the sphere, and is counter-rotated by the tilt so it stays upright on screen.
        let iconHalf: Float = 0.46
        let blurPx = min(24, blur * Float(W))
        let tiltC = Float(cos(tilt)), tiltS = Float(sin(tilt))
        // On: the icon emits light in the palette's brightest colour (unshaded), with a halo.
        let iconLight = Self.rgb(iconColor)
        let iconBase: SIMD3<Float> = on ? iconLight + (SIMD3<Float>(repeating: 1) - iconLight) * 0.2 : SIMD3(0.62, 0.62, 0.64)
        for i in 0..<(n * n) {
            guard inside[i] else { pixels[i] = 0; continue }
            let u0 = lonBase[i]
            var u = Int(u0 + shift) % W; if u < 0 { u += W }
            var uc = Int(u0 + cloudShift) % W; if uc < 0 { uc += W }
            let v = Int(latIdx[i])
            let row = v * W
            var c = tex.surface[row + u]
            // Motion blur along the spin: average texels across the arc turned in one frame.
            if blurPx >= 1.5 {
                let b = Int(blurPx)
                c = (c + tex.surface[row + (u + b / 2) % W] + tex.surface[row + (u - b / 2 + W) % W]
                       + tex.surface[row + (u + b) % W]) * 0.25
            }
            let cl = tex.clouds[row + uc]
            c = c + (SIMD3<Float>(repeating: 0.97) - c) * cl
            var out: SIMD3<Float>
            var emitted = SIMD3<Float>.zero
            let nrm = normal[i]
            if star {
                // A star lights itself: limb-darkened crust plus blazing seams.
                out = c * (0.55 + 0.45 * nrm.z)
                emitted = tex.glow[row + u] * 1.3
            } else {
                // Bump: tilt the normal by the height slope (east/west and north/south neighbours).
                let ue = (u + 1) % W, uw = (u + W - 1) % W
                let vn = max(0, v - 1), vs = min(H - 1, v + 1)
                let sx = (tex.height[row + ue] - tex.height[row + uw]) * 7 / max(0.25, cosLat[i])
                let sy = (tex.height[vn * W + u] - tex.height[vs * W + u]) * 7
                let bumped = simd_normalize(nrm - (east[i] * sx + north[i] * sy) * (1 - cl))
                // Toy-like light: wrapped diffuse so the night side isn't pitch black.
                let lam = max(0, (simd_dot(bumped, L) + 0.2) / 1.2)
                out = c * (0.08 + 0.95 * pow(lam, 0.9) * sun)
                // Flare light: grazing light from each flare makes the bumps pop where it lands.
                for fl in lights {
                    let d = fl.pos - nrm
                    let dist2 = simd_length_squared(d)
                    let k = max(0, simd_dot(bumped, d / sqrt(dist2))) * fl.power * 1.6 / (1 + dist2 * 6)
                    if k > 0.002 { out += c * flareTint * k + flareTint * (k * k * 0.25) }
                }
                // Specular: glossy water and ice catch the sun; rock stays matte.
                let gloss = tex.spec[row + u] * (1 - cl)
                if gloss > 0.01 { out += SIMD3<Float>(repeating: pow(max(0, simd_dot(bumped, half)), 36) * 0.9 * gloss * sun) }
                // A wet eye: a crisp glint on the smooth cornea.
                if eye { out += SIMD3<Float>(repeating: pow(max(0, simd_dot(nrm, half)), 320) * 1.3 * sun) }
                // Emissive: lava and radiation glow everywhere; city lights only at night.
                if tex.hasGlow {
                    let g = tex.glow[row + u]
                    let night = tex.kind == .terran || tex.kind == .jungle || tex.kind == .ocean
                    emitted = g * (night ? pow(max(0, 1 - lam * 1.6), 2) * (1 - cl) : 0.55 + 0.45 * (1 - lam))
                }
                // Rim: a thin band of atmosphere colour at the limb, brighter on the lit side.
                out += rimTint * (pow(1 - nrm.z, 3) * (0.35 + 0.65 * lam) * 0.55 * (0.4 + 0.6 * sun))
            }
            if let lo = gradeLo, let hi = gradeHi {
                let lum = simd_dot(out, SIMD3<Float>(0.299, 0.587, 0.114))
                let tone = lo + (hi - lo) * min(1, lum * 1.3)
                let toned = tone * (lum / max(0.05, simd_dot(tone, SIMD3<Float>(0.299, 0.587, 0.114))))
                out = out + (toned - out) * 0.45
                let glum = simd_dot(emitted, SIMD3<Float>(0.299, 0.587, 0.114))
                emitted = emitted + (hi * glum * 1.2 - emitted) * 0.3
            }
            out += emitted
            if mercury {
                // Liquid metal: the view reflected off a rippling surface (ripples swell with the bass).
                // The environment: a dark sky over a palette-lit horizon, a softbox up left, and the glow
                // ring behind the planet showing at grazing angles.
                let w1 = sin(nrm.x * 9 + tt * 3.1) * sin(nrm.y * 7 - tt * 2.3), w2 = sin((nrm.x + nrm.y) * 13 + tt * 4.7)
                let n2 = simd_normalize(nrm + SIMD3<Float>(w1 * 0.6 + w2 * 0.3, w2 * 0.5 - w1 * 0.3, 0) * wobble)
                let r = n2 * (2 * n2.z) - V
                let up = -r.y
                let sky = SIMD3<Float>(0.05, 0.06, 0.09), ground = SIMD3<Float>(0.02, 0.02, 0.03)
                var env = up > 0 ? rimTint * 0.35 + (sky - rimTint * 0.35) * min(1, up * 1.4)
                                 : rimTint * 0.25 + (ground - rimTint * 0.25) * min(1, -up * 2)
                env += rimTint * 0.8 * exp(-up * up * 60)
                if r.x < -0.15 && r.x > -0.75 && up > 0.35 && up < 0.85 { env += SIMD3<Float>(repeating: 1.1) }
                env += rimTint * 0.6 * max(0, -r.z)
                out = env * SIMD3<Float>(0.86, 0.89, 0.93) * (0.85 + 0.3 * pow(1 - n2.z, 2))
            }
            if mana {
                // The orb is filled to `liquid` (screen y, down positive) with a rippling surface; above
                // it, empty dark glass with a rim; a bright meniscus where they meet.
                let wave = liquid + 0.035 * sin(nrm.x * 7 + tt * 2.4) + 0.02 * sin(nrm.x * 13 - tt * 3.7)
                if nrm.y < wave - 0.02 {
                    out = SIMD3<Float>(0.025, 0.03, 0.045) + rimTint * (pow(1 - nrm.z, 2.5) * 0.35) + out * 0.06
                } else if nrm.y < wave + 0.02 {
                    out += (rimTint * 0.6 + SIMD3<Float>(repeating: 0.4)) * (1 - abs(nrm.y - wave) / 0.02)
                }
            }
            if icon {
                // Longitude on the texture, relative to the decal, wrapped to -pi...pi.
                var dl = (lonBase[i] + shift) / Float(W) * 2 * .pi
                dl = dl - (2 * .pi) * floor((dl + .pi) / (2 * .pi))
                let lat = latF[i]
                if abs(dl) < iconHalf * 1.6, abs(lat) < iconHalf * 1.6 {
                    let ex = dl * cosLat[i], ny2 = lat
                    let gx = ex * tiltC + ny2 * tiltS, gy = -ex * tiltS + ny2 * tiltC     // upright on screen
                    let gu = gx / (2 * iconHalf) + 0.5, gv = 0.5 - gy / (2 * iconHalf)
                    if eye {
                        // Caustic: the cornea focuses light onto the iris on the side away from the highlight.
                        let rr = hypot(gx, gy)
                        let band = smooth(0.17, 0.26, rr) * smooth(0.56, 0.42, rr)
                        let away = max(0, (gx - gy) / max(0.001, rr * 1.414))
                        out += out * band * away * away * 1.4
                    }
                    let a = glyphAt(gu, gv)
                    if on {
                        // Glowing: a soft halo from the glyph sampled at 1.25x, then the lit glyph itself.
                        let halo = glyphAt((gu - 0.5) * 0.8 + 0.5, (gv - 0.5) * 0.8 + 0.5) * 0.5
                            + glyphAt((gu - 0.5) * 0.65 + 0.5, (gv - 0.5) * 0.65 + 0.5) * 0.25
                        out += iconLight * halo * (1 - a) * 0.55
                        // Screen blend: the glyph only ever adds light, never greys the surface under it.
                        if a > 0.01 { out = SIMD3<Float>(repeating: 1) - (SIMD3<Float>(repeating: 1) - out) * (SIMD3<Float>(repeating: 1) - simd_min(iconBase * 1.15, SIMD3<Float>(repeating: 1)) * a) }
                    } else {
                        let shadow = glyphAt(gu - 0.035, gv - 0.035)
                        if shadow > 0.01 { out *= 1 - shadow * 0.45 * (1 - a) }           // soft drop shadow
                        if a > 0.01 {
                            let lam = max(0, (simd_dot(nrm, L) + 0.25) / 1.25)
                            let ink = simd_min(iconBase * (0.3 + 0.75 * lam), SIMD3<Float>(repeating: 1)) * a * 0.94
                            out = SIMD3<Float>(repeating: 1) - (SIMD3<Float>(repeating: 1) - out) * (SIMD3<Float>(repeating: 1) - ink)   // screen
                        }
                    }
                }
            }
            if !on {
                let g = (out.x + out.y + out.z) / 3 * 0.45
                out = SIMD3(repeating: g)
            }
            let rr = UInt32(max(0, min(255, out.x * 255))), gg = UInt32(max(0, min(255, out.y * 255))), bb = UInt32(max(0, min(255, out.z * 255)))
            pixels[i] = 0xFF00_0000 | (bb << 16) | (gg << 8) | rr
        }
        // Copy the pixels into the image: the buffer is reused next frame.
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func buildMap(n: Int, tilt: Double, pitch: Double = 0) {
        // A nod alone (same size and tilt) keeps the buffers, the lighting and the normals.
        let fresh = n != side || tilt != mapTilt || latIdx.count != n * n
        side = n; mapTilt = tilt
        if fresh {
            latIdx = .init(repeating: 0, count: n * n); lonBase = .init(repeating: 0, count: n * n)
            light = .init(repeating: 0, count: n * n); inside = .init(repeating: false, count: n * n)
            normal = .init(repeating: .zero, count: n * n); east = .init(repeating: .zero, count: n * n)
            north = .init(repeating: .zero, count: n * n); cosLat = .init(repeating: 1, count: n * n)
            latF = .init(repeating: 0, count: n * n)
            pixels = .init(repeating: 0, count: n * n)
        }
        let L = simd_normalize(SIMD3<Float>(-0.45, -0.5, 0.74))          // light from top-left, toward the viewer
        let ct = Float(cos(-tilt)), stl = Float(sin(-tilt))
        let cp = Float(cos(pitch)), sp = Float(sin(pitch))
        for y in 0..<n {
            for x in 0..<n {
                let nx = (Float(x) + 0.5) / Float(n) * 2 - 1, ny = (Float(y) + 0.5) / Float(n) * 2 - 1
                let d2 = nx * nx + ny * ny
                let i = y * n + x
                guard d2 <= 1 else { continue }
                inside[i] = true
                let z = sqrt(1 - d2)
                // Nod: tip the top toward the viewer (around the screen's x axis). Then undo the
                // axial tilt (around the view axis) and read latitude/longitude.
                let py = ny * cp - z * sp, pz = ny * sp + z * cp
                let tx = nx * ct - py * stl, ty = nx * stl + py * ct
                let lat = asin(max(-1, min(1, -ty)))
                let lon = atan2(tx, pz)
                latIdx[i] = Int32(max(0, min(Float(PlanetTexture.H - 1), (0.5 - lat / .pi) * Float(PlanetTexture.H))))
                lonBase[i] = (lon / (2 * .pi) + 1) * Float(PlanetTexture.W)
                if fresh {
                    let lam = max(0, simd_dot(SIMD3(nx, ny, z), L))
                    light[i] = 0.1 + 0.95 * pow(lam, 0.8)
                    normal[i] = SIMD3(nx, ny, z)
                }
                // Surface frame in view space: east (+longitude), north (+latitude).
                let sl = sin(lon), cl = cos(lon), sa = sin(lat), ca = cos(lat)
                let eP = SIMD3<Float>(cl, 0, -sl), nP = SIMD3<Float>(-sa * sl, -ca, -sa * cl)
                func back(_ v: SIMD3<Float>) -> SIMD3<Float> {
                    let yp = -v.x * stl + v.y * ct
                    return SIMD3(v.x * ct + v.y * stl, yp * cp + v.z * sp, -yp * sp + v.z * cp)
                }
                east[i] = back(eP); north[i] = back(nP)
                cosLat[i] = ca
                latF[i] = lat
            }
        }
    }
}
