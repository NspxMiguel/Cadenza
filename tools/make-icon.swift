import AppKit

// Draws the app icon and writes an .iconset, which iconutil turns into .icns.
//
// The mark is a fermata — the notation that holds a note beyond its written
// value, and the sign that traditionally opens the space a cadenza fills.

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Cadenza.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func draw(size: Int) -> NSImage {
    let side = CGFloat(size)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    // Squircle, matching the platform's icon silhouette.
    let inset = side * 0.055
    let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let shape = CGPath(roundedRect: rect,
                       cornerWidth: rect.width * 0.225,
                       cornerHeight: rect.height * 0.225,
                       transform: nil)
    context.addPath(shape)
    context.clip()

    // Warm, dark, faintly aged — closer to a concert programme than to a neon
    // music app.
    let colors = [
        NSColor(calibratedRed: 0.36, green: 0.09, blue: 0.13, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.13, green: 0.04, blue: 0.07, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: [])
    }

    // Fermata: an arc with a dot beneath it.
    let cream = NSColor(calibratedRed: 0.97, green: 0.94, blue: 0.88, alpha: 1)
    cream.setStroke()
    cream.setFill()

    let centre = CGPoint(x: side / 2, y: side * 0.44)
    let radius = side * 0.26
    let lineWidth = side * 0.055

    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: centre.x, y: centre.y),
                  radius: radius, startAngle: 0, endAngle: 180)
    arc.lineWidth = lineWidth
    arc.lineCapStyle = .round
    arc.stroke()

    let dotRadius = side * 0.052
    NSBezierPath(ovalIn: NSRect(x: centre.x - dotRadius, y: centre.y - dotRadius * 0.2,
                                width: dotRadius * 2, height: dotRadius * 2)).fill()

    image.unlockFocus()
    return image
}

for size in sizes {
    let image = draw(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }

    // iconutil expects both icon_NxN and icon_(N/2)x(N/2)@2x names.
    try? png.write(to: URL(fileURLWithPath: "\(output)/icon_\(size)x\(size).png"))
    if size >= 32 {
        try? png.write(to: URL(fileURLWithPath: "\(output)/icon_\(size / 2)x\(size / 2)@2x.png"))
    }
}

print("iconset em \(output)")
