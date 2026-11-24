// Prints window number, layer and bounds of on-screen windows owned by a process.
// Usage: winid <owner-name-substring> [pid]
import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let pid = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) : nil
for w in l {
    guard let o = w["kCGWindowOwnerName"] as? String, o.lowercased().contains(CommandLine.arguments[1]) else { continue }
    if let pid, (w["kCGWindowOwnerPID"] as? Int) != pid { continue }
    // The preview window is the tall one; skip menu bar items and small popups.
    if let b = w["kCGWindowBounds"] as? [String: Any], let h = b["Height"] as? Double, h < 200 { continue }
    print(w["kCGWindowNumber"]!, w["kCGWindowLayer"]!)
}
