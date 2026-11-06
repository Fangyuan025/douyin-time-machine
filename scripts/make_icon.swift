// 生成 App 图标：swift scripts/make_icon.swift <输出目录>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS 图标网格：内容区约 80%，圆角矩形
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(red: 0.08, green: 0.06, blue: 0.14, alpha: 1).cgColor,
                  NSColor(red: 0.20, green: 0.07, blue: 0.20, alpha: 1).cgColor] as CFArray
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // 发光圆环（时间隧道）
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let ringR = rect.width * 0.32
    let ringW = rect.width * 0.075
    let glow = NSColor(red: 1.0, green: 0.36, blue: 0.42, alpha: 1)
    let warm = NSColor(red: 1.0, green: 0.66, blue: 0.25, alpha: 1)
    ctx.setShadow(offset: .zero, blur: s * 0.06, color: glow.withAlphaComponent(0.8).cgColor)
    ctx.setLineWidth(ringW)
    ctx.setLineCap(.round)
    // 渐变圆环：分段绘制
    let segments = 120
    let gap = 0.16 // 留出逆时针箭头的缺口
    for i in 0..<segments {
        let t0 = Double(i) / Double(segments)
        let t1 = Double(i + 1) / Double(segments)
        guard t0 > gap else { continue }
        let a0 = .pi / 2 + t0 * 2 * .pi
        let a1 = .pi / 2 + t1 * 2 * .pi
        let k = CGFloat((t0 - gap) / (1 - gap))
        let c = NSColor(red: warm.redComponent + (glow.redComponent - warm.redComponent) * k,
                        green: warm.greenComponent + (glow.greenComponent - warm.greenComponent) * k,
                        blue: warm.blueComponent + (glow.blueComponent - warm.blueComponent) * k, alpha: 1)
        ctx.setStrokeColor(c.cgColor)
        ctx.addArc(center: center, radius: ringR, startAngle: a0, endAngle: a1 + 0.01, clockwise: false)
        ctx.strokePath()
    }
    // 箭头（指向逆时针方向 = 回到过去）
    let tipAngle = .pi / 2 + gap * 2 * .pi
    let tip = CGPoint(x: center.x + cos(tipAngle) * ringR, y: center.y + sin(tipAngle) * ringR)
    let dir = CGPoint(x: sin(tipAngle), y: -cos(tipAngle)) // 切线方向（顺时针）
    let normal = CGPoint(x: cos(tipAngle), y: sin(tipAngle))
    let L = ringW * 1.9
    let p1 = CGPoint(x: tip.x - dir.x * L * 0.2 + normal.x * L * 0.9, y: tip.y - dir.y * L * 0.2 + normal.y * L * 0.9)
    let p2 = CGPoint(x: tip.x - dir.x * L * 0.2 - normal.x * L * 0.9, y: tip.y - dir.y * L * 0.2 - normal.y * L * 0.9)
    let p3 = CGPoint(x: tip.x + dir.x * L * 1.3, y: tip.y + dir.y * L * 1.3)
    ctx.setFillColor(warm.cgColor)
    ctx.move(to: p1); ctx.addLine(to: p3); ctx.addLine(to: p2); ctx.closePath()
    ctx.fillPath()

    // 指针
    ctx.setShadow(offset: .zero, blur: s * 0.02, color: NSColor.white.withAlphaComponent(0.6).cgColor)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(rect.width * 0.05)
    ctx.move(to: center); ctx.addLine(to: CGPoint(x: center.x, y: center.y + ringR * 0.62)); ctx.strokePath()
    ctx.move(to: center); ctx.addLine(to: CGPoint(x: center.x + ringR * 0.45, y: center.y - ringR * 0.22)); ctx.strokePath()
    ctx.setFillColor(NSColor.white.cgColor)
    let dot = rect.width * 0.045
    ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("icons written to \(out)")
