import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("usage: make_icon.swift <output.icns>")
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

let chunks: [(type: String, pixels: Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024)
]

func pngData(pixels: Int) -> Data {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(
        roundedRect: rect.insetBy(dx: CGFloat(pixels) * 0.09, dy: CGFloat(pixels) * 0.09),
        xRadius: CGFloat(pixels) * 0.18,
        yRadius: CGFloat(pixels) * 0.18
    ).fill()

    NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.92, alpha: 1).setStroke()
    let lineWidth = max(2, CGFloat(pixels) * 0.055)
    let circle = NSBezierPath(ovalIn: rect.insetBy(dx: CGFloat(pixels) * 0.25, dy: CGFloat(pixels) * 0.25))
    circle.lineWidth = lineWidth
    circle.stroke()

    let needle = NSBezierPath()
    needle.lineCapStyle = .round
    needle.lineWidth = lineWidth
    needle.move(to: NSPoint(x: CGFloat(pixels) * 0.50, y: CGFloat(pixels) * 0.50))
    needle.line(to: NSPoint(x: CGFloat(pixels) * 0.68, y: CGFloat(pixels) * 0.63))
    needle.stroke()

    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(
        x: CGFloat(pixels) * 0.45,
        y: CGFloat(pixels) * 0.45,
        width: CGFloat(pixels) * 0.10,
        height: CGFloat(pixels) * 0.10
    )).fill()

    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("failed to render \(pixels)px icon")
    }
    return png
}

func appendFourCC(_ string: String, to data: inout Data) {
    data.append(contentsOf: string.utf8)
}

func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
        data.append(contentsOf: bytes)
    }
}

var chunkData = Data()
for chunk in chunks {
    let png = pngData(pixels: chunk.pixels)
    appendFourCC(chunk.type, to: &chunkData)
    appendUInt32BE(UInt32(png.count + 8), to: &chunkData)
    chunkData.append(png)
}

var icns = Data()
appendFourCC("icns", to: &icns)
appendUInt32BE(UInt32(chunkData.count + 8), to: &icns)
icns.append(chunkData)
try icns.write(to: outputURL)
