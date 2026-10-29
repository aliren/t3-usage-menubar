// Draws the T3 Usage app icon: a dark squircle carrying the menu bar ring gauge.
// Usage: swift scripts/make-icon.swift <output.iconset directory>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// Apple's continuous-corner squircle, approximated as a superellipse (n = 4.6, matched against Calculator).
func squircle(_ rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath(), n = 4.6, steps = 360
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + rect.width / 2 * CGFloat(copysign(pow(abs(c), 2 / n), c))
        let y = rect.midY + rect.height / 2 * CGFloat(copysign(pow(abs(s), 2 / n), s))
        i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
    }
    path.close()
    return path
}

func draw(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(pixels) / 1024
    // macOS icon grid: 824 pt body centred on a 1024 canvas, room left for the shadow.
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = squircle(body)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k); shadow.shadowBlurRadius = 24 * k
    shadow.set()
    NSColor.black.setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor(white: 0.15, alpha: 1), ending: NSColor(white: 0.05, alpha: 1))!.draw(in: body, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // Hairline edge, a touch brighter at the top, so the dark body separates from dark docks.
    NSGradient(starting: NSColor(white: 1, alpha: 0.16), ending: NSColor(white: 1, alpha: 0.03))!.draw(in: {
        let edge = squircle(body.insetBy(dx: 1 * k, dy: 1 * k)); edge.append(squircle(body.insetBy(dx: 4 * k, dy: 4 * k)).reversed)
        return edge
    }(), angle: -90)

    // Ring gauge, as in the menu bar: thin track, ~3/4 arc from twelve o'clock. Thicker at tiny sizes to stay legible.
    let center = NSPoint(x: body.midX, y: body.midY), radius = 250 * k
    let width = (pixels <= 16 ? 110 : pixels <= 64 ? 78 : 56) * k
    let track = NSBezierPath(); track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = width; NSColor(white: 1, alpha: 0.12).setStroke(); track.stroke()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * 0.76, clockwise: true)
    arc.lineWidth = width; arc.lineCapStyle = .round
    NSColor(white: 0.93, alpha: 1).setStroke(); arc.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
    try! draw(pixels: points * scale).write(to: out.appendingPathComponent(name))
}
print("Wrote \(out.path)")
