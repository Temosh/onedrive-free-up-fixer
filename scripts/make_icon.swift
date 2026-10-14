// Draws the app icon (1024x1024 PNG): cloud with an "offload" arrow and a wrench badge.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func fillGradient(_ path: CGPath, _ top: UInt32, _ bottom: UInt32, from: CGFloat, to: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: from), end: CGPoint(x: 0, y: to), options: [])
    ctx.restoreGState()
}

// Background: macOS icon grid (824pt rounded square, centered) with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x2F7CF0))
ctx.fillPath()
ctx.restoreGState()
fillGradient(tilePath, 0x5FB2FF, 0x1E56D0, from: 924, to: 100)

// Cloud: wide pill-shaped bottom layer with three lobes on top, plus a subtle shadow.
let cloud = CGMutablePath()
cloud.addRoundedRect(in: CGRect(x: 200, y: 400, width: 624, height: 180), cornerWidth: 90, cornerHeight: 90)
cloud.addEllipse(in: CGRect(x: 250, y: 465, width: 240, height: 240))   // left lobe
cloud.addEllipse(in: CGRect(x: 347, y: 475, width: 330, height: 330))   // top lobe
cloud.addEllipse(in: CGRect(x: 550, y: 480, width: 210, height: 210))   // right lobe
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x0A2A70, 0.35))
ctx.addPath(cloud)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// Up arrow inside the cloud ("send to cloud, free the disk").
let arrow = CGMutablePath()
arrow.addRoundedRect(in: CGRect(x: 476, y: 455, width: 72, height: 180), cornerWidth: 20, cornerHeight: 20)
arrow.move(to: CGPoint(x: 512, y: 748))
arrow.addLine(to: CGPoint(x: 400, y: 620))
arrow.addLine(to: CGPoint(x: 624, y: 620))
arrow.closeSubpath()
fillGradient(arrow, 0x4A9BFF, 0x1F5FD6, from: 748, to: 455)

// Badge: orange circle with a white ring, bottom right.
let badgeCenter = CGPoint(x: 728, y: 296)
let badgeRadius: CGFloat = 138
ctx.addEllipse(in: CGRect(x: badgeCenter.x - badgeRadius - 16, y: badgeCenter.y - badgeRadius - 16,
                          width: (badgeRadius + 16) * 2, height: (badgeRadius + 16) * 2))
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
let badge = CGPath(ellipseIn: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                                     width: badgeRadius * 2, height: badgeRadius * 2), transform: nil)
fillGradient(badge, 0xFFC24A, 0xFF7418, from: badgeCenter.y + badgeRadius, to: badgeCenter.y - badgeRadius)

// Wrench (white), rotated 45°, drawn in a layer so the jaw notch can be cut out.
ctx.saveGState()
ctx.translateBy(x: badgeCenter.x, y: badgeCenter.y)
ctx.rotate(by: -.pi / 4)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(color(0xFFFFFF))
// Spans -126...106 along its axis: shifted toward the handle so the heavy head looks centered.
ctx.addPath(CGPath(roundedRect: CGRect(x: -26, y: -126, width: 52, height: 150),
                   cornerWidth: 26, cornerHeight: 26, transform: nil))
ctx.addEllipse(in: CGRect(x: -58, y: -10, width: 116, height: 116))
ctx.fillPath()
ctx.setBlendMode(.clear)
ctx.fill(CGRect(x: -21, y: 52, width: 42, height: 70))  // jaw opening
ctx.endTransparencyLayer()
ctx.restoreGState()

NSGraphicsContext.current = nil
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
