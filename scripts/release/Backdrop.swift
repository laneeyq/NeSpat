import AppKit

// Draw in Finder points and keep both pixel densities in the TIFF.
let width = 560, height = 320
let canvas = NSRect(x: 0, y: 0, width: width, height: height)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func line(_ points: [NSPoint], ink: NSColor, weight: CGFloat) {
    let path = NSBezierPath()
    path.move(to: points[0])
    points.dropFirst().forEach { path.line(to: $0) }
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = weight
    ink.setStroke()
    path.stroke()
}
func draw() {
    NSGradient(colors: [color(0.10,0.088,0.083), color(0.20,0.15,0.12)])!.draw(in: canvas, angle: 26)
    // Sweeping contours stay behind the controls and fade toward the centre.
    for index in 0..<22 {
        let shift = CGFloat(index) * 5.5
        let contour = NSBezierPath()
        contour.move(to: NSPoint(x:230 + shift, y:-28))
        contour.curve(to:NSPoint(x:590, y:150 + shift),
                      controlPoint1:NSPoint(x:400 + shift, y:50),
                      controlPoint2:NSPoint(x:462 - shift/2, y:74 + shift))
        contour.lineWidth = 0.8
        color(0.85,0.57,0.33,0.12).setStroke()
        contour.stroke()
    }
    let cream = color(1,0.94,0.85)
    func text(_ string: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, ink: NSColor) {
        (string as NSString).draw(at: NSPoint(x: 36, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink
        ])
    }
    text("NeSpat", y: 245, size: 38, weight: .semibold, ink: cream)
    text("Перетащите приложение в «Программы»", y: 219, size: 16, weight: .regular, ink: color(0.86,0.80,0.74))
    // A small steam motif echoes the cup on the application icon.
    for offset in [0, 10, 20] {
        let x = CGFloat(483 + offset)
        let path = NSBezierPath()
        path.move(to: NSPoint(x:x, y:250))
        path.curve(to: NSPoint(x:x+4, y:277), controlPoint1:NSPoint(x:x+14, y:259), controlPoint2:NSPoint(x:x-4,y:265))
        path.lineWidth = 2
        path.lineCapStyle = .round
        color(0.93,0.67,0.39,0.78).setStroke()
        path.stroke()
    }
    for x in [155,405] {
        let rect = NSRect(x:x-64, y:72, width:128, height:128)
        let well = NSBezierPath(roundedRect:rect, xRadius:28, yRadius:28)
        color(1,0.91,0.80,0.055).setFill()
        well.fill()
        color(1,0.91,0.80,0.16).setStroke()
        well.lineWidth = 1
        well.stroke()
    }
    let amber = color(0.95,0.71,0.45)
    line([NSPoint(x:250,y:136),NSPoint(x:310,y:136)], ink: amber, weight:2.5)
    line([NSPoint(x:300,y:146),NSPoint(x:310,y:136),NSPoint(x:300,y:126)], ink:amber, weight:2.5)
}
let image = NSImage(size: canvas.size)
for scale in [1,2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:width*scale, pixelsHigh:height*scale,
                                  bitsPerSample:8, samplesPerPixel:4, hasAlpha:true, isPlanar:false, colorSpaceName:.deviceRGB,
                                  bytesPerRow:0, bitsPerPixel:0)!
    bitmap.size = canvas.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(bitmap)
}
try image.tiffRepresentation!.write(to: URL(fileURLWithPath:CommandLine.arguments[1]))
