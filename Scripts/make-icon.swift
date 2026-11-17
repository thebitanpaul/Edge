#!/usr/bin/env swift
//
// Draws Continuous.app's icon and writes Resources/Continuous.icns.
//
// Generated rather than committed as an opaque binary: the shapes are legible in the diff,
// the whole thing regenerates with one command, and nobody has to open an image editor to
// change a colour. Run it with:  swift Scripts/make-icon.swift
//
// The subject is what the app actually does: two screens, and one pointer crossing the gap
// between them. The screens are kept faint and the arrow bold, because at 16 points the arrow
// is the only thing that will still read.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/Continuous.iconset")
let output = root.appendingPathComponent("Resources/Continuous.icns")

// MARK: - Shapes

/// The classic arrow pointer, in a 0...1 box with the tip at the top-left.
func arrowPath(in rect: CGRect) -> CGPath {
    let unit: [(CGFloat, CGFloat)] = [
        (0.00, 0.00), (0.00, 0.86), (0.22, 0.65), (0.36, 1.00),
        (0.52, 0.93), (0.38, 0.59), (0.66, 0.57),
    ]
    let path = CGMutablePath()
    for (i, p) in unit.enumerated() {
        // y is flipped: the unit shape is described from the tip downwards.
        let point = CGPoint(x: rect.minX + p.0 * rect.width,
                            y: rect.maxY - p.1 * rect.height)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func squirclePath(in rect: CGRect) -> CGPath {
    // Close enough to the macOS app-icon silhouette at every size this is rendered at.
    CGPath(roundedRect: rect,
           cornerWidth: rect.width * 0.2237,
           cornerHeight: rect.height * 0.2237,
           transform: nil)
}

// MARK: - Drawing

func draw(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.interpolationQuality = .high
    context.setShouldAntialias(true)

    // Background: a deep indigo-to-violet gradient inside the rounded square.
    let plate = CGRect(x: s * 0.055, y: s * 0.055, width: s * 0.89, height: s * 0.89)
    context.saveGState()
    context.addPath(squirclePath(in: plate))
    context.clip()

    let colours = [
        CGColor(srgbRed: 0.27, green: 0.31, blue: 0.86, alpha: 1),
        CGColor(srgbRed: 0.44, green: 0.24, blue: 0.80, alpha: 1),
        CGColor(srgbRed: 0.18, green: 0.16, blue: 0.45, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: colours, locations: [0, 0.55, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: plate.minX, y: plate.maxY),
                                   end: CGPoint(x: plate.maxX, y: plate.minY),
                                   options: [])
    }

    // A soft highlight across the top, so the plate reads as a surface rather than a flat fill.
    if let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
                                       CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                              locations: [0, 1]) {
        context.drawLinearGradient(sheen,
                                   start: CGPoint(x: plate.midX, y: plate.maxY),
                                   end: CGPoint(x: plate.midX, y: plate.midY),
                                   options: [])
    }
    context.restoreGState()

    // Two screens, side by side with a gap between them. Deliberately low contrast: they are
    // context for the arrow, not competition for it.
    let screenY = s * 0.345
    let screenH = s * 0.30
    let screenW = s * 0.305
    let leftScreen = CGRect(x: s * 0.145, y: screenY, width: screenW, height: screenH)
    let rightScreen = CGRect(x: s * 0.55, y: screenY, width: screenW, height: screenH)

    for screen in [leftScreen, rightScreen] {
        let path = CGPath(roundedRect: screen,
                          cornerWidth: s * 0.035, cornerHeight: s * 0.035, transform: nil)
        context.addPath(path)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.13))
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.34))
        context.setLineWidth(max(1, s * 0.012))
        context.strokePath()
    }

    // The pointer, straddling the gap: leaving one screen, arriving on the other.
    let arrowHeight = s * 0.44
    let arrowWidth = arrowHeight * 0.66
    let main = CGRect(x: s * 0.405, y: s * 0.235, width: arrowWidth, height: arrowHeight)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                      blur: s * 0.035,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
    context.addPath(arrowPath(in: main))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // A thin dark keyline keeps the white arrow from dissolving into the lighter gradient.
    context.addPath(arrowPath(in: main))
    context.setStrokeColor(CGColor(srgbRed: 0.12, green: 0.10, blue: 0.28, alpha: 0.55))
    context.setLineWidth(max(1, s * 0.008))
    context.setLineJoin(.round)
    context.strokePath()

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not create \(url.lastPathComponent)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "could not write \(url.lastPathComponent)"])
    }
}

// MARK: - Run

let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

// Every slot `iconutil` expects, base size and @2x.
let slots: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for slot in slots {
    guard let image = draw(size: slot.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(slot.name)\n".utf8))
        exit(1)
    }
    try write(image, to: iconset.appendingPathComponent("\(slot.name).png"))
}
print("rendered \(slots.count) sizes into \(iconset.path)")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
try? fm.removeItem(at: iconset)

let bytes = (try? fm.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
print("wrote \(output.path) (\(bytes) bytes)")
