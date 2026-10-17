// Ritar app-ikonen (1024x1024 PNG): mörk squircle med grön mus och glöd.
// Kör: swift makeicon.swift <ut.png>

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let green = NSColor(red: 0x44/255, green: 0xD6/255, blue: 0x2C/255, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS-ikoner har ~10 % luft runt den rundade rutan
let inset: CGFloat = 100
let tile = NSRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// Skugga under rutan
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

// Mörk gradient
NSGradient(starting: NSColor(white: 0.22, alpha: 1), ending: NSColor(white: 0.06, alpha: 1))!
    .draw(in: tilePath, angle: -90)

// Grön glöd i mitten
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
NSGradient(colors: [green.withAlphaComponent(0.45), green.withAlphaComponent(0.0)])!
    .draw(fromCenter: NSPoint(x: size/2, y: size/2), radius: 0,
          toCenter: NSPoint(x: size/2, y: size/2), radius: 360, options: [])
NSGraphicsContext.restoreGraphicsState()

// Musen (SF Symbol) i grönt med glöd
let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .regular)
    .applying(.init(paletteColors: [green]))
if let mouse = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = mouse.size
    let r = NSRect(x: (size - s.width)/2, y: (size - s.height)/2, width: s.width, height: s.height)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = green
    glow.shadowBlurRadius = 60
    glow.set()
    mouse.draw(in: r)
    NSGraphicsContext.restoreGraphicsState()
    mouse.draw(in: r)
}

// Tunn grön kant
green.withAlphaComponent(0.6).setStroke()
let border = NSBezierPath(roundedRect: tile.insetBy(dx: 4, dy: 4), xRadius: 181, yRadius: 181)
border.lineWidth = 8
border.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Skrev \(out)")
