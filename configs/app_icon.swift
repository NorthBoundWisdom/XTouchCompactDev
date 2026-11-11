import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.11, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 190, yRadius: 190).fill()
for (index, y) in [600, 390, 520, 680].enumerated() {
    let x = 210 + index * 200
    NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: 220, width: 30, height: 580), xRadius: 15, yRadius: 15).fill()
    NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.55, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: x - 42, y: y, width: 114, height: 76), xRadius: 14, yRadius: 14).fill()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("AppIcon.png"))
