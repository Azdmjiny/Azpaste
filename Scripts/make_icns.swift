import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconEntry {
    let type: String
    let size: Int
}

let entries: [IconEntry] = [
    IconEntry(type: "icp4", size: 16),
    IconEntry(type: "icp5", size: 32),
    IconEntry(type: "icp6", size: 64),
    IconEntry(type: "ic07", size: 128),
    IconEntry(type: "ic08", size: 256),
    IconEntry(type: "ic09", size: 512),
    IconEntry(type: "ic10", size: 1024),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("Usage: swift Scripts/make_icns.swift <source-png> <output-icns>")
}

let sourcePath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

guard let image = NSImage(contentsOfFile: sourcePath) else {
    fail("Unable to read icon source: \(sourcePath)")
}

var proposedRect = NSRect(origin: .zero, size: image.size)
guard let sourceImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
    fail("Unable to decode icon source: \(sourcePath)")
}

func writeUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndianValue = value.bigEndian
    withUnsafeBytes(of: &bigEndianValue) { bytes in
        data.append(contentsOf: bytes)
    }
}

func pngData(for size: Int) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        fail("Unable to create icon bitmap context for \(size)x\(size)")
    }

    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.interpolationQuality = .high

    let sourceWidth = CGFloat(sourceImage.width)
    let sourceHeight = CGFloat(sourceImage.height)
    let targetSize = CGFloat(size)
    let scale = min(targetSize / sourceWidth, targetSize / sourceHeight)
    let drawWidth = sourceWidth * scale
    let drawHeight = sourceHeight * scale
    let drawRect = CGRect(
        x: (targetSize - drawWidth) / 2,
        y: (targetSize - drawHeight) / 2,
        width: drawWidth,
        height: drawHeight
    )

    context.draw(sourceImage, in: drawRect)

    guard let scaledImage = context.makeImage() else {
        fail("Unable to render icon bitmap for \(size)x\(size)")
    }

    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        fail("Unable to create PNG destination for \(size)x\(size)")
    }

    CGImageDestinationAddImage(destination, scaledImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("Unable to encode PNG for \(size)x\(size)")
    }

    return data as Data
}

var iconData = Data()
iconData.append(Data("icns".utf8))
writeUInt32(0, to: &iconData)

for entry in entries {
    let imageData = pngData(for: entry.size)
    iconData.append(Data(entry.type.utf8))
    writeUInt32(UInt32(imageData.count + 8), to: &iconData)
    iconData.append(imageData)
}

let totalLength = UInt32(iconData.count).bigEndian
withUnsafeBytes(of: totalLength) { bytes in
    iconData.replaceSubrange(4..<8, with: bytes)
}

do {
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: outputPath).deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try iconData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
} catch {
    fail("Unable to write icon file: \(error.localizedDescription)")
}
