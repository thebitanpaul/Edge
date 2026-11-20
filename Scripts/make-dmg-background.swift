#!/usr/bin/env swift
//
// Draws the picture behind the Edge disk image's window: an arrow from Edge to Applications,
// and how to get past Gatekeeper the first time. Edge is not notarised, so macOS refuses to
// open it until the user says Open Anyway in System Settings — and the disk image is the one
// thing every new user is guaranteed to look at before they hit that.
//
//   swift Scripts/make-dmg-background.swift OUT_DIR
//
// Writes OUT_DIR/background.png (1x) and OUT_DIR/background@2x.png. Scripts/package-dmg.sh
// combines them into one HiDPI TIFF and places the icons to match the layout below.
//
// Finder draws the icon names itself, white in Dark Mode and black in Light Mode, so the
// strip under the icons is kept a mid-tone where both read.

import AppKit

// Keep in step with Scripts/package-dmg.sh.
let size = CGSize(width: 660, height: 480)
let edgeIcon = CGPoint(x: 170, y: 140)        // icon centres, top-left origin, as Finder wants
let applicationsIcon = CGPoint(x: 490, y: 140)

let steps = [
    "Drag Edge into Applications.",
    "Open Edge.",
    "If macOS blocks it, click Done.",
    "Go to System Settings ▸ Privacy & Security.",
    "Under Security, click Open Anyway.",
]
let footnote = "Edge isn't notarised by Apple yet, so macOS asks this once."

func draw(scale: CGFloat, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // Drawn in pixels with our own scale; the point size goes on afterwards, for the DPI that
    // tells Finder which image is the @2x one. (Set before, the context would scale twice.)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    let cg = context.cgContext
    // Top-left origin, like Finder's icon positions.
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)

    // Background: a quiet top half for the icons, a white card for the instructions.
    NSColor(calibratedRed: 0.55, green: 0.58, blue: 0.63, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    // Arrow from Edge to Applications.
    let y = edgeIcon.y
    let from = edgeIcon.x + 78, to = applicationsIcon.x - 78
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: from, y: y))
    arrow.line(to: NSPoint(x: to - 14, y: y))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.9).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: to, y: y))
    head.line(to: NSPoint(x: to - 20, y: y - 13))
    head.line(to: NSPoint(x: to - 20, y: y + 13))
    head.close()
    NSColor.white.withAlphaComponent(0.9).setFill()
    head.fill()

    // Instructions card.
    let card = NSRect(x: 24, y: 252, width: size.width - 48, height: size.height - 252 - 24)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()

    let ink = NSColor(calibratedWhite: 0.12, alpha: 1)
    let soft = NSColor(calibratedWhite: 0.42, alpha: 1)
    let left = card.minX + 26

    ("Opening Edge the first time" as NSString).draw(
        at: NSPoint(x: left, y: card.minY + 18),
        withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: ink])

    var lineY = card.minY + 48
    for (index, step) in steps.enumerated() {
        ("\(index + 1)." as NSString).draw(
            at: NSPoint(x: left, y: lineY),
            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13.5, weight: .semibold),
                             .foregroundColor: soft])
        (step as NSString).draw(
            at: NSPoint(x: left + 22, y: lineY),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: ink])
        lineY += 23
    }

    (footnote as NSString).draw(
        at: NSPoint(x: left, y: card.maxY - 28),
        withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: soft])

    NSGraphicsContext.restoreGraphicsState()
    rep.size = size
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-dmg-background", code: 1)
    }
    try png.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift Scripts/make-dmg-background.swift OUT_DIR\n".data(using: .utf8)!)
    exit(1)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try draw(scale: 1, to: out.appendingPathComponent("background.png"))
try draw(scale: 2, to: out.appendingPathComponent("background@2x.png"))
