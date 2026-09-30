// Standalone reproduction for AVKit sample buffer Picture in Picture geometry
// on macOS. No WebRTC, no Float code. See docs/PUBLIC_PIP.md.
//
// Build and run:
//   swiftc -O docs/public-pip-probe.swift -o /tmp/public-pip-probe
//   /tmp/public-pip-probe                      # source layer 160x90
//   LW=696 LH=392 /tmp/public-pip-probe        # source layer 696x392
//
// Environment:
//   LW, LH   size of the source AVSampleBufferDisplayLayer in points (default 160x90)
//   HOST     transparent (alpha 0, default) | offscreen | visible
//
// The probe enqueues 1280x720 frames (solid colour, 24 px white border) at
// 30 fps, starts PiP after one second, prints the view/layer geometry AVKit
// builds inside the in-process PiP window, and stops after nine seconds.
// Expected: the frame, including its white border, fills the PiP window.

import AppKit
import AVFoundation
import AVKit
import CoreMedia

let environment = ProcessInfo.processInfo.environment
let sourceSize = NSSize(
    width: Double(environment["LW"] ?? "160") ?? 160,
    height: Double(environment["LH"] ?? "90") ?? 90
)
let hostMode = environment["HOST"] ?? "transparent"

final class PlaybackDelegate: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        print("did start")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("failed to start: \(error)")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        print("did stop")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        print("render size \(newRenderSize.width)x\(newRenderSize.height)")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        completion()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Source: an invisible borderless panel hosting the display layer.
let displayLayer = AVSampleBufferDisplayLayer()
let hostView = NSView(frame: NSRect(origin: .zero, size: sourceSize))
hostView.wantsLayer = true
displayLayer.frame = hostView.bounds
hostView.layer?.addSublayer(displayLayer)

let hostWindow = NSPanel(
    contentRect: hostView.frame,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
hostWindow.contentView = hostView
hostWindow.level = .floating
hostWindow.ignoresMouseEvents = true
hostWindow.backgroundColor = .clear
hostWindow.isOpaque = false
hostWindow.alphaValue = hostMode == "transparent" ? 0 : 1
let visibleFrame = NSScreen.main?.visibleFrame ?? .zero
hostWindow.setFrameOrigin(
    hostMode == "offscreen"
        ? NSPoint(x: -10_000, y: -10_000)
        : NSPoint(x: visibleFrame.maxX - sourceSize.width - 16, y: visibleFrame.minY + 16)
)
hostWindow.orderFrontRegardless()

// Frames: 1280x720 BGRA, solid colour with a white border, cycling hue.
var hue: CGFloat = 0

func enqueueFrame() {
    let width = 1280
    let height = 720
    let border = 24
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(
        nil,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &pixelBuffer
    )
    guard let pixelBuffer else { return }

    let color = NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1).usingColorSpace(.deviceRGB)!
    hue = (hue + 0.01).truncatingRemainder(dividingBy: 1)
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<height {
        for x in 0..<width {
            let pixel = base + y * bytesPerRow + x * 4
            let isBorder = x < border || y < border || x >= width - border || y >= height - border
            pixel[0] = isBorder ? 255 : UInt8(color.blueComponent * 255)
            pixel[1] = isBorder ? 255 : UInt8(color.greenComponent * 255)
            pixel[2] = isBorder ? 255 : UInt8(color.redComponent * 255)
            pixel[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    var formatDescription: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
    var timing = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription!,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    guard let sampleBuffer else { return }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)!
    let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(
        attachment,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
    )
    displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
}

func dumpView(_ view: NSView, depth: Int) {
    let indent = String(repeating: "  ", count: depth)
    let layerInfo = view.layer.map { "layerFrame=\($0.frame) scale=\($0.transform.m11)" } ?? ""
    print("\(indent)\(type(of: view)) frame=\(view.frame) \(layerInfo)")
    for subview in view.subviews {
        dumpView(subview, depth: depth + 1)
    }
}

let delegate = PlaybackDelegate()
let controller = AVPictureInPictureController(
    contentSource: .init(sampleBufferDisplayLayer: displayLayer, playbackDelegate: delegate)
)
controller.delegate = delegate

Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in enqueueFrame() }

// Start only once frames are queued: starting on an empty layer traps in
// -[NSView setFrame:] with a NaN frame inside AVKit's host view layout.
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    print("source layer \(Int(sourceSize.width))x\(Int(sourceSize.height)), possible=\(controller.isPictureInPicturePossible)")
    controller.startPictureInPicture()
}
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    for window in NSApp.windows where window !== hostWindow {
        print("\(type(of: window)) frame=\(window.frame)")
        if let contentView = window.contentView {
            dumpView(contentView, depth: 1)
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 9) { controller.stopPictureInPicture() }
DispatchQueue.main.asyncAfter(deadline: .now() + 10.5) { exit(0) }

app.run()
