import AppKit
import AVFoundation
import AVKit
import CoreMedia
import Foundation
import WebRTC

private final class NativePiPFrameRenderer: NSObject, RTCVideoRenderer {
    private weak var controller: NativePiPController?
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var cachedFormatKey: (width: Int, height: Int, pixelFormat: OSType)?
    private var cachedI420PixelBuffer: CVPixelBuffer?
    private var cachedI420PixelBufferKey: (width: Int, height: Int)?
    private var lastPresentationTime: CMTime = .invalid
    private var warnedUnsupportedBufferType = false
    private let renderQueue = DispatchQueue(label: "de.unsou.Float.NativePiPFrameRenderer")

    init(controller: NativePiPController) {
        self.controller = controller
    }

    func setSize(_ size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            self?.controller?.handleVideoRendererSizeChanged(size)
        }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }

        renderQueue.async { [weak self] in
            guard let self else { return }
            guard let renderPayload = self.renderPayload(from: frame) else { return }
            let pixelBuffer = renderPayload.pixelBuffer
            guard let sampleBuffer = self.sampleBuffer(from: pixelBuffer) else { return }

            DispatchQueue.main.async { [weak self] in
                self?.controller?.noteFrameRendered(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer),
                    pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
                    bufferKind: renderPayload.bufferKind
                )
                self?.controller?.enqueueSampleBuffer(sampleBuffer)
            }
        }
    }

    private struct RenderPayload {
        let pixelBuffer: CVPixelBuffer
        let bufferKind: String
    }

    private func renderPayload(from frame: RTCVideoFrame) -> RenderPayload? {
        if let cvBuffer = frame.buffer as? RTCCVPixelBuffer {
            return RenderPayload(pixelBuffer: cvBuffer.pixelBuffer, bufferKind: "cv")
        }

        let i420Buffer = frame.buffer.toI420()
        if let converted = i420PixelBuffer(from: i420Buffer) {
            return RenderPayload(pixelBuffer: converted, bufferKind: "i420")
        }

        if !warnedUnsupportedBufferType {
            warnedUnsupportedBufferType = true
            print("[Float PiP] unsupported frame buffer type=\(type(of: frame.buffer)); frame dropped")
        }
        return nil
    }

    private func i420PixelBuffer(from i420Buffer: any RTCI420BufferProtocol) -> CVPixelBuffer? {
        let width = Int(i420Buffer.width)
        let height = Int(i420Buffer.height)

        guard width > 0, height > 0 else { return nil }

        if cachedI420PixelBuffer == nil ||
            cachedI420PixelBufferKey?.width != width ||
            cachedI420PixelBufferKey?.height != height
        {
            var createdBuffer: CVPixelBuffer?
            let attributes: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_420YpCbCr8PlanarFullRange,
                attributes as CFDictionary,
                &createdBuffer
            )
            guard status == kCVReturnSuccess, let createdBuffer else {
                print("[Float PiP] failed to allocate I420 CVPixelBuffer status=\(status)")
                return nil
            }
            cachedI420PixelBuffer = createdBuffer
            cachedI420PixelBufferKey = (width: width, height: height)
        }

        guard let pixelBuffer = cachedI420PixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 3 else {
            return nil
        }

        guard let dstYBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let dstUBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1),
              let dstVBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 2)
        else {
            return nil
        }

        copyPlane(
            srcBase: i420Buffer.dataY,
            srcStride: Int(i420Buffer.strideY),
            dstBase: dstYBase,
            dstStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
            width: width,
            height: height
        )

        copyPlane(
            srcBase: i420Buffer.dataU,
            srcStride: Int(i420Buffer.strideU),
            dstBase: dstUBase,
            dstStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
            width: Int(i420Buffer.chromaWidth),
            height: Int(i420Buffer.chromaHeight)
        )

        copyPlane(
            srcBase: i420Buffer.dataV,
            srcStride: Int(i420Buffer.strideV),
            dstBase: dstVBase,
            dstStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 2),
            width: Int(i420Buffer.chromaWidth),
            height: Int(i420Buffer.chromaHeight)
        )

        return pixelBuffer
    }

    private func copyPlane(
        srcBase: UnsafePointer<UInt8>,
        srcStride: Int,
        dstBase: UnsafeMutableRawPointer,
        dstStride: Int,
        width: Int,
        height: Int
    ) {
        let dstBytes = dstBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let srcRow = srcBase.advanced(by: row * srcStride)
            let dstRow = dstBytes.advanced(by: row * dstStride)
            memcpy(dstRow, srcRow, width)
        }
    }

    private func sampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let formatKey = (width: width, height: height, pixelFormat: pixelFormat)

        if cachedFormatDescription == nil || cachedFormatKey?.width != width || cachedFormatKey?.height != height || cachedFormatKey?.pixelFormat != pixelFormat {
            var formatDescription: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            )
            guard status == noErr, let formatDescription else {
                print("[Float PiP] failed to create format description status=\(status)")
                return nil
            }
            cachedFormatDescription = formatDescription
            cachedFormatKey = formatKey
        }

        guard let cachedFormatDescription else {
            return nil
        }

        var presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
        if lastPresentationTime.isValid, CMTimeCompare(presentationTime, lastPresentationTime) <= 0 {
            presentationTime = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 600))
        }
        lastPresentationTime = presentationTime

        var sampleTiming = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: cachedFormatDescription,
            sampleTiming: &sampleTiming,
            sampleBufferOut: &sampleBuffer
        )
        if status != noErr {
            print("[Float PiP] failed to create sample buffer status=\(status)")
            return nil
        }
        if let sampleBuffer {
            markForImmediateDisplay(sampleBuffer)
        }
        return sampleBuffer
    }

    private func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) else {
            return
        }
        guard CFArrayGetCount(attachments) > 0 else { return }
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

@MainActor
final class NativePiPController: NSObject, PiPControlling {
    private enum Constants {
        static let defaultLayerSize = CGSize(width: 1280, height: 720)
        static let minLayerDimension: CGFloat = 1
        static let maxLayerDimension: CGFloat = 8192
        static let startRetryIntervalSeconds: TimeInterval = 0.25
        static let inlineHostSize = CGSize(width: 320, height: 180)
        static let inlineHostOrigin = CGPoint(x: -10_000, y: -10_000)
        static let fallbackPlaybackDurationSeconds: Double = 10 * 60 * 60
    }

    var onPictureInPictureClosed: (() -> Void)?
    var onPlaybackCommand: ((Bool) -> Void)?
    var onSeekCommand: ((Double) -> Void)?

    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    private let sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
    private let inlineHostView = NSView(frame: CGRect(origin: .zero, size: Constants.inlineHostSize))
    private var inlineHostWindow: NSWindow?
    private lazy var frameRenderer = NativePiPFrameRenderer(controller: self)
    private var pictureInPictureController: AVPictureInPictureController?
    private var playbackTimebase: CMTimebase?
    private var wantsStart = false
    private var startRetryTimer: Timer?
    private var startAttemptCount = 0
    private var isStoppingProgrammatically = false
    private var sourceVideoSize: CGSize = .zero
    private var renderedFrameCount: Int = 0
    private var hasRenderedFirstFrame = false

    private var playbackElapsedSeconds: Double = 0
    private var playbackAnchorDate: Date?
    private var playbackIsPlaying = true
    private var playbackDurationSeconds: Double = 0

    override init() {
        super.init()
        setupIfNeeded()
    }

    func setContentView(_ view: NSView) {
        _ = view
    }

    func requestStart() {
        wantsStart = true
        startStartRetryIfNeeded()
        if hasRenderedFirstFrame {
            attemptStart()
        } else {
            print("[Float PiP] start deferred waitingForFirstFrame=true")
        }
    }

    func stop() {
        wantsStart = false
        stopStartRetry()
        hasRenderedFirstFrame = false
        renderedFrameCount = 0
        guard let pictureInPictureController else { return }
        guard pictureInPictureController.isPictureInPictureActive else {
            sampleBufferDisplayLayer.flushAndRemoveImage()
            return
        }

        isStoppingProgrammatically = true
        pictureInPictureController.stopPictureInPicture()
        sampleBufferDisplayLayer.flushAndRemoveImage()
    }

    func updateExpectedVideoSize(_ size: CGSize) {
        guard let sanitizedSize = sanitizeLayerSize(size) else { return }
        sourceVideoSize = sanitizedSize
        print("[Float PiP] sourceVideoSize width=\(Int(sanitizedSize.width)) height=\(Int(sanitizedSize.height))")
    }

    func updatePlaybackState(_ isPlaying: Bool) {
        updatePlaybackClock(isPlaying: isPlaying)
        syncPlaybackTimebase()
        pictureInPictureController?.invalidatePlaybackState()
    }

    func updatePlaybackProgress(elapsedSeconds: Double?, durationSeconds: Double?) {
        if let elapsedSeconds, elapsedSeconds.isFinite, elapsedSeconds >= 0 {
            playbackElapsedSeconds = elapsedSeconds
            if playbackIsPlaying {
                playbackAnchorDate = Date()
            }
        }

        if let durationSeconds {
            if durationSeconds.isFinite, durationSeconds > 0 {
                playbackDurationSeconds = durationSeconds
            } else {
                playbackDurationSeconds = 0
            }
        }

        playbackElapsedSeconds = clampElapsedTime(playbackElapsedSeconds)
        syncPlaybackTimebase()
        pictureInPictureController?.invalidatePlaybackState()
    }

    func rtcVideoRenderer() -> RTCVideoRenderer {
        frameRenderer
    }

    fileprivate func handleVideoRendererSizeChanged(_ size: CGSize) {
        updateExpectedVideoSize(size)
    }

    fileprivate func enqueueSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if sampleBufferDisplayLayer.status == .failed {
            let message = sampleBufferDisplayLayer.error?.localizedDescription ?? "unknown"
            print("[Float PiP] displayLayer failed; flushing error=\(message)")
            sampleBufferDisplayLayer.flush()
        }

        sampleBufferDisplayLayer.enqueue(sampleBuffer)
        if sampleBufferDisplayLayer.status == .failed {
            let message = sampleBufferDisplayLayer.error?.localizedDescription ?? "unknown"
            print("[Float PiP] displayLayer failed after enqueue error=\(message)")
        }
        attemptStart()
    }

    fileprivate func noteFrameRendered(width: Int, height: Int, pixelFormat: OSType, bufferKind: String) {
        renderedFrameCount += 1
        if !hasRenderedFirstFrame {
            hasRenderedFirstFrame = true
            print("[Float PiP] first frame observed")
            if wantsStart {
                attemptStart()
            }
        }
        if renderedFrameCount == 1 || renderedFrameCount % 120 == 0 {
            print("[Float PiP] frame.rendered count=\(renderedFrameCount) size=\(width)x\(height) pixelFormat=\(fourCC(pixelFormat)) buffer=\(bufferKind) layerStatus=\(sampleBufferDisplayLayer.status.rawValue)")
        }
    }

    private func setupIfNeeded() {
        guard Self.isSupported else {
            print("[Float PiP] PiP is not supported on this system")
            return
        }

        ensureInlineHostWindow()

        sampleBufferDisplayLayer.videoGravity = .resizeAspect
        sampleBufferDisplayLayer.backgroundColor = NSColor.black.cgColor
        applyLayerGeometry(Constants.defaultLayerSize)
        configurePlaybackTimebase()

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferDisplayLayer,
            playbackDelegate: self
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.requiresLinearPlayback = false
        pictureInPictureController = controller
    }

    private func ensureInlineHostWindow() {
        if inlineHostWindow == nil {
            let frame = CGRect(origin: Constants.inlineHostOrigin, size: Constants.inlineHostSize)
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.contentView = inlineHostView
            window.orderFrontRegardless()
            inlineHostWindow = window
            print("[Float PiP] inline host window prepared")
        }

        inlineHostView.wantsLayer = true
        if let hostLayer = inlineHostView.layer, sampleBufferDisplayLayer.superlayer !== hostLayer {
            sampleBufferDisplayLayer.removeFromSuperlayer()
            hostLayer.addSublayer(sampleBufferDisplayLayer)
            sampleBufferDisplayLayer.frame = hostLayer.bounds
            sampleBufferDisplayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            print("[Float PiP] sample layer attached to inline host")
        }
    }

    private func attemptStart() {
        guard wantsStart else { return }
        guard hasRenderedFirstFrame else { return }
        guard let pictureInPictureController else { return }
        guard !pictureInPictureController.isPictureInPictureActive else {
            stopStartRetry()
            return
        }
        guard pictureInPictureController.isPictureInPicturePossible else {
            if startAttemptCount == 0 || startAttemptCount % 20 == 0 {
                print("[Float PiP] start deferred possible=\(pictureInPictureController.isPictureInPicturePossible)")
            }
            startAttemptCount += 1
            return
        }

        startAttemptCount = 0
        print("[Float PiP] start requested")
        pictureInPictureController.startPictureInPicture()
    }

    private func startStartRetryIfNeeded() {
        guard startRetryTimer == nil else { return }
        startRetryTimer = Timer.scheduledTimer(withTimeInterval: Constants.startRetryIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.wantsStart else {
                    self.stopStartRetry()
                    return
                }
                guard self.hasRenderedFirstFrame else { return }
                self.attemptStart()
            }
        }
    }

    private func stopStartRetry() {
        startRetryTimer?.invalidate()
        startRetryTimer = nil
    }

    private func applyLayerGeometry(_ size: CGSize) {
        guard let resolvedSize = sanitizeLayerSize(size) else { return }
        let currentSize = sampleBufferDisplayLayer.bounds.size
        if abs(currentSize.width - resolvedSize.width) < 0.5 && abs(currentSize.height - resolvedSize.height) < 0.5 {
            return
        }

        sampleBufferDisplayLayer.bounds = CGRect(origin: .zero, size: resolvedSize)
        sampleBufferDisplayLayer.position = CGPoint(x: resolvedSize.width * 0.5, y: resolvedSize.height * 0.5)
    }

    private func sanitizeLayerSize(_ size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite else { return nil }
        guard size.width > 0, size.height > 0 else { return nil }

        let sanitizedWidth = min(Constants.maxLayerDimension, max(Constants.minLayerDimension, size.width))
        let sanitizedHeight = min(Constants.maxLayerDimension, max(Constants.minLayerDimension, size.height))
        return CGSize(width: sanitizedWidth, height: sanitizedHeight)
    }

    private func updatePlaybackClock(isPlaying: Bool) {
        let now = Date()
        if playbackIsPlaying, let anchor = playbackAnchorDate {
            playbackElapsedSeconds += now.timeIntervalSince(anchor)
        }
        playbackElapsedSeconds = max(0, playbackElapsedSeconds)
        playbackIsPlaying = isPlaying
        playbackAnchorDate = isPlaying ? now : nil
    }

    private func currentPlaybackElapsedSeconds() -> Double {
        if playbackIsPlaying, let anchor = playbackAnchorDate {
            return max(0, playbackElapsedSeconds + Date().timeIntervalSince(anchor))
        }
        return max(0, playbackElapsedSeconds)
    }

    private func clampElapsedTime(_ elapsed: Double) -> Double {
        let lowerBounded = max(0, elapsed)
        if playbackDurationSeconds.isFinite, playbackDurationSeconds > 0 {
            return min(playbackDurationSeconds, lowerBounded)
        }
        return lowerBounded
    }

    private func configurePlaybackTimebase() {
        var createdTimebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &createdTimebase
        )
        guard status == noErr, let createdTimebase else {
            playbackTimebase = nil
            sampleBufferDisplayLayer.controlTimebase = nil
            print("[Float PiP] failed to create playback timebase status=\(status)")
            return
        }

        playbackTimebase = createdTimebase
        sampleBufferDisplayLayer.controlTimebase = createdTimebase
        syncPlaybackTimebase()
    }

    private func syncPlaybackTimebase() {
        guard let playbackTimebase else { return }
        let elapsedSeconds = clampElapsedTime(currentPlaybackElapsedSeconds())
        CMTimebaseSetTime(
            playbackTimebase,
            time: CMTime(seconds: elapsedSeconds, preferredTimescale: 600)
        )
        CMTimebaseSetRate(playbackTimebase, rate: playbackIsPlaying ? 1.0 : 0.0)
    }

    private func resolvedFinitePlaybackDuration() -> Double {
        if playbackDurationSeconds.isFinite, playbackDurationSeconds > 0 {
            return playbackDurationSeconds
        }
        let elapsed = currentPlaybackElapsedSeconds()
        if elapsed.isFinite, elapsed > 0 {
            return max(elapsed + 3600, 3600)
        }
        return Constants.fallbackPlaybackDurationSeconds
    }

    private func fourCC(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        let text = String(bytes: bytes, encoding: .ascii) ?? "????"
        return "\(text)(\(value))"
    }
}

extension NativePiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        _ = pictureInPictureController
        stopStartRetry()
        startAttemptCount = 0
        print("[Float PiP] didStart")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        _ = pictureInPictureController
        print("[Float PiP] failedToStart error=\(error.localizedDescription)")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        _ = pictureInPictureController
        print("[Float PiP] didStop")
        stopStartRetry()
        startAttemptCount = 0

        if isStoppingProgrammatically {
            isStoppingProgrammatically = false
            return
        }
        onPictureInPictureClosed?()
    }
}

extension NativePiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        _ = pictureInPictureController
        updatePlaybackState(playing)
        onPlaybackCommand?(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        _ = pictureInPictureController
        let durationSeconds = resolvedFinitePlaybackDuration()
        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 600)
        )
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        _ = pictureInPictureController
        return !playbackIsPlaying
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        _ = pictureInPictureController
        let width = max(0, Int(newRenderSize.width))
        let height = max(0, Int(newRenderSize.height))
        print("[Float PiP] renderSize width=\(width) height=\(height)")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        _ = pictureInPictureController
        defer { completionHandler() }

        let intervalSeconds = skipInterval.seconds
        guard intervalSeconds.isFinite else { return }

        print("[Float PiP] seek intervalSeconds=\(intervalSeconds)")
        playbackElapsedSeconds = clampElapsedTime(currentPlaybackElapsedSeconds() + intervalSeconds)
        playbackAnchorDate = playbackIsPlaying ? Date() : nil
        syncPlaybackTimebase()
        pictureInPictureController.invalidatePlaybackState()
        onSeekCommand?(intervalSeconds)
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        _ = pictureInPictureController
        return false
    }
}
