import AppKit
import Combine
import SwiftUI

/// Who's playing: cliamp, Spotify or Apple Music. Shows the active one, routes the transport to it,
/// and switches between them. Spotify and Music go through AppleScript (asks for Automation once);
/// apps that aren't running are never launched by polling.
@MainActor
final class NowPlayingHub: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case cliamp, spotify, music
        var id: String { rawValue }
        var name: String { switch self { case .cliamp: "cliamp"; case .spotify: "Spotify"; case .music: "Music" } }
        var bundleID: String? { switch self { case .cliamp: nil; case .spotify: "com.spotify.client"; case .music: "com.apple.Music" } }
    }

    struct Snapshot: Equatable {
        var running = false, playing = false
        var title = "", artist = "", position = 0.0, duration = 0.0
    }

    let cliamp: CliampBridge
    @Published private(set) var active: Source = .cliamp
    @Published private(set) var others: [Source: Snapshot] = [:]
    private var timer: Timer?
    private var pinnedUntil = Date.distantPast
    private var cliampSub: Any?

    init(cliamp: CliampBridge) {
        self.cliamp = cliamp
        // Re-publish cliamp changes so one object drives the view.
        cliampSub = cliamp.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.decide(); self?.objectWillChange.send() }
        }
    }

    // MARK: State for the view

    var installedSources: [Source] {
        Source.allCases.filter { s in
            s == .cliamp ? cliamp.installed : NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.bundleID!) != nil
        }
    }

    func snapshot(_ s: Source) -> Snapshot {
        if s == .cliamp {
            return Snapshot(running: cliamp.running, playing: cliamp.playing, title: cliamp.title, artist: cliamp.artist,
                            position: cliamp.position, duration: cliamp.duration)
        }
        return others[s] ?? Snapshot()
    }

    var now: Snapshot { snapshot(active) }

    // MARK: Look (shared by the panel and the widget)

    /// cliamp: one look per station. Spotify/Music: one per song (title + artist).
    var songKey: String { active == .cliamp ? "" : now.title + "|" + now.artist }
    var paletteKey: String { active.rawValue + ":" + cliamp.station + ":" + songKey }
    private var basePlanetKey: String {
        active == .cliamp ? "cliamp:" + (cliamp.station.isEmpty ? "megabass" : cliamp.station) : active.rawValue + ":" + songKey
    }
    var planetKey: String { basePlanetKey + (planetRolls[basePlanetKey].map { "#" + $0 } ?? "") }
    /// Rerolled planets (the dice button), per song or station, for this session.
    @Published private var planetRolls: [String: String] = [:]
    func rollPlanet() { planetRolls[basePlanetKey] = String(UInt64.random(in: 0...UInt64.max), radix: 36) }
    func applyPalette() {
        ThemeAnimator.shared.go(to: Palettes.current(source: active, station: cliamp.station, song: songKey), key: paletteKey)
    }

    // MARK: Polling

    func startPolling() {
        cliamp.startPolling()
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stopPolling() {
        cliamp.stopPolling()
        timer?.invalidate()
        timer = nil
    }

    /// AppleScript runs on its own queue: a pending Automation prompt or a slow app must not freeze the UI.
    nonisolated private static let scriptQueue = DispatchQueue(label: "megabass.applescript")
    private var querying = false

    private func poll() {
        decide()
        guard !querying else { return }
        let targets = [Source.spotify, .music].map { ($0, isRunning($0)) }
        querying = true
        Self.scriptQueue.async { [weak self] in
            var result: [Source: Snapshot] = [:]
            for (s, running) in targets { result[s] = running ? (Self.query(s) ?? Snapshot(running: true)) : Snapshot() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.querying = false
                if self.others != result { self.others = result }
                self.decide()
            }
        }
    }

    /// The active source follows whoever is playing, unless you picked one in the last 20 s.
    private func decide() {
        guard Date() > pinnedUntil else { return }
        let playing = Source.allCases.filter { snapshot($0).playing }
        if !playing.contains(active), let first = playing.first(where: { $0 != .cliamp }) ?? playing.first {
            active = first
        }
    }

    private func isRunning(_ s: Source) -> Bool {
        guard let id = s.bundleID else { return cliamp.running }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    // MARK: Control

    func toggle() { control(active, cliampCmd: { $0.toggle() }, script: "playpause") }

    /// While you drag the progress line: the fraction under the pointer (nil when not scrubbing).
    @Published var scrub: Double?

    /// Seeks the active player to `fraction` of the track.
    func seek(fraction: Double) {
        let d = now.duration
        guard d > 0 else { return }
        let target = max(0, min(d - 0.5, fraction * d))
        if active == .cliamp {
            cliamp.seek(to: target)
        } else {
            Self.run(active, "set player position to \(String(format: "%.2f", target))")
            if var snap = others[active] { snap.position = target; others[active] = snap }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.poll() }
    }
    func next() { control(active, cliampCmd: { $0.next() }, script: "next track") }
    func prev() { control(active, cliampCmd: { $0.prev() }, script: "previous track") }

    /// Makes `s` the player: pauses the others and starts or resumes it.
    func select(_ s: Source) {
        pinnedUntil = Date().addingTimeInterval(20)
        active = s
        for other in Source.allCases where other != s && snapshot(other).playing {
            if other == .cliamp { cliamp.toggle() } else { Self.run(other, "pause") }
        }
        switch s {
        case .cliamp:
            if !cliamp.running { cliamp.play(station: cliamp.station.isEmpty ? "lofi" : cliamp.station) }
            else if !cliamp.playing { cliamp.toggle() }
        default:
            Self.run(s, "play")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.poll() }
    }

    private func control(_ s: Source, cliampCmd: (CliampBridge) -> Void, script: String) {
        if s == .cliamp { cliampCmd(cliamp) } else { Self.run(s, script) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.poll() }
    }

    // MARK: AppleScript

    private static func run(_ s: Source, _ command: String) {
        guard s != .cliamp, !NSRunningApplication.runningApplications(withBundleIdentifier: s.bundleID!).isEmpty || command == "play" else { return }
        scriptQueue.async {
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"\(s.name)\" to \(command)")?.executeAndReturnError(&err)
        }
    }

    /// State, title, artist, position and duration (s) in one round trip.
    nonisolated private static func query(_ s: Source) -> Snapshot? {
        let durationExpr = s == .spotify ? "(duration of current track) / 1000" : "duration of current track"
        let src = """
        tell application "\(s.name)"
            set pState to player state as string
            if pState is "stopped" then return pState
            return pState & linefeed & (name of current track) & linefeed & (artist of current track) & linefeed & (player position as string) & linefeed & ((\(durationExpr)) as string)
        end tell
        """
        var err: NSDictionary?
        guard let out = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue else { return nil }
        let f = out.components(separatedBy: "\n")
        func num(_ i: Int) -> Double { i < f.count ? Double(f[i].replacingOccurrences(of: ",", with: ".")) ?? 0 : 0 }
        return Snapshot(running: true, playing: f.first == "playing",
                        title: f.count > 1 ? f[1] : "", artist: f.count > 2 ? f[2] : "",
                        position: num(3), duration: num(4))
    }
}

/// Colours per source and cliamp station; the popover's accent follows what's playing.
enum Palettes {
    static let megabass = (hot: Color(red: 1.0, green: 0.18, blue: 0.47), heat: Color(red: 1.0, green: 0.48, blue: 0.16))

    static func hex(_ v: UInt32) -> Color {
        Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static let stations: [String: (UInt32, UInt32)] = [
        "lofi": (0xFF8FAB, 0xB388FF), "meditative": (0x2EC4B6, 0x7DD3FC), "synthwave": (0xFF2E97, 0x00E5FF),
        "edm": (0x3D5AFE, 0xE040FB), "omarchy": (0xF59E0B, 0x84CC16), "chiptune": (0x22C55E, 0xFACC15),
        "amiga": (0x3B82F6, 0xF97316), "ncs": (0x00E5FF, 0x2979FF), "ncs-house": (0xFFB300, 0xFF3D00),
        "ncs-dubstep": (0x76FF03, 0x00C853), "ncs-dnb": (0xFF1744, 0xFF9100), "ncs-trap": (0xD500F9, 0x651FFF),
        "ncs-phonk": (0xC2185B, 0xFF4D6D), "ncs-pop": (0xFF4081, 0xFFD740), "ncs-chill": (0x80DEEA, 0xB39DDB),
    ]

    /// Per-song colours for Spotify and Music: the hue comes from a hash of title and artist, the
    /// second colour sits 30-55° around the wheel. Bright and saturated so it reads on the dark panel.
    static func song(_ key: String) -> (hot: Color, heat: Color) {
        let h = PlanetStyle.fnv1a(key)
        let hue = Double(h & 0xFFFF) / 65535
        let shift = (30 + Double((h >> 16) & 0xFF) / 255 * 25) / 360
        return (Color(hue: hue, saturation: 0.78, brightness: 1),
                Color(hue: (hue + shift).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 1))
    }

    static func current(source: NowPlayingHub.Source, station: String, song: String = "") -> (hot: Color, heat: Color) {
        switch source {
        case .spotify, .music:
            return song.isEmpty ? (source == .spotify ? (hex(0x1DB954), hex(0x1ED7A0)) : (hex(0xFA2D48), hex(0xFF6B81))) : Self.song(source.rawValue + ":" + song)
        case .cliamp:
            guard let p = stations[station] else { return megabass }
            return (hex(p.0), hex(p.1))
        }
    }
}

/// Blends the accent pair from the old palette to the new one (0.9 s, ease in-out) instead of
/// snapping. Views that use the accent read `\.themeTick`, so they repaint on every step.
@MainActor
final class ThemeAnimator: ObservableObject {
    static let shared = ThemeAnimator()
    @Published private(set) var tick = 0
    private var timer: Timer?
    private var key = ""

    private static func rgb(_ c: Color) -> (Double, Double, Double) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
        return (n.redComponent, n.greenComponent, n.blueComponent)
    }

    /// Moves to `target`. The first call (no previous palette) applies it at once.
    func go(to target: (hot: Color, heat: Color), key newKey: String) {
        guard newKey != key else { return }
        let first = key.isEmpty
        key = newKey
        timer?.invalidate()
        if first { Theme.hot = target.hot; Theme.heat = target.heat; tick += 1; return }
        let from = (Self.rgb(Theme.hot), Self.rgb(Theme.heat)), to = (Self.rgb(target.hot), Self.rgb(target.heat))
        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                let x = min(1, Date().timeIntervalSince(start) / 0.9)
                let e = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2          // ease in-out
                func lerp(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Color {
                    Color(red: a.0 + (b.0 - a.0) * e, green: a.1 + (b.1 - a.1) * e, blue: a.2 + (b.2 - a.2) * e)
                }
                Theme.hot = lerp(from.0, to.0)
                Theme.heat = lerp(from.1, to.1)
                self.tick += 1
                if x >= 1 { t.invalidate() }
            }
        }
    }
}

private struct ThemeTickKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    /// Changes on every palette step; views using `Theme` accents read it so they repaint.
    var themeTick: Int {
        get { self[ThemeTickKey.self] }
        set { self[ThemeTickKey.self] = newValue }
    }
}
