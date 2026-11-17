import AppKit

// Renders the logo into a macOS .iconset: the 824 pt body centred on a 1024 pt canvas with the
// standard drop shadow, at every size iconutil expects.
//
//   swift scripts/make-icon.swift docs/assets/logo.svg AppIcon.iconset

let arguments = CommandLine.arguments
guard arguments.count == 3, let logo = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift LOGO.svg OUTPUT.iconset\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: arguments[2])

func render(pixels: Int) -> Data? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let scale = CGFloat(pixels) / 1024
    context.interpolationQuality = .high
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 10 * scale,
                      color: CGColor(gray: 0, alpha: 0.3))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    logo.draw(in: NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale),
              from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    return context.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
}

do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            guard let png = render(pixels: points * factor) else {
                FileHandle.standardError.write(Data("could not render \(points)x\(points)@\(factor)x\n".utf8))
                exit(1)
            }
            let name = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
            try png.write(to: output.appendingPathComponent(name))
        }
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
