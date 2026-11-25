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
    let glow: [SIMD3<Float>]         // emissive light (lava, radiation), not shaded by the night side
    let hasGlow: Bool

    // MARK: Noise

    private init(surface: [SIMD3<Float>], clouds: [Float], glow: [SIMD3<Float>], hasGlow: Bool) {
        self.surface = surface; self.clouds = clouds; self.glow = glow; self.hasGlow = hasGlow
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
        let hasGlow = st.kind == .inferno || st.kind == .radiated
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
                switch st.kind {
                case .terran, .ocean, .jungle:
                    let sea: Float = st.kind == .ocean ? 0.6 : (st.kind == .jungle ? 0.4 : 0.5)
                    if h < sea {
                        col = mix(hex(0x0B2A5B), hex(0x2F7FB8), smooth(sea - 0.18, sea, h))            // deep to shallow
                        col = mix(col, hex(0x6FC3D8), smooth(sea - 0.012, sea, h) * 0.6)                // surf line
                    } else {
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
                if st.kind != .gasGiant { col = mix(col, hot, tint) }                         // a hint of the station palette
                col = col * (0.88 + 0.24 * fine)                                                // fine grain
                let i = y * W + x
                surface[i] = col
                glow[i] = emit
                if st.kind == .terran || st.kind == .ocean || st.kind == .jungle || st.kind == .tundra || st.kind == .toxic {
                    let cl = fbm(perm, p * 1.3 + warp * 1.2 + 11, octaves: 4, freq: 2.6)
                    clouds[i] = smooth(st.kind == .toxic ? 0.45 : 0.55, 0.75, cl) * (st.kind == .toxic ? 0.6 : 0.85)
                }
            }
        }
        return PlanetTexture(surface: surface, clouds: clouds, glow: glow, hasGlow: hasGlow)
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
    private var pixels: [UInt32] = []
    private var side = 0

    private static func rgb(_ c: Color) -> SIMD3<Float> {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        return SIMD3(Float(n.redComponent), Float(n.greenComponent), Float(n.blueComponent))
    }

    /// The texture for a style, or nil while it bakes (the caller draws the vector fallback).
    func texture(for st: PlanetStyle, hot: Color, heat: Color) -> PlanetTexture? {
        // Gas giants take their colours from the palette, so the palette is part of their key.
        let q = (Self.rgb(hot) * Float(12)).rounded(.toNearestOrEven)                       // palette quantised: fades re-bake a few times, not per frame
        let key = st.kind == .gasGiant ? st.key + "|\(q)" : st.key
        if let t = cache[key] { return t }
        if !baking.contains(key) {
            baking.insert(key)
            let h = Self.rgb(hot), e = Self.rgb(heat)
            queue.async {
                let t0 = Date()
                let tex = PlanetTexture.bake(style: st, hot: h, heat: e)
                if ProcessInfo.processInfo.environment["MB_BAKE_LOG"] != nil {
                    FileHandle.standardError.write("baked \(st.kind.rawValue) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms\n".data(using: .utf8)!)
                }
                DispatchQueue.main.async {
                    self.baking.remove(key)
                    if self.cache.count > 24 { self.cache.removeAll() }
                    self.cache[key] = tex
                }
            }
        }
        return nil
    }

    /// Renders the disc (2x resolution) into an image: texture lookup, clouds, per-pixel light, glow.
    func render(_ tex: PlanetTexture, radius R: Double, tilt: Double, spin: Double, on: Bool) -> CGImage? {
        let n = Int(R * 4)                                   // diameter at 2x
        let key = "\(n)|\(tilt)"
        if key != mapKey { buildMap(n: n, tilt: tilt); mapKey = key }
        let W = PlanetTexture.W
        let shift = Float(spin / (2 * .pi)) * Float(W)
        let cloudShift = Float(spin * 1.25 / (2 * .pi)) * Float(W)
        for i in 0..<(n * n) {
            guard inside[i] else { pixels[i] = 0; continue }
            let u0 = lonBase[i]
            var u = Int(u0 + shift) % W; if u < 0 { u += W }
            var uc = Int(u0 + cloudShift) % W; if uc < 0 { uc += W }
            let row = Int(latIdx[i]) * W
            var c = tex.surface[row + u]
            let cl = tex.clouds[row + uc]
            c = c + (SIMD3<Float>(repeating: 0.97) - c) * cl
            let l = light[i]
            var out = c * l
            if tex.hasGlow { out += tex.glow[row + u] * (0.55 + 0.45 * (1 - l)) }
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

    private func buildMap(n: Int, tilt: Double) {
        side = n
        latIdx = .init(repeating: 0, count: n * n); lonBase = .init(repeating: 0, count: n * n)
        light = .init(repeating: 0, count: n * n); inside = .init(repeating: false, count: n * n)
        pixels = .init(repeating: 0, count: n * n)
        let L = simd_normalize(SIMD3<Float>(-0.45, -0.5, 0.74))          // light from top-left, toward the viewer
        let ct = Float(cos(-tilt)), stl = Float(sin(-tilt))
        for y in 0..<n {
            for x in 0..<n {
                let nx = (Float(x) + 0.5) / Float(n) * 2 - 1, ny = (Float(y) + 0.5) / Float(n) * 2 - 1
                let d2 = nx * nx + ny * ny
                let i = y * n + x
                guard d2 <= 1 else { continue }
                inside[i] = true
                let z = sqrt(1 - d2)
                // Undo the axial tilt (rotate around the view axis), then read latitude/longitude.
                let tx = nx * ct - ny * stl, ty = nx * stl + ny * ct
                let lat = asin(max(-1, min(1, -ty)))
                let lon = atan2(tx, z)
                latIdx[i] = Int32(max(0, min(Float(PlanetTexture.H - 1), (0.5 - lat / .pi) * Float(PlanetTexture.H))))
                lonBase[i] = (lon / (2 * .pi) + 1) * Float(PlanetTexture.W)
                let lam = max(0, simd_dot(SIMD3(nx, ny, z), L))
                light[i] = 0.1 + 0.95 * pow(lam, 0.8)
            }
        }
    }
}
