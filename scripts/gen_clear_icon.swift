#!/usr/bin/env swift
// Generates the alpha-safe alternate icons used for iOS Clear-style choices.
// The system still decides the final Home Screen treatment, but these assets do
// not bake a full opaque square behind the Flipper mark.
import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("usage: gen_clear_icon.swift <output.png> <light|dark>\n", stderr)
    exit(64)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let theme = CommandLine.arguments[2]
guard theme == "light" || theme == "dark" else {
    fputs("theme must be light or dark\n", stderr)
    exit(64)
}

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
context.clear(CGRect(x: 0, y: 0, width: size, height: size))

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

let orange = color(1.0, 0.43, 0.03)
let body = theme == "light" ? color(0.98, 0.98, 0.97) : color(0.12, 0.12, 0.13)
let bodyStroke = theme == "light" ? color(0.72, 0.72, 0.72) : color(0.38, 0.38, 0.4)
let dark = color(0.06, 0.06, 0.065)
let white = color(0.98, 0.98, 0.98)

let device = CGRect(x: 142, y: 282, width: 740, height: 460)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -16), blur: 28,
                  color: color(0, 0, 0, theme == "light" ? 0.22 : 0.45))
context.setFillColor(body)
context.addPath(CGPath(roundedRect: device, cornerWidth: 96, cornerHeight: 96, transform: nil))
context.fillPath()
context.restoreGState()
context.setStrokeColor(bodyStroke)
context.setLineWidth(7)
context.addPath(CGPath(roundedRect: device.insetBy(dx: 4, dy: 4), cornerWidth: 92, cornerHeight: 92, transform: nil))
context.strokePath()

// Screen and Sub-GHz signal mark.
let screen = CGRect(x: 205, y: 392, width: 318, height: 222)
context.setFillColor(dark)
context.addPath(CGPath(roundedRect: screen, cornerWidth: 32, cornerHeight: 32, transform: nil))
context.fillPath()
let signalCenter = CGPoint(x: screen.minX + 88, y: screen.midY)
context.setStrokeColor(orange)
context.setLineCap(.round)
for (index, radius) in [38.0, 75.0, 112.0].enumerated() {
    context.setLineWidth(23 - CGFloat(index) * 4)
    context.addArc(center: signalCenter, radius: radius,
                   startAngle: -.pi * 0.42, endAngle: .pi * 0.42, clockwise: false)
    context.strokePath()
}
context.setFillColor(orange)
context.fillEllipse(in: CGRect(x: signalCenter.x - 17, y: signalCenter.y - 17, width: 34, height: 34))

// The physical five-way control, simplified for the small Home Screen glyph.
let center = CGPoint(x: device.maxX - 190, y: device.midY)
context.setFillColor(orange)
context.fillEllipse(in: CGRect(x: center.x - 116, y: center.y - 116, width: 232, height: 232))
context.setFillColor(theme == "light" ? white : dark)
context.fillEllipse(in: CGRect(x: center.x - 82, y: center.y - 82, width: 164, height: 164))
context.setFillColor(orange)
context.fillEllipse(in: CGRect(x: center.x - 28, y: center.y - 28, width: 56, height: 56))

func triangle(_ points: [CGPoint]) {
    let path = CGMutablePath()
    path.addLines(between: points + [points[0]])
    context.addPath(path)
    context.fillPath()
}

context.setFillColor(theme == "light" ? color(0.2, 0.2, 0.2) : white)
triangle([
    CGPoint(x: center.x, y: center.y + 104),
    CGPoint(x: center.x - 18, y: center.y + 72),
    CGPoint(x: center.x + 18, y: center.y + 72)
])
triangle([
    CGPoint(x: center.x, y: center.y - 104),
    CGPoint(x: center.x - 18, y: center.y - 72),
    CGPoint(x: center.x + 18, y: center.y - 72)
])
triangle([
    CGPoint(x: center.x - 104, y: center.y),
    CGPoint(x: center.x - 72, y: center.y - 18),
    CGPoint(x: center.x - 72, y: center.y + 18)
])
triangle([
    CGPoint(x: center.x + 104, y: center.y),
    CGPoint(x: center.x + 72, y: center.y - 18),
    CGPoint(x: center.x + 72, y: center.y + 18)
])

let image = context.makeImage()!
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try png.write(to: output)
print("wrote \(output.path) (\(theme), alpha-safe)")
