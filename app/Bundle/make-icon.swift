// Draws the app icon into an .iconset folder for iconutil:
//   swift make-icon.swift <out>.iconset
// A black line-art eye on a white rounded square, drawn so the icon needs
// no checked-in artwork.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    // The macOS icon grid: an 824/1024 rounded square, centered, with a
    // soft shadow and a hairline so the white tile holds up on light
    // backgrounds.
    let inset = s * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let t = tile.width
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: t * 0.225, yRadius: t * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.shadowBlurRadius = s * 12 / 1024
    shadow.shadowOffset = NSSize(width: 0, height: -s * 6 / 1024)
    shadow.set()
    NSColor.white.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 0, alpha: 0.12).setStroke()
    tilePath.lineWidth = max(s / 1024, 0.5)
    tilePath.stroke()

    // Thick strokes, and thicker still at small sizes so they don't fade.
    let line = max(t * 0.05, 1.4)
    let cx = s / 2, cy = s / 2
    NSColor.black.set()

    // The lids: two curves meeting in rounded corners.
    let w = t * 0.40, h = t * 0.205
    let eye = NSBezierPath()
    eye.move(to: NSPoint(x: cx - w, y: cy))
    eye.curve(to: NSPoint(x: cx + w, y: cy), controlPoint1: NSPoint(x: cx - w * 0.45, y: cy + h * 1.33), controlPoint2: NSPoint(x: cx + w * 0.45, y: cy + h * 1.33))
    eye.curve(to: NSPoint(x: cx - w, y: cy), controlPoint1: NSPoint(x: cx + w * 0.45, y: cy - h * 1.33), controlPoint2: NSPoint(x: cx - w * 0.45, y: cy - h * 1.33))
    eye.close()
    eye.lineWidth = line
    eye.lineJoinStyle = .round

    // The iris, a ring inside the lids, around a solid pupil with a glint.
    NSGraphicsContext.saveGraphicsState()
    eye.addClip()
    let iris = h - line * 0.5
    let irisPath = NSBezierPath(ovalIn: NSRect(x: cx - iris, y: cy - iris, width: 2 * iris, height: 2 * iris))
    irisPath.lineWidth = line
    irisPath.stroke()
    NSGraphicsContext.restoreGraphicsState()
    eye.stroke()

    let pupil = iris * 0.5
    NSBezierPath(ovalIn: NSRect(x: cx - pupil, y: cy - pupil, width: 2 * pupil, height: 2 * pupil)).fill()
    let glint = pupil * 0.36
    let gx = cx - pupil * 0.36, gy = cy + pupil * 0.36
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: gx - glint, y: gy - glint, width: 2 * glint, height: 2 * glint)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try draw(size: points * scale).write(to: out.appending(path: name))
    }
}
