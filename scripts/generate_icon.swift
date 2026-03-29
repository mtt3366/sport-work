import AppKit
import Foundation

let outputDirectory = CommandLine.arguments.dropFirst().first ?? {
    fputs("Usage: swift scripts/generate_icon.swift <iconset-directory>\n", stderr)
    exit(1)
}()

let fileManager = FileManager.default
let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)

try? fileManager.removeItem(at: outputURL)
try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

let iconSpecs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (fileName, size) in iconSpecs {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.22

    let backgroundPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSColor.white.setFill()
    backgroundPath.fill()
    NSColor(calibratedWhite: 0.0, alpha: 0.12).setStroke()
    backgroundPath.lineWidth = max(2, size * 0.015)
    backgroundPath.stroke()

    let ringInset = size * 0.12
    let ringRect = rect.insetBy(dx: ringInset, dy: ringInset)
    NSColor(calibratedWhite: 0.0, alpha: 0.14).setStroke()
    let ringPath = NSBezierPath(ovalIn: ringRect)
    ringPath.lineWidth = max(4, size * 0.055)
    ringPath.stroke()

    let progressPath = NSBezierPath()
    progressPath.appendArc(
        withCenter: NSPoint(x: rect.midX, y: rect.midY),
        radius: (ringRect.width / 2),
        startAngle: 90,
        endAngle: -150,
        clockwise: true
    )
    NSColor.black.setStroke()
    progressPath.lineWidth = max(6, size * 0.07)
    progressPath.lineCapStyle = .round
    progressPath.stroke()

    let symbolConfig = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .bold)
    let symbol = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig)

    if let symbol {
        let symbolRect = NSRect(
            x: rect.midX - size * 0.18,
            y: rect.midY - size * 0.19,
            width: size * 0.36,
            height: size * 0.36
        )
        NSColor.black.set()
        symbol.draw(in: symbolRect)
    }

    image.unlockFocus()

    guard
        let tiffData = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiffData),
        let pngData = rep.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "SportWorkIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render icon PNG"])
    }

    try pngData.write(to: outputURL.appendingPathComponent(fileName), options: .atomic)
}
