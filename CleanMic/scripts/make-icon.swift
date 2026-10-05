// Generiše Resources/AppIcon.icns:  swift scripts/make-icon.swift
// Ikona se crta ručno (bez SF Symbols — njihova licenca ne dozvoljava upotrebu u ikoni aplikacije).
import AppKit

let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: side, height: side)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: zaobljeni kvadrat 824×824 na platnu 1024×1024.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: plate, xRadius: 186, yRadius: 186)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor(red: 0.20, green: 0.38, blue: 0.92, alpha: 1).setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [NSColor(red: 0.30, green: 0.26, blue: 0.86, alpha: 1),
                    NSColor(red: 0.16, green: 0.58, blue: 0.99, alpha: 1)])!.draw(in: path, angle: 60)

// Talasni oblik: sedam zaobljenih stubića.
let heights: [CGFloat] = [0.26, 0.52, 0.80, 1.0, 0.66, 0.42, 0.22]
let barWidth: CGFloat = 58
let gap: CGFloat = 34
let maxHeight: CGFloat = 430
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (CGFloat(side) - total) / 2
NSColor.white.setFill()
for h in heights {
    let height = maxHeight * h
    let bar = NSRect(x: x, y: (CGFloat(side) - height) / 2, width: barWidth, height: height)
    NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}
NSGraphicsContext.restoreGraphicsState()

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("CleanMic-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = iconset.appendingPathComponent("icon_512x512@2x.png")
try rep.representation(using: .png, properties: [:])!.write(to: master)

func run(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { fatalError("\(tool) \(args) -> \(p.terminationStatus)") }
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
                   ("icon_256x256@2x", 512), ("icon_512x512", 512)] {
    try run("/usr/bin/sips", ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent("\(name).png").path])
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", out.path])
try? FileManager.default.removeItem(at: iconset)
print("✅ \(out.path)")
