// Renders the app icons. Usage:
//   swift tools/make-icon.swift <out.png> [ios|ios-dark|mac]
// ios / ios-dark: full-bleed 1024px square (iOS applies the rounded mask itself).
// mac: 1024px canvas with the macOS rounded-rect shape, margins and shadow baked in.
import CoreGraphics
import Foundation
import ImageIO

let out = CommandLine.arguments[1]
let style = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "ios"
let size = 1024.0
let rgb = CGColorSpaceCreateDeviceRGB()

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Draws the artwork (background, signal arcs, play/pause button) filling `rect`.
func drawArt(in ctx: CGContext, rect: CGRect, dark: Bool) {
    let s = rect.width / size
    func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }

    let bg = dark ? [color(28, 28, 38), color(10, 10, 16)] : [color(255, 94, 98), color(124, 58, 237)]
    ctx.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: bg as CFArray, locations: [0, 1])!,
                           start: p(0, size), end: p(size, 0), options: [])

    let center = p(size / 2, size / 2 - 90)

    ctx.setLineCap(.round)
    for (i, r) in [300.0, 380.0].enumerated() {
        ctx.setStrokeColor(color(255, 255, 255, i == 0 ? 0.85 : 0.5))
        ctx.setLineWidth(44 * s)
        ctx.addArc(center: center, radius: r * s, startAngle: .pi * 0.30, endAngle: .pi * 0.70, clockwise: false)
        ctx.strokePath()
    }

    let radius = 220.0 * s
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24 * s), blur: 60 * s, color: color(0, 0, 0, 0.35))
    ctx.setFillColor(color(255, 255, 255))
    ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ctx.restoreGState()

    ctx.setFillColor(dark ? color(255, 94, 98) : color(124, 58, 237))
    let h = 170.0 * s
    let tx = center.x - 125 * s
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: tx, y: center.y + h / 2))
    triangle.addLine(to: CGPoint(x: tx, y: center.y - h / 2))
    triangle.addLine(to: CGPoint(x: tx + 140 * s, y: center.y))
    triangle.closeSubpath()
    ctx.addPath(triangle)
    ctx.fillPath()
    for x in [center.x + 45 * s, center.x + 95 * s] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: center.y - h / 2, width: 34 * s, height: h),
                           cornerWidth: 10 * s, cornerHeight: 10 * s, transform: nil))
        ctx.fillPath()
    }
}

let mac = style == "mac"
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                    bitmapInfo: mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!

if mac {
    // macOS icon grid: 824pt rounded rect centred on a 1024 canvas, slightly raised for its shadow.
    let shape = CGRect(x: 100, y: 112, width: 824, height: 824)
    let path = CGPath(roundedRect: shape, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0, 0, 0, 0.3))
    ctx.addPath(path)
    ctx.setFillColor(color(0, 0, 0))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    drawArt(in: ctx, rect: shape, dark: false)
    ctx.restoreGState()
} else {
    drawArt(in: ctx, rect: CGRect(x: 0, y: 0, width: size, height: size), dark: style == "ios-dark")
}

let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
CGImageDestinationFinalize(destination)
