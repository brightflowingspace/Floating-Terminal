import Cocoa
// Floating Terminal のアイコンを一から描く（Appleの画像は使わない）
// 使い方: swift make_icon.swift AppIcon.png
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS のアイコン枠（824px の角丸四角）
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor(white: 0.12, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: NSColor(white: 0.19, alpha: 1), ending: NSColor(white: 0.08, alpha: 1))!
    .draw(in: shape, angle: -90)

func draw(_ text: String, size: CGFloat, centerX: CGFloat, centerY: CGFloat) {
    let font = NSFont(name: "Menlo-Bold", size: size)!
    let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: 0.95, alpha: 1)])
    let g = str.boundingRect(with: .zero, options: [.usesDeviceMetrics])
    str.draw(at: NSPoint(x: centerX - g.midX, y: centerY - g.midY))
}
// 目（> <）と口（F）。顔全体が枠の中央に来るように配置
draw(">", size: 300, centerX: 362, centerY: 571)
draw("<", size: 300, centerX: 662, centerY: 571)
draw("F", size: 260, centerX: 512, centerY: 336)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
