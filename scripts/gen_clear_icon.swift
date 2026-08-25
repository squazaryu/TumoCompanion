#!/usr/bin/env swift
// Copies the reviewed generated Clear icons into the exact 1024px asset shape
// expected by Xcode. Keeping the source PNGs in the repository prevents a future
// build from silently recreating the old generic white-device icon.
import AppKit
import Foundation

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

let scriptURL = URL(fileURLWithPath: #filePath)
let source = scriptURL
    .deletingLastPathComponent()
    .appendingPathComponent("icon_sources")
    .appendingPathComponent("clear-\(theme).png")
guard let sourceImage = NSImage(contentsOf: source) else {
    fputs("could not read \(source.path)\n", stderr)
    exit(66)
}

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("could not create a 1024px bitmap\n", stderr)
    exit(70)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
graphics.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
sourceImage.draw(
    in: NSRect(x: 0, y: 0, width: size, height: size),
    from: .zero,
    operation: .copy,
    fraction: 1
)
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not encode \(output.path)\n", stderr)
    exit(70)
}

try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: output)
print("wrote \(output.path) (\(theme), alpha-safe)")
