import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let background = NSBezierPath(roundedRect: rect.insetBy(dx: 48, dy: 48), xRadius: 210, yRadius: 210)
    NSColor(srgbRed: 0.11, green: 0.35, blue: 0.78, alpha: 1).setFill()
    background.fill()

    NSColor.white.setFill()
    NSColor.white.setStroke()
    let shaft = NSBezierPath(roundedRect: NSRect(x: 452, y: 390, width: 120, height: 250), xRadius: 16, yRadius: 16)
    shaft.fill()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 332, y: 420))
    head.line(to: NSPoint(x: 512, y: 230))
    head.line(to: NSPoint(x: 692, y: 420))
    head.close()
    head.fill()
    let tray = NSBezierPath()
    tray.lineWidth = 64
    tray.lineCapStyle = .round
    tray.lineJoinStyle = .round
    tray.move(to: NSPoint(x: 300, y: 250))
    tray.line(to: NSPoint(x: 300, y: 170))
    tray.line(to: NSPoint(x: 724, y: 170))
    tray.line(to: NSPoint(x: 724, y: 250))
    tray.stroke()
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    fputs("could not draw icon\n", stderr)
    exit(1)
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support/AppIcon.iconset/icon_1024x1024.png"
let url = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: url)
