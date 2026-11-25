import Foundation

/// Drives cliamp (github.com/bjarneo/cliamp, MIT), the terminal music player, through its CLI and IPC.
/// cliamp plays through the speakers, so megabass's tap hears it like any other app: this bridge only
/// adds now-playing info and transport. Polls `cliamp status --json` while the popover is open.
@MainActor
final class CliampBridge: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var running = false
    @Published private(set) var playing = false
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var shuffle = false
    @Published private(set) var playlists: [String] = []
    /// cliamp radio channels (radio.cliamp.stream): id and display name.
    @Published private(set) var stations: [(id: String, name: String)] = []
    /// The channel playing now, from the stream URL ("…/lofi/tracks/…" → "lofi"), or "".
    @Published private(set) var station = ""

    private let path: String?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "megabass.cliamp")

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        path = ["\(home)/.local/bin/cliamp", "/opt/homebrew/bin/cliamp", "/usr/local/bin/cliamp", "\(home)/go/bin/cliamp"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        installed = path != nil
    }

    func startPolling() {
        guard installed, timer == nil else { return }
        refresh()
        loadPlaylists()
        loadStations()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func toggle() { command(["toggle"]) }
    /// Jumps to an absolute position (seconds).
    func seek(to seconds: Double) {
        position = seconds
        command(["remote", "call", "seek.absolute", "--params", "{\"value\":\(max(0, seconds))}", "--wait"])
    }
    func next() { command(["next"]) }
    func toggleShuffle() { shuffle.toggle(); command(["shuffle", "toggle"]) }
    func prev() { command(["prev"]) }

    /// Plays a playlist: through the running player, or by starting cliamp's headless daemon.
    func play(playlist: String) {
        if running { command(["load", playlist]); return }
        guard let path else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--daemon", "--auto-play", "--playlist", playlist]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()               // the daemon outlives megabass, as cliamp intends
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    /// Switches cliamp to a radio channel. Starts the headless daemon first if cliamp isn't running.
    func play(station id: String) {
        let load = { [weak self] in
            self?.run(["remote", "call", "provider.load", "--params", "{\"provider\":\"cliamp\",\"playlist\":\"\(id)\"}", "--wait"]) { _ in self?.refresh() }
        }
        station = id
        if running { load(); return }
        guard let path else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--daemon"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { load() }
    }

    func refresh() {
        run(["status", "--json"]) { [weak self] data in
            guard let self else { return }
            let s = data.flatMap { try? JSONDecoder().decode(Status.self, from: $0) }
            self.running = s?.ok == true
            self.playing = s?.state == "playing"
            self.title = s?.track?.title ?? ""
            self.artist = s?.track?.artist ?? ""
            self.position = s?.position ?? 0
            self.duration = s?.duration ?? 0
            self.shuffle = s?.shuffle ?? false
            self.station = Self.stationID(s?.track?.path) ?? (self.running ? self.station : "")
        }
    }

    private func loadPlaylists() {
        run(["playlist", "list"]) { [weak self] data in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { return }
            // Lines look like "  Lofi        12 tracks".
            self.playlists = text.split(separator: "\n").compactMap { line in
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "  ").filter { !$0.isEmpty }
                guard parts.count >= 2, parts.last!.contains("track"), !parts.last!.hasPrefix("0 ") else { return nil }
                return parts.dropLast().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            }
        }
    }

    private func loadStations() {
        run(["remote", "call", "provider.playlists", "--params", "{\"provider\":\"cliamp\"}", "--wait"]) { [weak self] data in
            guard let self, let data, let r = try? JSONDecoder().decode(Playlists.self, from: data) else { return }
            self.stations = (r.job?.result?.playlists ?? []).map { ($0.id, $0.name) }
        }
    }

    /// "https://radio.cliamp.stream/lofi/tracks/…" → "lofi".
    static func stationID(_ path: String?) -> String? {
        guard let path, let u = URL(string: path), u.host == "radio.cliamp.stream" else { return nil }
        return u.pathComponents.dropFirst().first
    }

    private struct Playlists: Decodable {
        struct Job: Decodable { let result: Result? }
        struct Result: Decodable { let playlists: [Item]? }
        struct Item: Decodable { let id: String; let name: String }
        let job: Job?
    }

    private func command(_ args: [String]) {
        run(args) { [weak self] _ in self?.refresh() }
    }

    /// Runs cliamp off the main thread with a 3 s limit; hands stdout back on main.
    private func run(_ args: [String], done: @escaping @MainActor (Data?) -> Void) {
        guard let path else { return }
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var data: Data?
            if (try? p.run()) != nil {
                let deadline = DispatchTime.now() + 3
                DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
                data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
            }
            let result = data
            DispatchQueue.main.async { done(result) }
        }
    }

    private struct Status: Decodable {
        struct Track: Decodable { let title: String?; let artist: String?; let path: String? }
        let ok: Bool?
        let state: String?
        let track: Track?
        let position: Double?
        let duration: Double?
        let shuffle: Bool?
    }
}
