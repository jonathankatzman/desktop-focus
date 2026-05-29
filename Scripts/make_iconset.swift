import CoreGraphics
import Foundation
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("Usage: make_iconset.swift <source.png> <output.iconset>\n", stderr)
    exit(64)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("Could not read source image: \(sourceURL.path)\n", stderr)
    exit(66)
}

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let outputs: [(pixels: Int, filename: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for output in outputs {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: output.pixels,
            height: output.pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        fputs("Could not create bitmap context for \(output.filename)\n", stderr)
        exit(70)
    }

    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: output.pixels, height: output.pixels))
    context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: output.pixels, height: output.pixels))

    guard let scaledImage = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            outputURL.appendingPathComponent(output.filename) as CFURL,
            "public.png" as CFString,
            1,
            nil
          ) else {
        fputs("Could not encode \(output.filename)\n", stderr)
        exit(70)
    }

    CGImageDestinationAddImage(destination, scaledImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        fputs("Could not write \(output.filename)\n", stderr)
        exit(70)
    }
}
