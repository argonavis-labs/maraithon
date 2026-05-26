#!/usr/bin/env swift
//
//  generate_icon.swift
//
//  Reproducible Maraithon app-icon generator.
//
//  WHAT: Renders a 1024x1024 master PNG for the Maraithon Mac app icon,
//        then emits every standard macOS app-icon-set size (16, 32, 64,
//        128, 256, 512, 1024 at 1x and 2x). All output lands in
//        Sources/Maraithon/Resources/Assets.xcassets/AppIcon.appiconset/.
//
//  INVARIANT: This script is the source of truth for the icon. The PNGs
//             are committed but must be re-derivable byte-for-byte from
//             this file. Edit the glyph here, then re-run.
//
//  Concept: a calm, Apple-native glyph — a stylized "M" with a single
//  arc curving across it (local <-> cloud sync). System blue on solid
//  white. No gradient, no shadow, no rim lighting. Full-bleed 1024
//  square; macOS applies the squircle.
//
//  Run:    swift scripts/generate_icon.swift
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Paths

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().standardizedFileURL
let appiconset = repoRoot
    .appendingPathComponent("Sources/Maraithon/Resources/Assets.xcassets/AppIcon.appiconset",
                            isDirectory: true)
let iconBundle = repoRoot
    .appendingPathComponent("docs/icon/AppIcon.icon.draft",
                            isDirectory: true)

try? fm.createDirectory(at: appiconset, withIntermediateDirectories: true)
try? fm.createDirectory(at: iconBundle, withIntermediateDirectories: true)

// MARK: - Colors

// Apple system blue — accentColor default on macOS.
// sRGB 0, 122, 255 (#007AFF).
let systemBlue = CGColor(srgbRed: 0.0, green: 122.0/255.0, blue: 1.0, alpha: 1.0)
let white = CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)

// MARK: - Glyph

/// Draw the Maraithon glyph into `ctx` at the given canvas size.
///
/// Coordinates are in canvas pixels. The 1024-square master is the
/// design space; every other size is rendered by re-running the same
/// drawing at the smaller canvas size so the stroke widths scale with
/// the canvas (no bitmap resampling).
func drawGlyph(in ctx: CGContext, size: CGFloat) {
    // White background — full bleed.
    ctx.setFillColor(white)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    // The design grid: think of the canvas as 1024 units; everything is
    // expressed as a fraction of `size` so it stays sharp at every
    // rendered resolution.
    let s = size

    // Inset: keep the glyph clear of the squircle edge so it reads at
    // 16pt. ~22% on each side leaves a generous breathing margin and
    // matches the visual weight of Mail / Reminders.
    let inset = s * 0.22
    let glyphRect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)

    // The composition has two stacked elements with clear separation:
    //   1. The connection arc — a high, gentle bridge with endpoint
    //      dots, reading as "sync".
    //   2. The "M" — the brand letter, sitting underneath the arc.
    //
    // Splitting the glyph rect into a top ~22% (arc) and a bottom
    // ~70% (M), with an 8% gutter between, gives a clean two-band
    // composition that reads as one shape.
    let mRect = CGRect(
        x: glyphRect.minX,
        y: glyphRect.minY,
        width: glyphRect.width,
        height: glyphRect.height * 0.70
    )
    let arcBandTop = glyphRect.maxY
    let arcBandBottom = mRect.maxY + glyphRect.height * 0.08

    // Stroke weight — sized off the M's height so it tracks visual
    // weight across all output sizes.
    let stroke = mRect.height * 0.20

    ctx.setStrokeColor(systemBlue)
    ctx.setFillColor(systemBlue)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // ---- M ----
    //
    // Four anchored segments, AppKit origin bottom-left:
    //
    //   p2 ___________ p4
    //   |    \  /\  /   |
    //   |     \/  \/    |
    //   p1    p3       p5
    //
    // The valley sits ~45% up from the baseline so the shape reads as
    // a balanced M, not a W.
    let left = mRect.minX
    let right = mRect.maxX
    let top = mRect.maxY
    let bottom = mRect.minY
    let midX = mRect.midX
    let valleyY = bottom + mRect.height * 0.30

    let mPath = CGMutablePath()
    mPath.move(to: CGPoint(x: left,  y: bottom))
    mPath.addLine(to: CGPoint(x: left,  y: top))
    mPath.addLine(to: CGPoint(x: midX,  y: valleyY))
    mPath.addLine(to: CGPoint(x: right, y: top))
    mPath.addLine(to: CGPoint(x: right, y: bottom))
    ctx.addPath(mPath)
    ctx.strokePath()

    // ---- Sync arc ----
    //
    // A single gentle curve across the band above the M. Reads as a
    // connection / handshake. We use the same stroke weight as the M
    // with round line caps — the caps themselves become the endpoint
    // anchors, so the whole glyph reads as one continuous weight.
    ctx.setLineWidth(stroke)

    let arcInset = stroke * 0.5  // keep the round caps inside the glyph rect
    let arcLeftX = glyphRect.minX + arcInset
    let arcRightX = glyphRect.maxX - arcInset
    // Bow the arc downward (toward the M) — control point sits at the
    // bottom of the band, anchors at the top. This gives a pronounced
    // smile shape that reads clearly even at 16px.
    let arcAnchorY = arcBandTop - stroke * 0.5
    let arcControlY = arcBandBottom - stroke * 0.5

    let arcPath = CGMutablePath()
    arcPath.move(to: CGPoint(x: arcLeftX, y: arcAnchorY))
    arcPath.addQuadCurve(
        to: CGPoint(x: arcRightX, y: arcAnchorY),
        control: CGPoint(x: midX, y: arcControlY)
    )
    ctx.addPath(arcPath)
    ctx.strokePath()
}

// MARK: - Renderer

/// Render the glyph into a PNG of `pixelSize` x `pixelSize`.
func renderPNG(pixelSize: Int, to url: URL) throws {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "icongen", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "CGContext init failed"])
    }

    // Crisper antialiasing at small sizes.
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    drawGlyph(in: ctx, size: CGFloat(pixelSize))

    guard let image = ctx.makeImage() else {
        throw NSError(domain: "icongen", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "makeImage failed"])
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icongen", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try data.write(to: url, options: .atomic)
}

// MARK: - Asset catalog manifest

/// Standard macOS app-icon-set sizes. Each entry produces one PNG.
struct IconEntry {
    let logicalSize: Int   // points
    let scale: Int         // 1 or 2
    var pixelSize: Int { logicalSize * scale }
    var filename: String { "icon_\(logicalSize)x\(logicalSize)@\(scale)x.png" }
    var manifestSize: String { "\(logicalSize)x\(logicalSize)" }
    var manifestScale: String { "\(scale)x" }
}

let entries: [IconEntry] = [
    IconEntry(logicalSize: 16,  scale: 1),
    IconEntry(logicalSize: 16,  scale: 2),
    IconEntry(logicalSize: 32,  scale: 1),
    IconEntry(logicalSize: 32,  scale: 2),
    IconEntry(logicalSize: 128, scale: 1),
    IconEntry(logicalSize: 128, scale: 2),
    IconEntry(logicalSize: 256, scale: 1),
    IconEntry(logicalSize: 256, scale: 2),
    IconEntry(logicalSize: 512, scale: 1),
    IconEntry(logicalSize: 512, scale: 2),
]

// MARK: - Generate

print("Generating Maraithon app icon…")
print("  target: \(appiconset.path)")

// 1024 master — used by AppIcon.icon and as the 512@2x output.
let master1024 = appiconset.appendingPathComponent("icon_1024.png")
try renderPNG(pixelSize: 1024, to: master1024)
print("  wrote icon_1024.png (1024x1024)")

// Per-entry PNGs.
for entry in entries {
    let url = appiconset.appendingPathComponent(entry.filename)
    try renderPNG(pixelSize: entry.pixelSize, to: url)
    print("  wrote \(entry.filename) (\(entry.pixelSize)x\(entry.pixelSize))")
}

// Asset-catalog manifests.
let appiconsetManifest: [String: Any] = [
    "images": entries.map { entry in
        [
            "size": entry.manifestSize,
            "idiom": "mac",
            "filename": entry.filename,
            "scale": entry.manifestScale
        ]
    },
    "info": ["version": 1, "author": "xcode"]
]
let appiconsetJSON = try JSONSerialization.data(
    withJSONObject: appiconsetManifest,
    options: [.prettyPrinted, .sortedKeys]
)
try appiconsetJSON.write(to: appiconset.appendingPathComponent("Contents.json"))
print("  wrote AppIcon.appiconset/Contents.json")

// Asset-catalog root.
let catalogRoot = appiconset.deletingLastPathComponent()
let catalogManifest: [String: Any] = [
    "info": ["version": 1, "author": "xcode"]
]
let catalogJSON = try JSONSerialization.data(
    withJSONObject: catalogManifest,
    options: [.prettyPrinted, .sortedKeys]
)
try catalogJSON.write(to: catalogRoot.appendingPathComponent("Contents.json"))
print("  wrote Assets.xcassets/Contents.json")

// MARK: - macOS 26 Tahoe Icon Composer bundle

// Scaffold per https://successfulsoftware.net/2025/09/26/updating-application-icons-for-macos-26-tahoe-and-liquid-glass/.
// A real .icon bundle is produced by Icon Composer.app; until we run that
// tool, ship a minimal manifest pointing at the same 1024 master.
let tahoeMaster = iconBundle.appendingPathComponent("icon_1024.png")
try renderPNG(pixelSize: 1024, to: tahoeMaster)

let tahoeManifest: [String: Any] = [
    "schemaVersion": 1,
    "platform": "macOS",
    "layers": [
        [
            "name": "Maraithon",
            "image": "icon_1024.png"
        ]
    ]
]
let tahoeJSON = try JSONSerialization.data(
    withJSONObject: tahoeManifest,
    options: [.prettyPrinted, .sortedKeys]
)
try tahoeJSON.write(to: iconBundle.appendingPathComponent("manifest.json"))
print("  wrote AppIcon.icon/{manifest.json,icon_1024.png}")

print("Done.")
