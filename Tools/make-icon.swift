#!/usr/bin/env swift
//
// Renders `Assets/icon.svg` into a macOS `.icns`.
//
// Run:  swift Tools/make-icon.swift <icon.svg> <output.icns>
//       swift Tools/make-icon.swift <icon.svg> <output.iconset>   (a folder, for inspection)
//
// The artwork carries its own rounded-square silhouette and fills the canvas edge to edge, so
// nothing is drawn around it here. That matters on macOS 26, which composites a legacy `.icns`
// onto its own rounded tile: a transparent margin is not empty space there, it is the system's
// white tile showing through, framing the artwork in a border it was never meant to have. The
// artwork wants to *be* the tile, not sit inside one.
//
// `iconutil -c icns` is deliberately not used. It stopped working on this machine and rejects any
// iconset with "Invalid Iconset" — including one it had just produced itself from a known-good
// .icns, which is the proof it is the tool and not the data. The format is a header plus
// length-prefixed chunks, so the dependency is not worth keeping.

import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 else {
    fail("usage: make-icon.swift <icon.svg> <output.icns|output.iconset>")
}
let (sourcePath, output) = (args[0], args[1])

guard let artwork = NSImage(contentsOf: URL(fileURLWithPath: sourcePath)), artwork.isValid else {
    fail("could not read \(sourcePath)")
}

/// Draws the artwork into a square bitmap of exactly `pixels` on a side.
///
/// The SVG is vector, so every size is rendered from the source rather than downscaled from one
/// large raster — small sizes stay crisp instead of turning to mush.
func png(_ pixels: CGFloat) -> Data {
    let side = Int(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fail("could not allocate the \(side)px bitmap") }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                 from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fail("could not encode the \(side)px icon")
    }
    return data
}

func beUInt32(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

/// One chunk: 4-byte type, 4-byte length *including* those 8 bytes, then the PNG.
func icnsChunk(type: String, png: Data) -> Data {
    var chunk = Data(type.utf8)
    chunk.append(beUInt32(UInt32(png.count + 8)))
    chunk.append(png)
    return chunk
}

// The PNG-carrying chunk types modern macOS reads. 16pt entries are deliberately absent: macOS
// downscales from the 32px entry, and this matches the icns that was already shipping.
let icnsEntries: [(type: String, pixels: CGFloat)] = [
    ("ic11", 32),    // 16pt @2x
    ("ic12", 64),    // 32pt @2x
    ("ic07", 128),   // 128pt @1x
    ("ic13", 256),   // 128pt @2x
    ("ic08", 256),   // 256pt @1x
    ("ic14", 512),   // 256pt @2x
    ("ic09", 512),   // 512pt @1x
    ("ic10", 1024),  // 512pt @2x
]

let iconsetVariants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

// Rendering is the expensive half, so each pixel size is drawn once and reused by every chunk that
// wants it — 256 and 512 are each wanted twice.
var rendered: [CGFloat: Data] = [:]
func pngData(_ pixels: CGFloat) -> Data {
    if let cached = rendered[pixels] { return cached }
    let data = png(pixels)
    rendered[pixels] = data
    return data
}

if output.hasSuffix(".icns") {
    var body = Data()
    for entry in icnsEntries {
        body.append(icnsChunk(type: entry.type, png: pngData(entry.pixels)))
    }
    var file = Data("icns".utf8)
    file.append(beUInt32(UInt32(body.count + 8)))  // total length counts the 8-byte header
    file.append(body)

    let url = URL(fileURLWithPath: output)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    do {
        try file.write(to: url)
    } catch {
        fail("could not write \(output): \(error)")
    }
    print("wrote \(output) — \(icnsEntries.count) sizes, \(file.count / 1024) KB")
} else {
    let folder = URL(fileURLWithPath: output)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for variant in iconsetVariants {
        let url = folder.appendingPathComponent("\(variant.name).png")
        do {
            try pngData(variant.pixels).write(to: url)
        } catch {
            fail("could not write \(url.path): \(error)")
        }
    }
    print("wrote \(output) — \(iconsetVariants.count) variants")
}
