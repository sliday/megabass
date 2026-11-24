import AppKit
import MegaBassCore
import SwiftUI

@main
struct MegaBassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(engine: delegate.engine)
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
    let engine = Engine()
    private var preview: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        // --preview: the popover in a plain window (screenshots, reviews). --on / --demo: start state.
        if let m = args.firstIndex(of: "--mode"), m + 1 < args.count, let mode = BassMode(rawValue: args[m + 1]) { engine.mode = mode }
        engine.demoSilent = args.contains("--silent")
        if args.contains("--demo") { engine.toggleDemo() } else if args.contains("--on") { engine.setEnabled(true) }
        if args.contains("--preview") {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "megabass"
            w.contentView = NSHostingView(rootView: PopoverView(engine: engine))
            w.setContentSize(w.contentView!.fittingSize)
            w.center()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            preview = w
        }
    }

    func applicationWillTerminate(_ note: Notification) { engine.setEnabled(false) }
}
