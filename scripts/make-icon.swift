// Builds app/Resources/AppIcon.icns from app/Resources/AppIcon.png. Run through `make icon`.
//
// The artwork is a free-form shape on transparency. macOS 26+ shrinks such icons into a grey tile, so we place it on
// our own tile laid out on Apple's 1024 pt macOS icon grid.
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileCornerRadius: CGFloat = 185.4
let tileColor = CGColor(srgbRed: 247 / 255, green: 239 / 255, blue: 224 / 255, alpha: 1)
// Applies to the whole source canvas, which has transparent padding, so tune it by eye if the artwork changes.
let artworkSide: CGFloat = 790

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("can't read \(url.path)") }
    return image
}

// Drawn at each pixel size rather than downscaled from 1024, so the tile edge stays crisp at 16 px.
func render(_ artwork: CGImage, pixels: Int) -> CGImage {
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("can't create a \(pixels) px context") }
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)

    let tile = RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous).path(in: tileRect).cgPath
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
    context.addPath(tile)
    context.setFillColor(tileColor)
    context.fillPath()
    context.restoreGState()

    let inset = (canvas - artworkSide) / 2
    context.draw(artwork, in: CGRect(x: inset, y: inset, width: artworkSide, height: artworkSide))

    guard let image = context.makeImage() else { fail("can't render \(pixels) px") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("can't write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("can't write \(url.path)") }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: make-icon.swift <artwork.png> <output.icns>") }
let artwork = loadImage(URL(fileURLWithPath: arguments[1]))
let output = URL(fileURLWithPath: arguments[2])

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathComponent("AppIcon.iconset")
do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch { fail("can't create \(iconset.path): \(error)") }
defer { try? FileManager.default.removeItem(at: iconset.deletingLastPathComponent()) }

// The point sizes and names iconutil expects.
for points in [16, 32, 128, 256, 512] {
    writePNG(render(artwork, pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(artwork, pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
do { try iconutil.run() } catch { fail("can't run iconutil: \(error)") }
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }
print("Wrote \(output.path)")
