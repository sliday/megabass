import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in l { if let o = w["kCGWindowOwnerName"] as? String, o.lowercased().contains(CommandLine.arguments[1]) { print(w["kCGWindowNumber"]!, w["kCGWindowLayer"]!, w["kCGWindowBounds"]!) } }
