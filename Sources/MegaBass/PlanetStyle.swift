import Foundation

/// A planet's look, derived deterministically from a key (a cliamp station, or the Spotify/Music
/// track title): same key, same planet, every time. FNV-1a 64 hashes the key; SplitMix64 expands
/// the hash into the style's numbers. `code` is the short hashed name, `definition` the full recipe.
struct PlanetStyle: Equatable {
    struct Storm: Equatable { var lat: Double; var lon: Double; var size: Double }
    /// A surface feature on the sphere (continent, cloud, crater), angular radius `size`.
    struct Blob: Equatable { var lat: Double; var lon: Double; var size: Double; var shade: Double }

    /// Planet classes in the spirit of 4X space games (Master of Orion and friends), plus curios:
    /// orbs that are objects rather than worlds.
    enum Kind: String, CaseIterable {
        case gasGiant = "gas giant", terran, ocean, jungle, desert, tundra, ice, barren, radiated, toxic, inferno, star
        case crystal = "crystal ball", eightBall = "8 ball", mana = "mana orb", disco = "disco ball", eyeball, plasma = "plasma globe", pearl
        case mercury = "mercury ball"
        static let worlds: [Kind] = [.gasGiant, .terran, .ocean, .jungle, .desert, .tundra, .ice, .barren, .radiated, .toxic, .inferno, .star]
        static let curios: [Kind] = [.crystal, .eightBall, .mana, .disco, .eyeball, .plasma, .pearl, .mercury]
        var isCurio: Bool { Kind.curios.contains(self) }
    }

    let key: String
    let code: String
    let kind: Kind
    let blobs: [Blob]           // continents, islands, dunes
    let clouds: [Blob]
    let craters: [Blob]
    let cracks: [[(lat: Double, lon: Double)]]
    let caps: Double            // polar cap size, 0 = none
    let bands: Int              // latitude bands, 5...12
    let wave: Double            // band-edge waviness, fraction of radius
    let detail: Double          // fine ripple frequency
    let tilt: Double            // axial tilt, radians
    let spin: Double            // rotation speed, rad/s
    let storms: [Storm]
    let rings: Bool
    let ringTilt: Double        // radians
    let ringWidth: Double       // fraction of radius
    let ringLines: Int          // 8...14 lines
    let ringGap: Int            // index of a dark Cassini-style gap, -1 for none
    let atmosphere: Double      // atmosphere strength multiplier
    let starClass: Int          // stars only: 0 red dwarf, 1 orange, 2 yellow, 3 white, 4 blue-white

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return h
    }

    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    }

    static func from(_ key: String) -> PlanetStyle {
        let h = fnv1a(key)
        var r = SplitMix64(state: h)
        let bands = 5 + Int(r.unit() * 8)
        let wave = r.range(0.02, 0.09)
        let detail = r.range(4, 9)
        let tilt = r.range(-0.44, 0.44)
        let spin = r.range(0.12, 0.3)
        let storms = (0..<Int(r.unit() * 4)).map { _ in
            Storm(lat: r.range(-0.6, 0.6), lon: r.range(0, 2 * .pi), size: r.range(0.18, 0.4))
        }
        let rings = r.unit() < 0.55
        let ringTilt = r.range(-0.5, 0.5)
        let ringWidth = r.range(0.24, 0.46)
        let ringLines = 8 + Int(r.unit() * 7)
        let ringGap = r.unit() < 0.6 ? 2 + Int(r.unit() * Double(max(1, ringLines - 4))) : -1
        var atmosphere = r.range(0.7, 1.4)
        var kind = Kind.worlds[Int(r.unit() * Double(Kind.worlds.count)) % Kind.worlds.count]
        // About a quarter of keys get a curio instead, from their own hash: the rest keep their world.
        var cr = SplitMix64(state: fnv1a(key + "curio"))
        if cr.unit() < 0.25 { kind = Kind.curios[Int(cr.unit() * Double(Kind.curios.count)) % Kind.curios.count] }
        func blobs(_ n: Int, _ a: Double, _ b: Double, lat: Double = 0.95) -> [Blob] {
            (0..<n).map { _ in Blob(lat: r.range(-lat, lat), lon: r.range(0, 2 * .pi), size: r.range(a, b), shade: r.unit()) }
        }
        var land: [Blob] = [], clouds: [Blob] = [], craters: [Blob] = [], cracks: [[(lat: Double, lon: Double)]] = []
        var caps = 0.0
        switch kind {
        case .gasGiant: break
        case .terran:   land = blobs(16, 0.18, 0.42, lat: 0.8); clouds = blobs(12, 0.1, 0.3); caps = r.range(0.18, 0.3)
        case .ocean:    land = blobs(6, 0.06, 0.16, lat: 0.7); clouds = blobs(16, 0.1, 0.32); caps = r.range(0.1, 0.2)
        case .jungle:   land = blobs(24, 0.22, 0.5, lat: 0.85); clouds = blobs(14, 0.1, 0.28)
        case .desert:   land = blobs(14, 0.2, 0.45); craters = blobs(5, 0.04, 0.09); atmosphere *= 0.6
        case .tundra:   land = blobs(12, 0.15, 0.4); clouds = blobs(6, 0.1, 0.25); caps = r.range(0.35, 0.55)
        case .ice:      caps = 1; cracks = (0..<6).map { _ in crack(&r) }; atmosphere *= 0.7
        case .barren:   craters = blobs(22, 0.04, 0.16); atmosphere *= 0.3
        case .radiated: craters = blobs(10, 0.04, 0.12); cracks = (0..<7).map { _ in crack(&r) }; atmosphere *= 0.5
        case .toxic:    clouds = blobs(20, 0.15, 0.4); atmosphere *= 1.6
        case .inferno:  craters = blobs(6, 0.05, 0.12); cracks = (0..<9).map { _ in crack(&r) }; atmosphere *= 0.8
        case .star:     atmosphere = 1.6
        case .mana:     atmosphere = 0.6
        case .plasma:   atmosphere = 0.5
        case .crystal, .eightBall, .disco, .eyeball, .pearl, .mercury: atmosphere = 0.25
        }
        let starClass = Int(r.unit() * 5)
        let code = "PL-" + String(format: "%08X", UInt32(truncatingIfNeeded: h >> 32))
        return PlanetStyle(key: key, code: code, kind: kind, blobs: land, clouds: clouds, craters: craters,
                           cracks: cracks, caps: caps, bands: bands, wave: wave, detail: detail, tilt: tilt, spin: spin,
                           storms: storms, rings: kind == .star || kind.isCurio ? false : rings, ringTilt: ringTilt, ringWidth: ringWidth,
                           ringLines: ringLines, ringGap: ringGap,
                           atmosphere: atmosphere, starClass: starClass)
    }

    /// A wandering line on the sphere (lava, radiation, ice fractures).
    private static func crack(_ r: inout SplitMix64) -> [(lat: Double, lon: Double)] {
        var lat = r.range(-0.8, 0.8), lon = r.range(0, 2 * .pi)
        var heading = r.range(0, 2 * .pi)
        return (0..<9).map { _ in
            defer { heading += r.range(-0.7, 0.7); lat = max(-1.2, min(1.2, lat + sin(heading) * 0.12)); lon += cos(heading) * 0.14 }
            return (lat: lat, lon: lon)
        }
    }

    static func == (a: PlanetStyle, b: PlanetStyle) -> Bool { a.key == b.key }

    /// The first hashed planet of a given type (for the gallery).
    static func sample(_ kind: Kind) -> PlanetStyle {
        for n in 0..<10_000 { let s = from("gallery-\(n)"); if s.kind == kind { return s } }
        return from("megabass")
    }

    /// The full recipe, readable: what the hash decided.
    var definition: String {
        let deg = { (r: Double) in String(format: "%+.0f°", r * 180 / .pi) }
        let name = kind == .star ? ["red dwarf", "orange", "yellow", "white", "blue-white"][starClass] + " star" : kind.rawValue
        var parts = [name, "\(bands) bands", String(format: "wave %.2f", wave), "tilt " + deg(tilt),
                     String(format: "spin %.2f rad/s", spin), "\(storms.count) storm\(storms.count == 1 ? "" : "s")"]
        if rings { parts.append("rings " + deg(ringTilt)) }
        parts.append(String(format: "atmosphere %.1f×", atmosphere))
        return "\(code) · " + parts.joined(separator: " · ")
    }
}
