import Cocoa

// 使い方: swiftc make_icon.swift -o /tmp/make_icon && /tmp/make_icon <出力.iconset のフォルダ>
// 指3本のアイコン
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = CGFloat(px) / 1024
    // 背景: 角丸の四角(macOS のアイコン枠 824pt)
    let bg = NSBezierPath(roundedRect: NSRect(x: 100*u, y: 100*u, width: 824*u, height: 824*u), xRadius: 185*u, yRadius: 185*u)
    NSGradient(starting: NSColor(white: 1.0, alpha: 1), ending: NSColor(white: 0.88, alpha: 1))!.draw(in: bg, angle: -90)
    // 指3本: 下端をそろえた縦長の丸棒。中指がいちばん高い
    NSColor.systemBlue.setFill()
    let fingers: [(CGFloat, CGFloat)] = [(282, 330), (452, 430), (622, 355)]  // (x, 高さ)
    for (fx, h) in fingers {
        NSBezierPath(roundedRect: NSRect(x: fx*u, y: 285*u, width: 118*u, height: h*u), xRadius: 59*u, yRadius: 59*u).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("16",16),("16@2x",32),("32",32),("32@2x",64),("128",128),("128@2x",256),("256",256),("256@2x",512),("512",512),("512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name.replacingOccurrences(of: "@2x", with: ""))x\(name.replacingOccurrences(of: "@2x", with: ""))\(name.contains("@2x") ? "@2x" : "").png"))
}
