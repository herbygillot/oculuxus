// Draws the app icon into an .iconset folder for iconutil:
//   swift make-icon.swift <out>.iconset
// An eye on a Go-blue rounded square, drawn so the icon needs no
// checked-in artwork.
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
    // The macOS icon grid: an 824/1024 rounded square, centered.
    let inset = s * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(starting: NSColor(srgbRed: 0.00, green: 0.75, blue: 0.90, alpha: 1),
               ending: NSColor(srgbRed: 0.00, green: 0.45, blue: 0.62, alpha: 1))!
        .draw(in: tilePath, angle: -90)

    // The eye: two arcs meeting at the corners.
    let cx = s / 2, cy = s / 2
    let w = tile.width * 0.36, h = tile.width * 0.24
    let eye = NSBezierPath()
    eye.move(to: NSPoint(x: cx - w, y: cy))
    eye.curve(to: NSPoint(x: cx + w, y: cy), controlPoint1: NSPoint(x: cx - w / 2, y: cy + h * 1.3), controlPoint2: NSPoint(x: cx + w / 2, y: cy + h * 1.3))
    eye.curve(to: NSPoint(x: cx - w, y: cy), controlPoint1: NSPoint(x: cx + w / 2, y: cy - h * 1.3), controlPoint2: NSPoint(x: cx - w / 2, y: cy - h * 1.3))
    eye.close()
    NSColor.white.setFill()
    eye.fill()

    let iris = tile.width * 0.15
    let irisPath = NSBezierPath(ovalIn: NSRect(x: cx - iris, y: cy - iris, width: 2 * iris, height: 2 * iris))
    NSColor(srgbRed: 0.05, green: 0.20, blue: 0.30, alpha: 1).setFill()
    irisPath.fill()
    let glint = iris * 0.32
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: cx + iris * 0.25, y: cy + iris * 0.25, width: glint, height: glint)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try draw(size: points * scale).write(to: out.appending(path: name))
    }
}
