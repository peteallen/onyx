#!/usr/bin/swift

import AppKit
import Foundation

enum IconRenderError: LocalizedError {
    case couldNotCreateBitmap(Int)
    case couldNotEncodePNG(Int)

    var errorDescription: String? {
        switch self {
        case let .couldNotCreateBitmap(size):
            "Could not create the \(size)-pixel icon bitmap."
        case let .couldNotEncodePNG(size):
            "Could not encode the \(size)-pixel icon as PNG."
        }
    }
}

private struct IconVariant {
    let filename: String
    let pixels: Int
    let icnsType: String
}

private let variants = [
    IconVariant(filename: "icon_16x16.png", pixels: 16, icnsType: "icp4"),
    IconVariant(filename: "icon_16x16@2x.png", pixels: 32, icnsType: "ic11"),
    IconVariant(filename: "icon_32x32.png", pixels: 32, icnsType: "icp5"),
    IconVariant(filename: "icon_32x32@2x.png", pixels: 64, icnsType: "ic12"),
    IconVariant(filename: "icon_128x128.png", pixels: 128, icnsType: "ic07"),
    IconVariant(filename: "icon_128x128@2x.png", pixels: 256, icnsType: "ic13"),
    IconVariant(filename: "icon_256x256.png", pixels: 256, icnsType: "ic08"),
    IconVariant(filename: "icon_256x256@2x.png", pixels: 512, icnsType: "ic14"),
    IconVariant(filename: "icon_512x512.png", pixels: 512, icnsType: "ic09"),
    IconVariant(filename: "icon_512x512@2x.png", pixels: 1_024, icnsType: "ic10"),
]

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}

private func makeICNS(_ entries: [(type: String, png: Data)]) -> Data {
    var payload = Data()
    for entry in entries {
        precondition(entry.type.utf8.count == 4)
        payload.append(contentsOf: entry.type.utf8)
        payload.appendBigEndian(UInt32(entry.png.count + 8))
        payload.append(entry.png)
    }

    var result = Data("icns".utf8)
    result.appendBigEndian(UInt32(payload.count + 8))
    result.append(payload)
    return result
}

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

private func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconRenderError.couldNotCreateBitmap(pixels)
    }

    let side = CGFloat(pixels)
    let outerInset = side * 0.045
    let outerRect = NSRect(x: outerInset, y: outerInset, width: side - 2 * outerInset, height: side - 2 * outerInset)
    let outerPath = NSBezierPath(roundedRect: outerRect, xRadius: side * 0.205, yRadius: side * 0.205)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()

    let outerShadow = NSShadow()
    outerShadow.shadowColor = color(0.01, 0.01, 0.025, alpha: 0.54)
    outerShadow.shadowBlurRadius = max(1, side * 0.045)
    outerShadow.shadowOffset = NSSize(width: 0, height: -side * 0.022)
    outerShadow.set()
    NSGradient(colors: [
        color(0.105, 0.11, 0.145),
        color(0.035, 0.038, 0.055),
    ])?.draw(in: outerPath, angle: -58)

    NSGraphicsContext.saveGraphicsState()
    outerPath.addClip()
    let ambientRect = NSRect(
        x: side * 0.12,
        y: side * 0.16,
        width: side * 0.78,
        height: side * 0.78
    )
    NSGradient(colors: [
        color(0.34, 0.28, 0.88, alpha: 0.30),
        color(0.12, 0.44, 0.70, alpha: 0.07),
        color(0.03, 0.04, 0.06, alpha: 0),
    ])?.draw(in: ambientRect, relativeCenterPosition: NSPoint(x: -0.08, y: 0.05))
    NSGraphicsContext.restoreGraphicsState()

    color(1, 1, 1, alpha: 0.11).setStroke()
    outerPath.lineWidth = max(0.65, side * 0.0022)
    outerPath.stroke()

    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: side / 2, yBy: side / 2)
    transform.rotate(byDegrees: 45)
    transform.translateX(by: -side / 2, yBy: -side / 2)
    transform.concat()

    let markSide = side * 0.515
    let markRect = NSRect(
        x: (side - markSide) / 2,
        y: (side - markSide) / 2,
        width: markSide,
        height: markSide
    )
    let markPath = NSBezierPath(
        roundedRect: markRect,
        xRadius: side * 0.105,
        yRadius: side * 0.105
    )

    let markShadow = NSShadow()
    markShadow.shadowColor = color(0.25, 0.20, 0.98, alpha: 0.42)
    markShadow.shadowBlurRadius = max(1, side * 0.065)
    markShadow.shadowOffset = NSSize(width: side * 0.015, height: -side * 0.018)
    markShadow.set()
    NSGradient(colors: [
        color(0.49, 0.38, 1.00),
        color(0.30, 0.69, 0.97),
        color(0.19, 0.82, 0.86),
    ])?.draw(in: markPath, angle: -38)

    NSGraphicsContext.saveGraphicsState()
    markPath.addClip()

    let upperFacet = NSBezierPath()
    upperFacet.move(to: NSPoint(x: markRect.minX, y: markRect.maxY))
    upperFacet.line(to: NSPoint(x: markRect.maxX, y: markRect.maxY))
    upperFacet.line(to: NSPoint(x: markRect.midX, y: markRect.midY))
    upperFacet.close()
    color(1, 1, 1, alpha: 0.13).setFill()
    upperFacet.fill()

    let lowerFacet = NSBezierPath()
    lowerFacet.move(to: NSPoint(x: markRect.minX, y: markRect.minY))
    lowerFacet.line(to: NSPoint(x: markRect.maxX, y: markRect.minY))
    lowerFacet.line(to: NSPoint(x: markRect.midX, y: markRect.midY))
    lowerFacet.close()
    color(0.035, 0.04, 0.13, alpha: 0.18).setFill()
    lowerFacet.fill()
    NSGraphicsContext.restoreGraphicsState()

    color(1, 1, 1, alpha: 0.18).setStroke()
    markPath.lineWidth = max(0.75, side * 0.0028)
    markPath.stroke()

    let innerSide = side * 0.225
    let innerRect = NSRect(
        x: (side - innerSide) / 2,
        y: (side - innerSide) / 2,
        width: innerSide,
        height: innerSide
    )
    let innerPath = NSBezierPath(
        roundedRect: innerRect,
        xRadius: side * 0.047,
        yRadius: side * 0.047
    )
    color(0.045, 0.052, 0.095, alpha: 0.78).setFill()
    innerPath.fill()
    color(1, 1, 1, alpha: 0.88).setStroke()
    innerPath.lineWidth = max(1.2, side * 0.017)
    innerPath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconRenderError.couldNotEncodePNG(pixels)
    }
    return data
}

let arguments = CommandLine.arguments
guard arguments.count == 2 || arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("Usage: render-app-icon.swift ICONSET_DIRECTORY [ICNS_PATH]\n".utf8)
    )
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

var icnsEntries: [(type: String, png: Data)] = []
icnsEntries.reserveCapacity(variants.count)
for variant in variants {
    let data = try renderIcon(pixels: variant.pixels)
    try data.write(to: outputDirectory.appendingPathComponent(variant.filename), options: .atomic)
    icnsEntries.append((type: variant.icnsType, png: data))
}

print("Rendered Onyx iconset: \(outputDirectory.path)")
if arguments.count == 3 {
    let icnsURL = URL(fileURLWithPath: arguments[2])
    try FileManager.default.createDirectory(
        at: icnsURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try makeICNS(icnsEntries).write(to: icnsURL, options: .atomic)
    print("Rendered Onyx app icon: \(icnsURL.path)")
}
