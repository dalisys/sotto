import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else { fatalError("Usage: create-icon.swift OUTPUT_DIRECTORY") }
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let orange = NSColor(red: 1, green: 79.0/255, blue: 0, alpha: 1)
func mark(_ color: NSColor, cutouts: Bool) {
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: 230, y: 302, width: 564, height: 420), xRadius: 128, yRadius: 128).fill()
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 330, y: 330)); tail.line(to: NSPoint(x: 290, y: 210))
    tail.curve(to: NSPoint(x: 467, y: 330), controlPoint1: NSPoint(x: 364, y: 239), controlPoint2: NSPoint(x: 421, y: 284))
    tail.close(); tail.fill()
    let heights: [CGFloat] = [100, 170, 230, 170, 100]
    for (index, height) in heights.enumerated() {
        let path = NSBezierPath(roundedRect: NSRect(x: 367 + CGFloat(index) * 55, y: 512 - height/2, width: 30, height: height), xRadius: 15, yRadius: 15)
        if cutouts {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill(); path.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else { orange.setFill(); path.fill() }
    }
}
func render(size: Int, template: Bool = false) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: size * 4, bitsPerPixel: 32), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(size)/1024); transform.concat()
    if template {
        let zoom = NSAffineTransform(); zoom.translateX(by: -280, yBy: -250); zoom.scale(by: 1.55); zoom.concat()
        mark(.black, cutouts: true)
    } else {
        orange.setFill()
        NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 206, yRadius: 206).fill()
        mark(.white, cutouts: false)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    return data
}
for size in [16, 32, 64, 128, 256, 512, 1024] { try render(size: size).write(to: directory.appendingPathComponent("\(size).png")) }
try render(size: 36, template: true).write(to: directory.appendingPathComponent("SottoMenuTemplate.png"))
