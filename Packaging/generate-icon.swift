// Renders AskMail's app icon: a dark graphite squircle with a centered,
// glowing accent hairline — the same mark used for the menu-bar status item
// and the question-bar hairline, scaled up into a full app icon.
//
// Usage: swift Packaging/generate-icon.swift <output.iconset dir>
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024

func makeIcon(size: CGFloat) -> CGImage {
    let scale = size / canvas
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: scale, y: scale)

    let rect = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    let cornerRadius: CGFloat = canvas * 0.2237 // macOS squircle approximation
    let squircle = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Background: near-black graphite gradient.
    let bgColors = [
        CGColor(red: 0.145, green: 0.145, blue: 0.165, alpha: 1),
        CGColor(red: 0.055, green: 0.055, blue: 0.067, alpha: 1),
    ] as CFArray
    let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0, 1])!
    ctx.drawLinearGradient(bgGradient,
                            start: CGPoint(x: 0, y: canvas),
                            end: CGPoint(x: 0, y: 0),
                            options: [])

    // Soft glass sheen near the top.
    let sheenColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.10),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray
    let sheenGradient = CGGradient(colorsSpace: colorSpace, colors: sheenColors, locations: [0, 1])!
    ctx.drawLinearGradient(sheenGradient,
                            start: CGPoint(x: 0, y: canvas),
                            end: CGPoint(x: 0, y: canvas * 0.45),
                            options: [])

    ctx.restoreGState()

    // Hairline edge, echoing the app's 1pt hairline motif at icon scale.
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
    ctx.setLineWidth(2)
    ctx.strokePath()

    // Centered glowing accent bar (the "hairline" mark, scaled up).
    let barWidth = canvas * 0.58
    let barHeight = canvas * 0.052
    let barRect = CGRect(x: (canvas - barWidth) / 2, y: (canvas - barHeight) / 2, width: barWidth, height: barHeight)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil)

    let accentColors = [
        CGColor(red: 0.36, green: 0.62, blue: 1.0, alpha: 1),
        CGColor(red: 0.66, green: 0.46, blue: 1.0, alpha: 1),
    ] as CFArray
    let accentGradient = CGGradient(colorsSpace: colorSpace, colors: accentColors, locations: [0, 1])!

    // Soft glow behind the bar.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: canvas * 0.05, color: CGColor(red: 0.5, green: 0.55, blue: 1.0, alpha: 0.55))
    ctx.addPath(barPath)
    ctx.setFillColor(CGColor(red: 0.5, green: 0.55, blue: 1.0, alpha: 0.35))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(barPath)
    ctx.clip()
    ctx.drawLinearGradient(accentGradient,
                            start: CGPoint(x: barRect.minX, y: 0),
                            end: CGPoint(x: barRect.maxX, y: 0),
                            options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("usage: generate-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [(name: String, points: CGFloat, scale: CGFloat)] = [
    ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
    ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
    ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
    ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
    ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2),
]

for entry in sizes {
    let px = entry.points * entry.scale
    let image = makeIcon(size: px)
    writePNG(image, to: outDir.appendingPathComponent("\(entry.name).png"))
}
print("Wrote \(sizes.count) images to \(outDir.path)")
