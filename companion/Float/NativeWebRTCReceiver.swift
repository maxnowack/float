#if canImport(WebRTC)
import AVFoundation
import AVKit
import Darwin
import Foundation
import QuartzCore
import WebRTC

private let pipDebugLoggingEnabled = true

final class NativeWebRTCReceiver: NSObject, WebRTCReceiver {
    var onLocalIceCandidate: ((LocalIceCandidate) -> Void)?
    var onStreamingChanged: ((Bool) -> Void)?

    private let peerFactory = RTCPeerConnectionFactory()
    private var peerConnection: RTCPeerConnection?
    private var currentTabId: Int?
    private var currentVideoId: String?
    private var currentVideoTrack: RTCVideoTrack?
    private var currentAudioTrack: RTCAudioTrack?
    private let pipController = NativePiPController()
    private let sampleBufferRenderer = WebRTCSampleBufferRenderer()
    private let sampleDeliveryLock = NSLock()
    private var pendingSampleBuffer: CMSampleBuffer?
    private var sampleDeliveryScheduled = false

    override init() {
        super.init()
        pipController.onPictureInPictureClosed = { [weak self] in
            guard let self else { return }
            if pipDebugLoggingEnabled {
                print("[Float PiP] receiver.pip-closed externally=true action=stop")
            }
            self.stop()
        }
        sampleBufferRenderer.onVideoSizeChanged = { [weak self] size in
            Task { @MainActor [weak self] in
                self?.pipController.updateExpectedVideoSize(size)
            }
        }
    }

    func handleOffer(_ offer: OfferMessage) async throws -> String {
        let connection = try getOrCreatePeerConnection()
        currentTabId = offer.tabId
        currentVideoId = offer.videoId

        let remote = RTCSessionDescription(type: .offer, sdp: offer.sdp)
        try await setRemoteDescription(remote, on: connection)
        let answer = try await createAnswer(on: connection)
        try await setLocalDescription(answer, on: connection)
        return answer.sdp
    }

    func addRemoteIceCandidate(_ ice: IceMessage) async throws {
        guard let connection = peerConnection else {
            throw WebRTCReceiverError.missingPeerConnection
        }

        let candidate = RTCIceCandidate(
            sdp: ice.candidate,
            sdpMLineIndex: Int32(ice.sdpMLineIndex ?? 0),
            sdpMid: ice.sdpMid
        )
        try await connection.add(candidate)
    }

    func stop() {
        if let track = currentVideoTrack {
            track.remove(sampleBufferRenderer)
        }
        currentVideoTrack = nil
        currentAudioTrack = nil
        sampleBufferRenderer.resetTiming()
        sampleBufferRenderer.onSampleBuffer = nil
        sampleBufferRenderer.shouldSkipFrameBeforeConversion = nil
        onStreamingChanged?(false)
        sampleDeliveryLock.lock()
        pendingSampleBuffer = nil
        sampleDeliveryScheduled = false
        sampleDeliveryLock.unlock()
        Task { @MainActor in
            self.pipController.stop()
        }
        peerConnection?.close()
        peerConnection = nil
        currentTabId = nil
        currentVideoId = nil
    }

    private func getOrCreatePeerConnection() throws -> RTCPeerConnection {
        if let existing = peerConnection {
            return existing
        }

        let config = RTCConfiguration()
        config.iceServers = []
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = peerFactory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw WebRTCReceiverError.peerConnectionUnavailable
        }

        peerConnection = connection
        return connection
    }

    private func setRemoteDescription(_ description: RTCSessionDescription, on connection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func createAnswer(on connection: RTCPeerConnection) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: [
                    "OfferToReceiveAudio": "true",
                    "OfferToReceiveVideo": "true",
                ],
                optionalConstraints: nil
            )
            connection.answer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let description else {
                    continuation.resume(throwing: WebRTCReceiverError.peerConnectionUnavailable)
                    return
                }

                continuation.resume(returning: description)
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription, on connection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

extension NativeWebRTCReceiver: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let tabId = currentTabId, let videoId = currentVideoId else { return }
        onLocalIceCandidate?(
            LocalIceCandidate(
                tabId: tabId,
                videoId: videoId,
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: Int(candidate.sdpMLineIndex)
            )
        )
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        if let track = transceiver.receiver.track as? RTCVideoTrack {
            attachVideoTrack(track)
        } else if let track = transceiver.receiver.track as? RTCAudioTrack {
            attachAudioTrack(track)
        }
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams: [RTCMediaStream]
    ) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            attachVideoTrack(track)
        } else if let track = rtpReceiver.track as? RTCAudioTrack {
            attachAudioTrack(track)
        }
    }
}

private extension NativeWebRTCReceiver {
    func attachVideoTrack(_ track: RTCVideoTrack) {
        if let previous = currentVideoTrack, previous.trackId == track.trackId {
            return
        }
        if let previous = currentVideoTrack {
            previous.remove(sampleBufferRenderer)
        }
        sampleBufferRenderer.resetTiming()
        if pipDebugLoggingEnabled {
            let videoID = currentVideoId ?? "unknown-video"
            sampleBufferRenderer.streamLabel = "\(videoID):\(track.trackId)"
        }
        sampleBufferRenderer.shouldSkipFrameBeforeConversion = { [weak self] in
            self?.hasPendingSampleBuffer() ?? false
        }
        sampleBufferRenderer.onSampleBuffer = { [weak self] sampleBuffer in
            self?.scheduleSampleBufferDelivery(sampleBuffer)
        }
        currentVideoTrack = track
        track.add(sampleBufferRenderer)
        onStreamingChanged?(true)
        Task { @MainActor in
            self.pipController.requestStart()
        }
    }

    func attachAudioTrack(_ track: RTCAudioTrack) {
        currentAudioTrack = track
        track.isEnabled = true
        if pipDebugLoggingEnabled {
            let videoID = currentVideoId ?? "unknown-video"
            print("[Float PiP] receiver.audio-attached video=\(videoID) track=\(track.trackId)")
        }
    }

    func scheduleSampleBufferDelivery(_ sampleBuffer: CMSampleBuffer) {
        sampleDeliveryLock.lock()
        pendingSampleBuffer = sampleBuffer
        if sampleDeliveryScheduled {
            sampleDeliveryLock.unlock()
            return
        }
        sampleDeliveryScheduled = true
        sampleDeliveryLock.unlock()

        Task { @MainActor [weak self] in
            self?.drainPendingSampleBuffers()
        }
    }

    @MainActor
    func drainPendingSampleBuffers() {
        while true {
            guard let sampleBuffer = popPendingSampleBuffer() else {
                sampleDeliveryLock.lock()
                if pendingSampleBuffer == nil {
                    sampleDeliveryScheduled = false
                    sampleDeliveryLock.unlock()
                    return
                }
                sampleDeliveryLock.unlock()
                continue
            }
            pipController.enqueue(sampleBuffer: sampleBuffer)
        }
    }

    func popPendingSampleBuffer() -> CMSampleBuffer? {
        sampleDeliveryLock.lock()
        let sampleBuffer = pendingSampleBuffer
        pendingSampleBuffer = nil
        sampleDeliveryLock.unlock()
        return sampleBuffer
    }

    func hasPendingSampleBuffer() -> Bool {
        sampleDeliveryLock.lock()
        let hasPending = pendingSampleBuffer != nil
        sampleDeliveryLock.unlock()
        return hasPending
    }
}

private final class WebRTCSampleBufferRenderer: NSObject, RTCVideoRenderer {
    private typealias PixelBufferResult = (buffer: CVPixelBuffer, usedCropScale: Bool)
    private static let videoTimestampTimescale: Int32 = 1_000_000_000
    private static let minimumFrameStep = CMTime(value: 1, timescale: 240)
    private static let videoPlayoutDelay = CMTime(value: 120, timescale: 1_000) // 120ms

    private struct FormatKey: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
    }

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onVideoSizeChanged: ((CGSize) -> Void)?
    var shouldSkipFrameBeforeConversion: (() -> Bool)?
    var streamLabel: String = "stream"
    private var lastPresentationTime = CMTime.invalid
    private var firstFrameTimestampNs: Int64?
    private var firstFramePresentationTime = CMTime.invalid
    private var renderedFrameCount: Int = 0
    private var droppedFrameCount: Int = 0
    private let formatCacheLock = NSLock()
    private var cachedFormatKey: FormatKey?
    private var cachedFormatDescription: CMVideoFormatDescription?

    func setSize(_ size: CGSize) {
        if size.width > 0, size.height > 0 {
            onVideoSizeChanged?(size)
        }
        guard pipDebugLoggingEnabled else { return }
        print("[Float PiP] renderer.setSize stream=\(streamLabel) size=\(Int(size.width))x\(Int(size.height))")
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        renderedFrameCount += 1

        if shouldSkipFrameBeforeConversion?() == true {
            droppedFrameCount += 1
            if pipDebugLoggingEnabled, droppedFrameCount % 120 == 0 {
                print("[Float PiP] renderer.drop stream=\(streamLabel) reason=backpressure-preconvert frame=\(renderedFrameCount)")
            }
            return
        }

        let target = Self.targetSize(for: frame)
        guard let pixelBufferResult = makePixelBuffer(from: frame, targetWidth: target.width, targetHeight: target.height) else {
            droppedFrameCount += 1
            if pipDebugLoggingEnabled, droppedFrameCount % 30 == 0 {
                print("[Float PiP] renderer.drop stream=\(streamLabel) reason=pixel-buffer-conversion frame=\(renderedFrameCount)")
            }
            return
        }
        let pixelBuffer = pixelBufferResult.buffer
        guard let sampleBuffer = makeSampleBuffer(from: pixelBuffer, presentationTime: presentationTime(for: frame)) else {
            droppedFrameCount += 1
            if pipDebugLoggingEnabled, droppedFrameCount % 30 == 0 {
                print("[Float PiP] renderer.drop stream=\(streamLabel) reason=sample-buffer-create frame=\(renderedFrameCount)")
            }
            return
        }
        if pipDebugLoggingEnabled, renderedFrameCount % 60 == 0 {
            let outWidth = CVPixelBufferGetWidth(pixelBuffer)
            let outHeight = CVPixelBufferGetHeight(pixelBuffer)
            let probe = Self.probeSummary(for: pixelBuffer)
            let path = pixelBufferResult.usedCropScale ? "crop-scale" : "direct"
            print("[Float PiP] renderer.frame stream=\(streamLabel) frame=\(renderedFrameCount) output=\(outWidth)x\(outHeight) path=\(path) drops=\(droppedFrameCount) probe={\(probe)}")
        }
        onSampleBuffer?(sampleBuffer)
    }

    private func makePixelBuffer(from frame: RTCVideoFrame, targetWidth: Int, targetHeight: Int) -> PixelBufferResult? {
        let sourceBuffer = frame.buffer

        if let cvBuffer = sourceBuffer as? RTCCVPixelBuffer {
            let sourcePixelBuffer = cvBuffer.pixelBuffer
            let width = CVPixelBufferGetWidth(sourcePixelBuffer)
            let height = CVPixelBufferGetHeight(sourcePixelBuffer)
            guard width > 0, height > 0 else {
                return nil
            }

            let cropX = max(0, Int(cvBuffer.cropX))
            let cropY = max(0, Int(cvBuffer.cropY))
            let cropWidth = min(max(1, Int(cvBuffer.cropWidth)), width)
            let cropHeight = min(max(1, Int(cvBuffer.cropHeight)), height)

            if pipDebugLoggingEnabled, renderedFrameCount % 60 == 0 {
                print(
                    "[Float PiP] renderer.input stream=\(streamLabel) frame=\(renderedFrameCount) raw=\(width)x\(height) " +
                    "frame=\(Int(frame.width))x\(Int(frame.height)) rot=\(frame.rotation.rawValue) " +
                    "crop=(x:\(cropX),y:\(cropY),w:\(cropWidth),h:\(cropHeight)) target=\(targetWidth)x\(targetHeight)"
                )
            }

            if cropX == 0, cropY == 0, cropWidth == width, cropHeight == height, width == targetWidth, height == targetHeight {
                if let copied = Self.copyPixelBuffer(sourcePixelBuffer) {
                    return (buffer: copied, usedCropScale: false)
                }
                return (buffer: sourcePixelBuffer, usedCropScale: false)
            }

            guard let outputBuffer = Self.makePixelBuffer(
                width: targetWidth,
                height: targetHeight,
                pixelFormat: CVPixelBufferGetPixelFormatType(sourcePixelBuffer)
            ) else {
                return (buffer: sourcePixelBuffer, usedCropScale: false)
            }

            let tempSize = Int(cvBuffer.bufferSizeForCroppingAndScaling(toWidth: Int32(targetWidth), height: Int32(targetHeight)))
            var tempData = tempSize > 0 ? Data(count: tempSize) : Data()
            let didCrop = tempData.withUnsafeMutableBytes { bytes -> Bool in
                let tempBuffer = tempSize > 0 ? bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) : nil
                return cvBuffer.cropAndScale(to: outputBuffer, withTempBuffer: tempBuffer)
            }
            if pipDebugLoggingEnabled, renderedFrameCount % 60 == 0 {
                let sourceProbe = Self.probeSummary(for: sourcePixelBuffer)
                let outputProbe = Self.probeSummary(for: didCrop ? outputBuffer : sourcePixelBuffer)
                print(
                    "[Float PiP] renderer.crop-scale stream=\(streamLabel) frame=\(renderedFrameCount) didCrop=\(didCrop) tempBytes=\(tempSize) " +
                    "sourceProbe={\(sourceProbe)} outputProbe={\(outputProbe)}"
                )
            }
            return (buffer: didCrop ? outputBuffer : sourcePixelBuffer, usedCropScale: didCrop)
        }
        return nil
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        guard let formatDescription = formatDescription(for: pixelBuffer) else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr else {
            return nil
        }

        // Use normal presentation timestamps for PiP compositing.
        // DisplayImmediately can cause stale overlay/compositor artifacts on some systems.

        return sampleBuffer
    }

    private func formatDescription(for pixelBuffer: CVPixelBuffer) -> CMVideoFormatDescription? {
        let key = FormatKey(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )

        formatCacheLock.lock()
        if let cachedFormatDescription, let cachedFormatKey, cachedFormatKey == key {
            formatCacheLock.unlock()
            return cachedFormatDescription
        }
        formatCacheLock.unlock()

        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { return nil }

        formatCacheLock.lock()
        cachedFormatKey = key
        cachedFormatDescription = formatDescription
        formatCacheLock.unlock()
        return formatDescription
    }

    func resetTiming() {
        lastPresentationTime = .invalid
        firstFrameTimestampNs = nil
        firstFramePresentationTime = .invalid
    }

    private func presentationTime(for frame: RTCVideoFrame) -> CMTime {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let frameTimestampNs = frame.timeStampNs

        guard frameTimestampNs > 0 else {
            return monotonicPresentationTime(from: now)
        }

        if firstFrameTimestampNs == nil || !firstFramePresentationTime.isValid {
            firstFrameTimestampNs = frameTimestampNs
            firstFramePresentationTime = CMTimeAdd(now, Self.videoPlayoutDelay)
        }

        guard let firstFrameTimestampNs else {
            return monotonicPresentationTime(from: now)
        }

        let frameDeltaNs = max(Int64(0), frameTimestampNs - firstFrameTimestampNs)
        let delta = CMTime(value: frameDeltaNs, timescale: Self.videoTimestampTimescale)
        let mapped = CMTimeAdd(firstFramePresentationTime, delta)
        return monotonicPresentationTime(from: mapped)
    }

    private func monotonicPresentationTime(from candidate: CMTime) -> CMTime {
        var presentationTime = candidate
        if !lastPresentationTime.isValid {
            lastPresentationTime = presentationTime
            return presentationTime
        }

        if presentationTime <= lastPresentationTime {
            presentationTime = CMTimeAdd(lastPresentationTime, Self.minimumFrameStep)
        }

        lastPresentationTime = presentationTime
        return presentationTime
    }

    private static func makePixelBuffer(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess else {
            return nil
        }
        return pixelBuffer
    }

    private static func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        guard let destination = makePixelBuffer(width: width, height: height, pixelFormat: format) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        if CVPixelBufferIsPlanar(source) {
            let planeCount = CVPixelBufferGetPlaneCount(source)
            for plane in 0..<planeCount {
                guard
                    let srcBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                    let dstBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
                else {
                    continue
                }
                let srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                let rows = CVPixelBufferGetHeightOfPlane(source, plane)
                let bytesToCopyPerRow = min(srcBytesPerRow, dstBytesPerRow)
                for row in 0..<rows {
                    let srcRow = srcBase.advanced(by: row * srcBytesPerRow)
                    let dstRow = dstBase.advanced(by: row * dstBytesPerRow)
                    memcpy(dstRow, srcRow, bytesToCopyPerRow)
                }
            }
            return destination
        }

        guard
            let srcBase = CVPixelBufferGetBaseAddress(source),
            let dstBase = CVPixelBufferGetBaseAddress(destination)
        else {
            return destination
        }
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
        let rows = CVPixelBufferGetHeight(source)
        let bytesToCopyPerRow = min(srcBytesPerRow, dstBytesPerRow)
        for row in 0..<rows {
            let srcRow = srcBase.advanced(by: row * srcBytesPerRow)
            let dstRow = dstBase.advanced(by: row * dstBytesPerRow)
            memcpy(dstRow, srcRow, bytesToCopyPerRow)
        }
        return destination
    }

    private static func targetSize(for frame: RTCVideoFrame) -> (width: Int, height: Int) {
        // Keep native frame resolution and let AVSampleBufferDisplayLayer handle presentation scaling.
        // Software frame scaling here can introduce visible artifacts in PiP (e.g., black blocks).
        let rawWidth = max(1, Int(frame.width))
        let rawHeight = max(1, Int(frame.height))
        switch frame.rotation {
        case ._90, ._270:
            return (rawHeight, rawWidth)
        case ._0, ._180:
            return (rawWidth, rawHeight)
        @unknown default:
            return (rawWidth, rawHeight)
        }
    }

    private static func probeSummary(for pixelBuffer: CVPixelBuffer) -> String {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard let samples = sampleLumaTriplet(from: pixelBuffer) else {
            return "fmt=\(fourCCString(format)) sample=unavailable"
        }
        return "fmt=\(fourCCString(format)) tl=\(samples.tl) center=\(samples.center) br=\(samples.br)"
    }

    private static func sampleLumaTriplet(from pixelBuffer: CVPixelBuffer) -> (tl: Int, center: Int, br: Int)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        if CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) > 0 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            return (
                tl: mean8BitLuma(base: base, bytesPerRow: bytesPerRow, width: width, height: height, centerX: 12, centerY: 12),
                center: mean8BitLuma(base: base, bytesPerRow: bytesPerRow, width: width, height: height, centerX: width / 2, centerY: height / 2),
                br: mean8BitLuma(base: base, bytesPerRow: bytesPerRow, width: width, height: height, centerX: max(0, width - 12), centerY: max(0, height - 12))
            )
        }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        return (
            tl: meanBGRA(base: base, bytesPerRow: bytesPerRow, width: width, height: height, centerX: 12, centerY: 12),
            center: meanBGRA(base: base, bytesPerRow: bytesPerRow, width: width, height: height, centerX: width / 2, centerY: height / 2),
            br: meanBGRA(base: base, bytesPerRow: bytesPerRow, width: width, height: height, centerX: max(0, width - 12), centerY: max(0, height - 12))
        )
    }

    private static func mean8BitLuma(
        base: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        centerX: Int,
        centerY: Int
    ) -> Int {
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let radius = 8
        let startX = max(0, min(width - 1, centerX) - radius)
        let endX = min(width - 1, max(0, centerX) + radius)
        let startY = max(0, min(height - 1, centerY) - radius)
        let endY = min(height - 1, max(0, centerY) + radius)

        var sum = 0
        var count = 0
        for y in startY...endY {
            let row = ptr.advanced(by: y * bytesPerRow)
            for x in startX...endX {
                sum += Int(row[x])
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return sum / count
    }

    private static func meanBGRA(
        base: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        centerX: Int,
        centerY: Int
    ) -> Int {
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let radius = 8
        let startX = max(0, min(width - 1, centerX) - radius)
        let endX = min(width - 1, max(0, centerX) + radius)
        let startY = max(0, min(height - 1, centerY) - radius)
        let endY = min(height - 1, max(0, centerY) + radius)

        var sum = 0
        var count = 0
        for y in startY...endY {
            let row = ptr.advanced(by: y * bytesPerRow)
            for x in startX...endX {
                let pixel = row.advanced(by: x * 4)
                let b = Int(pixel[0])
                let g = Int(pixel[1])
                let r = Int(pixel[2])
                sum += (r * 77 + g * 150 + b * 29) / 256
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return sum / count
    }

    private static func fourCCString(_ value: OSType) -> String {
        let chars: [CChar] = [
            CChar((value >> 24) & 0xff),
            CChar((value >> 16) & 0xff),
            CChar((value >> 8) & 0xff),
            CChar(value & 0xff),
            0
        ]
        return String(cString: chars)
    }
}

@MainActor
private final class NativePiPController: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    var onPictureInPictureClosed: (() -> Void)?

    private let sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private var privatePiPFrameworkHandle: UnsafeMutableRawPointer?
    private var privatePiPController: NSObject?
    private var privatePiPPresented = false
    private var isStoppingPrivatePiPProgrammatically = false
    private var privatePiPContentViewController = NSViewController()
    private var privatePiPPanel: NSWindow?
    private var privatePiPPanelCloseObserver: NSObjectProtocol?
    private var windowWillCloseObserver: NSObjectProtocol?
    private var windowDidBecomeKeyObserver: NSObjectProtocol?
    private var isObservingPrivatePiPPanel = false
    private var privatePiPPanelKVOContext = 0
    private var privatePiPPanelNilVerificationWorkItem: DispatchWorkItem?
    private var wantsStart = false
    private var isStartingPictureInPicture = false
    private var hasReceivedFrame = false
    private var enqueuedSampleCount = 0
    private var timebase: CMTimebase?
    private var lastSampleBuffer: CMSampleBuffer?
    private var lastEnqueuedImageSize: CGSize = .zero
    private var expectedVideoAspectRatio: CGFloat = 16.0 / 9.0

    override init() {
        super.init()
        setupIfNeeded()
    }

    func enqueue(sampleBuffer: CMSampleBuffer) {
        lastSampleBuffer = sampleBuffer
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let incomingSize = CGSize(
                width: CVPixelBufferGetWidth(imageBuffer),
                height: CVPixelBufferGetHeight(imageBuffer)
            )
            if sizeChanged(incomingSize, comparedTo: lastEnqueuedImageSize) {
                if lastEnqueuedImageSize.width > 0, lastEnqueuedImageSize.height > 0 {
                    if pipDebugLoggingEnabled {
                        print(
                            "[Float PiP] pip.input-size-changed old=\(Int(lastEnqueuedImageSize.width))x\(Int(lastEnqueuedImageSize.height)) " +
                            "new=\(Int(incomingSize.width))x\(Int(incomingSize.height)) action=flush"
                        )
                    }
                    sampleBufferDisplayLayer.flushAndRemoveImage()
                }
                lastEnqueuedImageSize = incomingSize
            }
        }
        enqueuedSampleCount += 1
        if pipDebugLoggingEnabled, enqueuedSampleCount % 60 == 0 {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            print("[Float PiP] pip.enqueue sample=\(enqueuedSampleCount) pts=\(CMTimeGetSeconds(pts)) dropped=\(sampleBufferDisplayLayer.isReadyForMoreMediaData ? 0 : 1)")
        }

        if sampleBufferDisplayLayer.status == .failed {
            if pipDebugLoggingEnabled {
                let reason = sampleBufferDisplayLayer.error?.localizedDescription ?? "unknown"
                print("[Float PiP] pip.layer.failed reason=\(reason) -- flushing")
            }
            sampleBufferDisplayLayer.flush()
            sampleBufferDisplayLayer.flushAndRemoveImage()
        }

        guard sampleBufferDisplayLayer.isReadyForMoreMediaData else { return }
        sampleBufferDisplayLayer.enqueue(sampleBuffer)
        hasReceivedFrame = true
        attemptStartPiP()
    }

    func requestStart() {
        wantsStart = true
        syncDisplayLayerTimebaseToHostClock(reason: "requestStart")
        attemptStartPiP()
    }

    func stop() {
        wantsStart = false
        isStartingPictureInPicture = false
        hasReceivedFrame = false
        if privatePiPPresented {
            let shouldDismissPrivatePiP = shouldAttemptPrivateDismiss()
            handlePrivatePiPStateDidChange(isPresented: false, reason: "stop-request", notifyExternalClose: false)
            isStoppingPrivatePiPProgrammatically = true
            if shouldDismissPrivatePiP, let privatePiPController {
                if dismissPrivatePictureInPicture(on: privatePiPController) {
                    if pipDebugLoggingEnabled {
                        print("[Float PiP] private.stop requested=true")
                    }
                } else if pipDebugLoggingEnabled {
                    print("[Float PiP] private.stop requested=false reason=missing-dismiss-selector")
                }
            } else if pipDebugLoggingEnabled {
                print("[Float PiP] private.stop requested=false reason=tracked-window-not-visible")
            }
            isStoppingPrivatePiPProgrammatically = false
        }
        pipController?.stopPictureInPicture()
        sampleBufferDisplayLayer.flush()
        sampleBufferDisplayLayer.flushAndRemoveImage()
        syncDisplayLayerTimebaseToHostClock(reason: "stop")
        expectedVideoAspectRatio = 16.0 / 9.0
        lastEnqueuedImageSize = .zero
    }

    func updateExpectedVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let ratio = size.width / size.height
        guard ratio.isFinite, ratio > 0 else { return }
        if abs(ratio - expectedVideoAspectRatio) < 0.01 {
            return
        }
        expectedVideoAspectRatio = ratio
        if pipDebugLoggingEnabled {
            print("[Float PiP] pip.video-aspect updated ratio=\(String(format: "%.4f", ratio)) source=\(Int(size.width))x\(Int(size.height))")
        }
        applyPrivatePiPAspectConstraints(reason: "video-size-update")
    }

    private func setupIfNeeded() {
        if pipController != nil || privatePiPController != nil { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        sampleBufferDisplayLayer.videoGravity = .resizeAspect
        sampleBufferDisplayLayer.isOpaque = false
        sampleBufferDisplayLayer.masksToBounds = true
        sampleBufferDisplayLayer.needsDisplayOnBoundsChange = true
        sampleBufferDisplayLayer.anchorPoint = CGPoint(x: 0, y: 0)
        sampleBufferDisplayLayer.position = .zero
        sampleBufferDisplayLayer.frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        sampleBufferDisplayLayer.backgroundColor = NSColor.clear.cgColor
        setupPrivatePiPHostView()

        var timebase: CMTimebase?
        let createStatus = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if createStatus == noErr, let timebase {
            self.timebase = timebase
            syncDisplayLayerTimebaseToHostClock(reason: "setup")
        }

        if setupPrivatePiPController() {
            if pipDebugLoggingEnabled {
                print("[Float PiP] pip.setup supported=true mode=privatePIP")
            }
            return
        }

        if pipDebugLoggingEnabled {
            print("[Float PiP] pip.setup supported=true mode=sampleBufferDisplayLayer")
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferDisplayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.requiresLinearPlayback = true
        controller.delegate = self
        pipController = controller
        if pipDebugLoggingEnabled {
            print("[Float PiP] pip.config requiresLinearPlayback=\(controller.requiresLinearPlayback)")
        }
    }

    private func attemptStartPiP() {
        guard wantsStart else { return }
        guard hasReceivedFrame else { return }
        guard !isStartingPictureInPicture else { return }

        if let privatePiPController {
            guard !privatePiPPresented else { return }
            let selectorName = "presentViewControllerAsPictureInPicture:"
            guard privatePiPController.responds(to: NSSelectorFromString(selectorName)) else {
                if pipDebugLoggingEnabled {
                    print("[Float PiP] private.start unavailable reason=missing-selector")
                }
                return
            }
            isStartingPictureInPicture = true
            applyPrivatePiPAspectConstraints(reason: "start")
            if pipDebugLoggingEnabled {
                print("[Float PiP] private.start possible=true")
            }
            guard callObjectSetter(
                on: privatePiPController,
                selectorName: selectorName,
                value: privatePiPContentViewController
            ) else {
                isStartingPictureInPicture = false
                if pipDebugLoggingEnabled {
                    print("[Float PiP] private.start failed reason=invoke-error")
                }
                return
            }
            handlePrivatePiPStateDidChange(isPresented: true, reason: "start", notifyExternalClose: false)
            if pipDebugLoggingEnabled {
                let panel = currentPrivatePiPPanel()
                let panelClass = panel.map { NSStringFromClass(type(of: $0)) } ?? "nil"
                print("[Float PiP] private.start post-present panel=\(panelClass)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600)) { [weak self] in
                guard let self else { return }
                guard self.privatePiPPresented else { return }
                if pipDebugLoggingEnabled {
                    let panel = self.currentPrivatePiPPanel()
                    let panelClass = panel.map { NSStringFromClass(type(of: $0)) } ?? "nil"
                    print("[Float PiP] private.start delayed-panel panel=\(panelClass)")
                }
            }
            isStartingPictureInPicture = false
            return
        }

        guard let pipController else { return }
        guard !pipController.isPictureInPictureActive else { return }
        guard pipController.isPictureInPicturePossible else { return }

        isStartingPictureInPicture = true
        if pipDebugLoggingEnabled {
            print("[Float PiP] pip.start mode=sampleBufferDisplayLayer possible=true")
        }
        pipController.startPictureInPicture()
    }

    private func setupPrivatePiPHostView() {
        let hostView = NSView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
        hostView.wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.frame = hostView.bounds
        rootLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        rootLayer.backgroundColor = NSColor.clear.cgColor
        hostView.layer = rootLayer

        sampleBufferDisplayLayer.frame = rootLayer.bounds
        sampleBufferDisplayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        rootLayer.addSublayer(sampleBufferDisplayLayer)

        privatePiPContentViewController = NSViewController()
        privatePiPContentViewController.view = hostView
    }

    private func setupPrivatePiPController() -> Bool {
        let path = "/System/Library/PrivateFrameworks/PIP.framework/Versions/A/PIP"
        privatePiPFrameworkHandle = dlopen(path, RTLD_NOW)
        guard privatePiPFrameworkHandle != nil else {
            if pipDebugLoggingEnabled {
                let error = dlerror().map { String(cString: $0) } ?? "unknown"
                print("[Float PiP] private.setup failed reason=dlopen error=\(error)")
            }
            return false
        }

        guard let pipClass = NSClassFromString("PIPViewController") as? NSObject.Type else {
            if pipDebugLoggingEnabled {
                print("[Float PiP] private.setup failed reason=missing-class PIPViewController")
            }
            return false
        }

        let controller = pipClass.init()
        let presentSelector = NSSelectorFromString("presentViewControllerAsPictureInPicture:")
        guard controller.responds(to: presentSelector) else {
            if pipDebugLoggingEnabled {
                print("[Float PiP] private.setup failed reason=missing-selector presentViewControllerAsPictureInPicture:")
            }
            return false
        }

        privatePiPController = controller
        applyPrivatePiPAspectConstraints(reason: "setup")
        return true
    }

    private func applyPrivatePiPAspectConstraints(reason: String) {
        guard let controller = privatePiPController else { return }

        let ratio = max(0.2, min(5.0, expectedVideoAspectRatio))
        let aspectSize = CGSize(width: ratio, height: 1.0)

        // Use sane bounds so the private PiP panel keeps resize enabled but stays on ratio.
        let minWidth: CGFloat = 320
        let maxWidth: CGFloat = 3840
        let minSize = CGSize(width: minWidth, height: max(1, round(minWidth / ratio)))
        let maxSize = CGSize(width: maxWidth, height: max(1, round(maxWidth / ratio)))

        callBoolSetter(on: controller, selectorName: "setUserCanResize:", value: true)
        callCGSizeSetter(on: controller, selectorName: "setAspectRatio:", value: aspectSize)
        callCGSizeSetter(on: controller, selectorName: "setPreferredMinimumSize:", value: minSize)
        callCGSizeSetter(on: controller, selectorName: "setPreferredMaximumSize:", value: maxSize)
        callCGSizeSetter(on: controller, selectorName: "setMinSize:", value: minSize)
        callCGSizeSetter(on: controller, selectorName: "setMaxSize:", value: maxSize)

        if pipDebugLoggingEnabled {
            print(
                "[Float PiP] private.aspect-constraints reason=\(reason) " +
                "ratio=\(String(format: "%.4f", ratio)) " +
                "min=\(Int(minSize.width))x\(Int(minSize.height)) " +
                "max=\(Int(maxSize.width))x\(Int(maxSize.height))"
            )
        }
    }

    private func callCGSizeSetter(on controller: NSObject, selectorName: String, value: CGSize) {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, CGSize) -> Void
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Setter.self)
        fn(controller, selector, value)
    }

    private func callBoolSetter(on controller: NSObject, selectorName: String, value: Bool) {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Setter.self)
        fn(controller, selector, value)
    }

    private func callObjectSetter(on controller: NSObject, selectorName: String, value: AnyObject?) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Setter.self)
        fn(controller, selector, value)
        return true
    }

    private func callVoidMethod(on controller: NSObject, selectorName: String) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return false }
        typealias Method = @convention(c) (AnyObject, Selector) -> Void
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Method.self)
        fn(controller, selector)
        return true
    }

    private func callObjectGetter(on controller: NSObject, selectorName: String) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Getter.self)
        return fn(controller, selector)
    }

    private func dismissPrivatePictureInPicture(on controller: NSObject) -> Bool {
        if callVoidMethod(on: controller, selectorName: "dismissPictureInPicture") {
            return true
        }
        if callVoidMethod(on: controller, selectorName: "stopPictureInPicture") {
            return true
        }
        if callObjectSetter(on: controller, selectorName: "dismissPictureInPictureWithCompletionHandler:", value: nil) {
            return true
        }
        return false
    }

    private func handlePrivatePiPStateDidChange(isPresented: Bool, reason: String, notifyExternalClose: Bool) {
        privatePiPPresented = isPresented
        if isPresented {
            cancelPrivatePiPPanelNilVerification(reason: "state-presented")
            startPrivatePiPPanelObservation()
            refreshPrivatePiPPanelFromController()
        } else {
            cancelPrivatePiPPanelNilVerification(reason: "state-not-presented")
            stopPrivatePiPPanelObservation()
            if notifyExternalClose {
                onPictureInPictureClosed?()
            }
        }
        if pipDebugLoggingEnabled {
            let panelClass = privatePiPPanel.map { NSStringFromClass(type(of: $0)) } ?? "nil"
            print(
                "[Float PiP] private.state presented=\(isPresented) reason=\(reason) " +
                "notifyExternalClose=\(notifyExternalClose) panel=\(panelClass) observing=\(isObservingPrivatePiPPanel)"
            )
        }
    }

    private func startPrivatePiPPanelObservation() {
        guard let controller = privatePiPController else { return }
        ensureGlobalWindowObservers()
        if !isObservingPrivatePiPPanel {
            controller.addObserver(self, forKeyPath: "panel", options: [.initial, .new], context: &privatePiPPanelKVOContext)
            isObservingPrivatePiPPanel = true
            if pipDebugLoggingEnabled {
                print("[Float PiP] private.panel-observe start")
            }
        } else {
            refreshPrivatePiPPanelFromController()
        }
    }

    private func stopPrivatePiPPanelObservation() {
        cancelPrivatePiPPanelNilVerification(reason: "stop-observation")
        if isObservingPrivatePiPPanel, let controller = privatePiPController {
            controller.removeObserver(self, forKeyPath: "panel", context: &privatePiPPanelKVOContext)
            isObservingPrivatePiPPanel = false
        }
        detachPrivatePiPPanelCloseObserver()
        detachGlobalWindowObservers()
        privatePiPPanel = nil
        if pipDebugLoggingEnabled {
            print("[Float PiP] private.panel-observe stop")
        }
    }

    private func detachPrivatePiPPanelCloseObserver() {
        if let observer = privatePiPPanelCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            privatePiPPanelCloseObserver = nil
        }
    }

    private func refreshPrivatePiPPanelFromController() {
        let panel = currentPrivatePiPPanel()
        if pipDebugLoggingEnabled {
            let panelClass = panel.map { NSStringFromClass(type(of: $0)) } ?? "nil"
            print("[Float PiP] private.panel refresh panel=\(panelClass)")
        }
        updateObservedPrivatePiPPanel(panel)
    }

    private func currentPrivatePiPPanel() -> NSWindow? {
        guard let controller = privatePiPController else { return nil }
        return callObjectGetter(on: controller, selectorName: "panel") as? NSWindow
    }

    private func updateObservedPrivatePiPPanel(_ panel: NSWindow?) {
        if privatePiPPanel === panel { return }
        detachPrivatePiPPanelCloseObserver()
        privatePiPPanel = panel
        guard let panel else {
            if pipDebugLoggingEnabled {
                print("[Float PiP] private.panel detached")
            }
            schedulePrivatePiPPanelNilVerification(reason: "panel-detached")
            return
        }
        cancelPrivatePiPPanelNilVerification(reason: "panel-attached")
        privatePiPPanelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePrivatePiPPanelWillClose()
            }
        }
        if pipDebugLoggingEnabled {
            let title = panel.title.isEmpty ? "<empty>" : panel.title
            print("[Float PiP] private.panel attached class=\(NSStringFromClass(type(of: panel))) title=\(title) visible=\(panel.isVisible)")
        }
    }

    private func ensureGlobalWindowObservers() {
        if windowWillCloseObserver == nil {
            windowWillCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleAnyWindowWillClose(notification)
            }
        }
        if windowDidBecomeKeyObserver == nil {
            windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleAnyWindowDidBecomeKey(notification)
            }
        }
    }

    private func detachGlobalWindowObservers() {
        if let observer = windowWillCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            windowWillCloseObserver = nil
        }
        if let observer = windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            windowDidBecomeKeyObserver = nil
        }
    }

    private func handleAnyWindowDidBecomeKey(_ notification: Notification) {
        guard privatePiPPresented else { return }
        guard let window = notification.object as? NSWindow else { return }
        let isMatch = isLikelyPrivatePiPWindow(window)
        if pipDebugLoggingEnabled {
            let title = window.title.isEmpty ? "<empty>" : window.title
            print(
                "[Float PiP] private.window didBecomeKey class=\(NSStringFromClass(type(of: window))) " +
                "title=\(title) visible=\(window.isVisible) level=\(window.level.rawValue) match=\(isMatch)"
            )
        }
        if isMatch {
            updateObservedPrivatePiPPanel(window)
            if pipDebugLoggingEnabled {
                let className = NSStringFromClass(type(of: window))
                print("[Float PiP] private.panel visible class=\(className)")
            }
        }
    }

    private func handleAnyWindowWillClose(_ notification: Notification) {
        guard privatePiPPresented else { return }
        guard let window = notification.object as? NSWindow else { return }
        let isMatch = window === privatePiPPanel || isLikelyPrivatePiPWindow(window)
        if pipDebugLoggingEnabled {
            let title = window.title.isEmpty ? "<empty>" : window.title
            let className = NSStringFromClass(type(of: window))
            let trackedClass = privatePiPPanel.map { NSStringFromClass(type(of: $0)) } ?? "nil"
            print(
                "[Float PiP] private.window willClose class=\(className) title=\(title) " +
                "visible=\(window.isVisible) match=\(isMatch) tracked=\(trackedClass)"
            )
        }
        guard isMatch else { return }
        handlePrivatePiPPanelWillClose()
    }

    private func isLikelyPrivatePiPWindow(_ window: NSWindow) -> Bool {
        if window === privatePiPPanel { return true }
        if window.contentViewController === privatePiPContentViewController { return true }
        if privatePiPContentViewController.view.window === window { return true }
        let className = NSStringFromClass(type(of: window)).lowercased()
        if className.contains("pip") || className.contains("pictureinpicture") {
            return true
        }
        return false
    }

    private func handlePrivatePiPPanelWillClose() {
        cancelPrivatePiPPanelNilVerification(reason: "panel-will-close")
        let isExternalClose = !isStoppingPrivatePiPProgrammatically
        if pipDebugLoggingEnabled {
            print("[Float PiP] private.panel willClose external=\(isExternalClose)")
        }
        guard privatePiPPresented else { return }
        handlePrivatePiPStateDidChange(
            isPresented: false,
            reason: "panel-willClose",
            notifyExternalClose: isExternalClose
        )
    }

    private func schedulePrivatePiPPanelNilVerification(reason: String) {
        guard privatePiPPresented else { return }
        guard !isStoppingPrivatePiPProgrammatically else {
            if pipDebugLoggingEnabled {
                print("[Float PiP] private.panel nil-verify skip reason=programmatic-stop trigger=\(reason)")
            }
            return
        }
        cancelPrivatePiPPanelNilVerification(reason: "reschedule-\(reason)")
        let delay: DispatchTimeInterval = .milliseconds(450)
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.verifyPrivatePiPPanelAfterNilTransition(trigger: reason)
            }
        }
        privatePiPPanelNilVerificationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        if pipDebugLoggingEnabled {
            print("[Float PiP] private.panel nil-verify scheduled trigger=\(reason) delayMs=450")
        }
    }

    private func cancelPrivatePiPPanelNilVerification(reason: String) {
        guard let workItem = privatePiPPanelNilVerificationWorkItem else { return }
        workItem.cancel()
        privatePiPPanelNilVerificationWorkItem = nil
        if pipDebugLoggingEnabled {
            print("[Float PiP] private.panel nil-verify canceled reason=\(reason)")
        }
    }

    private func verifyPrivatePiPPanelAfterNilTransition(trigger: String) {
        privatePiPPanelNilVerificationWorkItem = nil
        guard privatePiPPresented else {
            if pipDebugLoggingEnabled {
                print("[Float PiP] private.panel nil-verify ignored reason=not-presented trigger=\(trigger)")
            }
            return
        }
        guard !isStoppingPrivatePiPProgrammatically else {
            if pipDebugLoggingEnabled {
                print("[Float PiP] private.panel nil-verify ignored reason=programmatic-stop trigger=\(trigger)")
            }
            return
        }
        let panel = currentPrivatePiPPanel()
        guard panel == nil else {
            if pipDebugLoggingEnabled {
                let className = panel.map { NSStringFromClass(type(of: $0)) } ?? "unknown"
                print("[Float PiP] private.panel nil-verify recovered panel=\(className) trigger=\(trigger)")
            }
            updateObservedPrivatePiPPanel(panel)
            return
        }
        if pipDebugLoggingEnabled {
            print("[Float PiP] private.panel nil-verify confirmed trigger=\(trigger) action=close")
        }
        handlePrivatePiPPanelWillClose()
    }

    private func shouldAttemptPrivateDismiss() -> Bool {
        guard privatePiPPresented else { return false }
        if let panel = privatePiPPanel {
            return panel.isVisible
        }
        return currentPrivatePiPPanel() != nil
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard context == &privatePiPPanelKVOContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        guard keyPath == "panel" else { return }
        refreshPrivatePiPPanelFromController()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStartingPictureInPicture = false
        replayLastSampleIfPossible(reason: "delegate-start")
        if pipDebugLoggingEnabled {
            print("[Float PiP] pip.delegate didStart")
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isStartingPictureInPicture = false
        if pipDebugLoggingEnabled {
            print("[Float PiP] pip.delegate failedToStart error=\(error.localizedDescription)")
        }
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        if pipDebugLoggingEnabled {
            print("[Float PiP] pip.delegate willStop")
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStartingPictureInPicture = false
        if pipDebugLoggingEnabled {
            print("[Float PiP] pip.delegate didStop")
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime.positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        if pipDebugLoggingEnabled {
            print("[Float PiP] pip.render-size width=\(Int(newRenderSize.width)) height=\(Int(newRenderSize.height))")
        }
        replayLastSampleIfPossible(reason: "render-size-transition")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    private func replayLastSampleIfPossible(reason: String) {
        sampleBufferDisplayLayer.flushAndRemoveImage()
        syncDisplayLayerTimebaseToHostClock(reason: reason)

        if let lastSampleBuffer, sampleBufferDisplayLayer.isReadyForMoreMediaData {
            sampleBufferDisplayLayer.enqueue(lastSampleBuffer)
            if pipDebugLoggingEnabled {
                let pts = CMSampleBufferGetPresentationTimeStamp(lastSampleBuffer)
                print("[Float PiP] pip.layer-replay reason=\(reason) pts=\(CMTimeGetSeconds(pts))")
            }
        } else if pipDebugLoggingEnabled {
            print("[Float PiP] pip.layer-replay-skipped reason=\(reason) ready=\(sampleBufferDisplayLayer.isReadyForMoreMediaData) hasSample=\(lastSampleBuffer != nil)")
        }
    }

    private func sizeChanged(_ lhs: CGSize, comparedTo rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) > 1 || abs(lhs.height - rhs.height) > 1
    }

    private func syncDisplayLayerTimebaseToHostClock(reason: String) {
        guard let timebase else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        CMTimebaseSetTime(timebase, time: now)
        CMTimebaseSetRate(timebase, rate: 1.0)
        sampleBufferDisplayLayer.controlTimebase = timebase
        if pipDebugLoggingEnabled {
            print("[Float PiP] pip.timebase-sync reason=\(reason) host=\(CMTimeGetSeconds(now))")
        }
    }
}
#endif
