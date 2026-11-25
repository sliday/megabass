import AppKit
import MegaBassCore
import SwiftUI

@main
struct MegaBassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(engine: delegate.engine, hub: delegate.hub)
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
    lazy var hub = NowPlayingHub(cliamp: player)
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
        if args.contains("--gallery") {
            // Every planet type, lit, for review.
            let grid = VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(Array(PlanetStyle.Kind.allCases.enumerated()).filter { $0.offset / 4 == row }, id: \.offset) { _, k in
                            VStack(spacing: 2) {
                                PlanetView(engine: self.engine, radius: 40, style: PlanetStyle.sample(k), alwaysOn: true).frame(width: 140, height: 140)
                                Text(k.rawValue).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                            }
                        }
                    }
                }
            }.padding(12).background(Color(red: 0.04, green: 0.04, blue: 0.06))
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "megabass planets"
            w.contentView = NSHostingView(rootView: grid)
            w.setContentSize(w.contentView!.fittingSize)
            w.center(); w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            preview = w
        } else if args.contains("--preview") {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "megabass"
            w.contentView = NSHostingView(rootView: PopoverView(engine: engine, hub: hub))
            w.setContentSize(w.contentView!.fittingSize)
            w.center()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            preview = w
        } else if !args.contains("--no-panel") {
            // Launched by hand (Spotlight, Alfred, Finder): show the panel. A menu-bar manager such as
            // Bartender, or the notch, can hide the menu-bar icon; the app must still be reachable.
            showPanel()
        }
    }

    /// Opening megabass again while it runs shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return true
    }

    private var panel: NSPanel?

    /// The popover as a floating panel under the right end of the menu bar.
    func showPanel() {
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = false   // drags belong to the sliders; move by the top strip
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: PopoverView(engine: engine, hub: hub))
            p.setContentSize(p.contentView!.fittingSize)
            if let screen = NSScreen.main {
                let v = screen.visibleFrame
                p.setFrameTopLeftPoint(NSPoint(x: v.maxX - p.frame.width - 12, y: v.maxY - 8))
            }
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ note: Notification) { engine.shutdown() }
}
