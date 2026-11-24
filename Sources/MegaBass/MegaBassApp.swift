import AppKit
import MegaBassCore
import SwiftUI

@main
struct MegaBassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(engine: delegate.engine, player: delegate.player)
        } label: {
            MenuBarIcon(engine: delegate.engine)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var engine: Engine
    var body: some View {
        Image(systemName: engine.enabled ? "waveform.circle.fill" : "waveform.circle")
            .accessibilityLabel("megabass")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = Engine(restore: !CommandLine.arguments.contains("--preview"))
    let player = CliampBridge()
    private var preview: NSWindow?
    private var diagTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        // --preview: the popover in a plain window (screenshots, reviews). --on / --demo: start state.
        if let m = args.firstIndex(of: "--mode"), m + 1 < args.count, let mode = BassMode(rawValue: args[m + 1]) { engine.mode = mode }
        engine.demoSilent = args.contains("--silent")
        if args.contains("--demo") { engine.toggleDemo() } else if args.contains("--on") { engine.setEnabled(true) }
        if let d = args.firstIndex(of: "--diag") {
            // Once a second to the given path (default ~/Library/Logs/megabass/diag.txt).
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/megabass")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = d + 1 < args.count && !args[d + 1].hasPrefix("--") ? URL(fileURLWithPath: args[d + 1]) : dir.appendingPathComponent("diag.txt")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let h = try? FileHandle(forWritingTo: url)
            diagTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let h else { return }
                    h.seekToEndOfFile()
                    h.write((self.engine.diagnosticsLine() + "\n").data(using: .utf8)!)
                }
            }
        }
        if args.contains("--preview") {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "megabass"
            w.contentView = NSHostingView(rootView: PopoverView(engine: engine, player: player))
            w.setContentSize(w.contentView!.fittingSize)
            w.center()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            preview = w
        }
    }

    func applicationWillTerminate(_ note: Notification) { engine.shutdown() }
}
