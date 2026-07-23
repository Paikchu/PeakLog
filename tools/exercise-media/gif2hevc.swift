import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// Converts an animated GIF to a looping HEVC .mov using ImageIO + AVAssetWriter.
// usage: swift gif2hevc.swift <in.gif> <out.mov> [quality 0..1]

func gifFrames(_ url: URL) -> (images: [CGImage], delays: [Double])? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let count = CGImageSourceGetCount(src)
    guard count > 0 else { return nil }
    var images: [CGImage] = []
    var delays: [Double] = []
    for i in 0..<count {
        guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
        images.append(img)
        var delay = 0.1
        if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
           let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let d = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, d > 0 {
                delay = d
            } else if let d = gif[kCGImagePropertyGIFDelayTime] as? Double, d > 0 {
                delay = d
            }
        }
        delays.append(max(delay, 0.02))
    }
    return (images, delays)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: gif2hevc <in.gif> <out.mov> [quality]\n".data(using: .utf8)!)
    exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let quality = args.count > 3 ? (Double(args[3]) ?? 0.6) : 0.6

try? FileManager.default.removeItem(at: outURL)

guard let (images, delays) = gifFrames(inURL), let first = images.first else {
    FileHandle.standardError.write("cannot read gif\n".data(using: .utf8)!)
    exit(1)
}

let width = first.width
let height = first.height

guard let writer = try? AVAssetWriter(outputURL: outURL, fileType: .mov) else {
    FileHandle.standardError.write("cannot create writer\n".data(using: .utf8)!)
    exit(1)
}

let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoQualityKey: quality,
        AVVideoMaxKeyFrameIntervalKey: images.count,
    ],
]

let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
input.expectsMediaDataInRealTime = false

let attrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
]
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)

writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let timescale: CMTimeScale = 600
var currentTime = CMTime.zero
let colorSpace = CGColorSpaceCreateDeviceRGB()

for (index, image) in images.enumerated() {
    while !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.005)
    }
    guard let pool = adaptor.pixelBufferPool else { break }
    var pxBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pxBuffer)
    guard let buffer = pxBuffer else { break }

    CVPixelBufferLockBaseAddress(buffer, [])
    if let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) {
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    adaptor.append(buffer, withPresentationTime: currentTime)

    // The source GIFs hold frame 0 for ~1s as a poster pause; normalize it to
    // the regular cadence so the loop reads as continuous motion.
    var delay = delays[index]
    if index == 0 && delay > 0.4 {
        delay = delays.count > 1 ? delays[1] : 0.1
    }
    currentTime = CMTimeAdd(currentTime, CMTime(seconds: delay, preferredTimescale: timescale))
}

input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()

if writer.status == .completed {
    let attributes = try? FileManager.default.attributesOfItem(atPath: outURL.path)
    let size = (attributes?[.size] as? Int) ?? 0
    print("ok frames=\(images.count) bytes=\(size)")
} else {
    FileHandle.standardError.write("failed: \(String(describing: writer.error))\n".data(using: .utf8)!)
    exit(1)
}
