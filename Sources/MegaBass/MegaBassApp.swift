import AppKit
import MegaBassCore
import SwiftUI

@main
struct MegaBassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(engine: delegate.engine, hub: delegate.hub, inMenu: true)
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
        // The floating panel (and the preview window) follow their content's height, top edge fixed.
        LayoutState.shared.panelSize = { [weak self] size in
            guard let self, size.height > 0 else { return }
            for w in [self.panel as NSWindow?, self.preview].compactMap({ $0 }) where w.contentView is NSHostingView<PopoverView> {
                let frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
                guard abs(frame.height - w.frame.height) > 0.5 else { continue }
                var f = w.frame
                let top = f.maxY
                f.size.height = frame.height
                f.origin.y = top - frame.height
                w.setFrame(f, display: true, animate: false)
            }
        }
        // One planet at a time: whichever floating window is showing (the panel or the widget) steps
        // aside while the menu-bar popover is open, and comes back when it closes.
        LayoutState.shared.menuOpen = { [weak self] open in
            DispatchQueue.main.async {
                guard let self else { return }
                if open {
                    self.steppedAside = [self.panel, self.widget].compactMap { $0 }.filter(\.isVisible)
                    self.steppedAside.forEach { $0.orderOut(nil) }
                } else {
                    self.steppedAside.forEach { $0.orderFrontRegardless() }
                    self.steppedAside = []
                }
            }
        }
        if args.contains("--gallery") {
            PlanetTextures.shared.capacity = 32                     // every type at once
            // Every planet type, lit, for review.
            let grid = VStack(spacing: 8) {
                ForEach(0..<((PlanetStyle.Kind.allCases.count + 3) / 4), id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(Array(PlanetStyle.Kind.allCases.enumerated()).filter { $0.offset / 4 == row }, id: \.offset) { _, k in
                            VStack(spacing: 2) {
                                PlanetView(engine: self.engine, radius: 40, style: PlanetStyle.sample(k), alwaysOn: true, enabled: true).frame(width: 140, height: 140)
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
        ensurePanel()
        if LayoutState.shared.compact { showWidget(); return }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensurePanel() {
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
            LayoutState.shared.onChange = { [weak self] in
                DispatchQueue.main.async { self?.applyLayout() }
            }
            LayoutState.shared.hideAll = { [weak self] in
                DispatchQueue.main.async { self?.panel?.orderOut(nil); self?.widget?.orderOut(nil) }
            }
        }
    }

    private var widget: NSPanel?
    /// Windows hidden while the menu-bar popover is open.
    private var steppedAside: [NSWindow] = []

    /// Panel <-> widget: the planet flies between the panel's hero spot and the widget's corner
    /// (0.35 s, ease in-out) while the other window fades. The widget's saved frame is restored after.
    private func applyLayout() {
        ensurePanel()
        guard let panel else { return }
        let hero = heroFrame(in: panel)
        if LayoutState.shared.compact {
            ensureWidget()
            guard let w = widget else { return }
            let target = w.frame
            w.alphaValue = 0
            w.setFrame(hero, display: false)
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                w.animator().setFrame(target, display: true)
                w.animator().alphaValue = 1
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                panel.alphaValue = 1
            })
        } else {
            guard let w = widget, w.isVisible else {
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            let saved = w.frame
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                w.animator().setFrame(hero, display: true)
                w.animator().alphaValue = 0
                panel.animator().alphaValue = 1
            }, completionHandler: {
                w.orderOut(nil)
                w.alphaValue = 1
                w.setFrame(saved, display: false)            // keep the parked spot
            })
        }
    }

    /// The hero (planet + ring, 280 pt) in screen coordinates, from where the ring sits in the panel.
    private func heroFrame(in panel: NSPanel) -> NSRect {
        let c = RingSim.shared.ringCenter
        let contentH = panel.contentView?.frame.height ?? panel.frame.height
        let cx = panel.frame.minX + (c == .zero ? panel.frame.width / 2 : c.x)
        let cy = panel.frame.minY + contentH - (c == .zero ? 140 : c.y)
        return NSRect(x: cx - 140, y: cy - 140, width: 280, height: 280)
    }

    /// Just the planet: a borderless, transparent, square window that floats on every Space,
    /// resizable 140-420 pt, dragged anywhere, its frame remembered.
    private func showWidget() {
        ensureWidget()
        widget?.orderFrontRegardless()
    }

    private func ensureWidget() {
        if widget == nil {
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                            styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.isMovableByWindowBackground = true
            w.hidesOnDeactivate = false
            w.contentAspectRatio = NSSize(width: 1, height: 1)
            w.minSize = NSSize(width: 140, height: 140)
            w.maxSize = NSSize(width: 420, height: 420)
            w.contentView = NSHostingView(rootView: WidgetView(engine: engine, hub: hub))
            if !w.setFrameUsingName("megabass.widget"), let screen = NSScreen.main {
                let v = screen.visibleFrame
                w.setFrame(NSRect(x: v.maxX - 212, y: v.maxY - 212, width: 200, height: 200), display: false)
            }
            w.setFrameAutosaveName("megabass.widget")
            widget = w
        }
    }

    func applicationWillTerminate(_ note: Notification) { engine.shutdown() }
}
