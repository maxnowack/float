#if canImport(WebRTC)
import AppKit
import Foundation
import WebRTC

@MainActor
final class NativeLibWebRTCReceiver: NSObject, WebRTCReceiver {
    private static let opusRtpmapRegex = try! NSRegularExpression(
        pattern: #"^a=rtpmap:(\d+)\s+opus/48000/2$"#,
        options: [.caseInsensitive]
    )
    private static let fmtpPayloadRegex = try! NSRegularExpression(
        pattern: #"^a=fmtp:(\d+)\s+"#,
        options: [.caseInsensitive]
    )
    private static let terminalConnectionStates: Set<RTCPeerConnectionState> = [
        .disconnected, .failed, .closed,
    ]
    private static let statsProbeIntervalSeconds: TimeInterval = 1.0
    private static let fpsSmoothingAlpha: Double = 0.28

    private struct VideoInboundSnapshot {
        let framesDecoded: Double
        let sampleTime: Date
    }

    var onLocalIceCandidate: ((LocalIceCandidate) -> Void)?
    var onStreamingChanged: ((Bool) -> Void)?
    var onPlaybackCommand: ((Bool) -> Void)?
    var onSeekCommand: ((Double) -> Void)?
    var onPiPRenderSizeChanged: ((CGSize) -> Void)?

    private static var didInitializeSSL = false
    private static var didInitializeFieldTrials = false
    static var isSupported: Bool {
        RTCMTLNSVideoView.isMetalAvailable()
    }

    private let pipController = NativePiPController()
    private let peerConnectionFactory: RTCPeerConnectionFactory
    private let videoView: RTCMTLNSVideoView

    private var peerConnection: RTCPeerConnection?
    private var remoteVideoTrack: RTCVideoTrack?
    private var remoteAudioTrack: RTCAudioTrack?
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var currentTabId: Int?
    private var currentVideoId: String?
    private var isStopping = false
    private var debugLoggingEnabled = false
    private var diagnosticsOverlayEnabled = true
    private var statsProbeTimer: Timer?
    private var lastVideoInboundSnapshot: VideoInboundSnapshot?
    private var smoothedVideoFPS: Double?
    private var lastReportedVideoSize = CGSize.zero

    override init() {
        if !Self.didInitializeFieldTrials {
            RTCInitFieldTrialDictionary([
                // Avoid AEC render/capture downmix behavior that can collapse stereo channels.
                "WebRTC-Aec3EnforceRenderDelayEstimationDownmixing": "Disabled",
                "WebRTC-Aec3EnforceCaptureDelayEstimationDownmixing": "Disabled",
            ])
            Self.didInitializeFieldTrials = true
        }

        if !Self.didInitializeSSL {
            _ = RTCInitializeSSL()
            Self.didInitializeSSL = true
        }

        peerConnectionFactory = RTCPeerConnectionFactory()
        videoView = RTCMTLNSVideoView(frame: .zero)

        super.init()

        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        videoView.delegate = self

        pipController.setContentView(videoView)
        pipController.onPictureInPictureClosed = { [weak self] in
            self?.stop()
        }
        pipController.onPlaybackCommand = { [weak self] isPlaying in
            self?.onPlaybackCommand?(isPlaying)
        }
        pipController.onSeekCommand = { [weak self] intervalSeconds in
            self?.onSeekCommand?(intervalSeconds)
        }
        pipController.onPiPRenderSizeChanged = { [weak self] size in
            self?.onPiPRenderSizeChanged?(size)
        }
    }

    func handleOffer(_ offer: OfferMessage) async throws -> String {
        currentTabId = offer.tabId
        currentVideoId = offer.videoId

        pipController.stop()
        clearActivePeerConnection(notifyStreamingStopped: false)

        let connection = try makePeerConnection()
        peerConnection = connection

        do {
            let remoteOffer = RTCSessionDescription(type: .offer, sdp: offer.sdp)
            try await setRemoteDescription(remoteOffer, on: connection)
            try await flushPendingRemoteCandidates(on: connection)

            let createdAnswer = try await createAnswer(on: connection)
            let stereoAnswerSdp = enforceStereoOpusInSdp(createdAnswer.sdp)
            let localAnswer = RTCSessionDescription(type: .answer, sdp: stereoAnswerSdp)
            try await setLocalDescription(localAnswer, on: connection)

            try await flushPendingRemoteCandidates(on: connection)

            let localSdp = connection.localDescription?.sdp ?? stereoAnswerSdp
            let outboundAnswerSdp = enforceStereoOpusInSdp(localSdp)
            if outboundAnswerSdp != localSdp {
                log("answer.opusStereo.sdpUpdated mode=post-local-description")
            }
            logCurrentAudioReceiverParameters(context: "answer.created")
            log("answer.created sdpLength=\(outboundAnswerSdp.count)")
            return outboundAnswerSdp
        } catch {
            let reason = error.localizedDescription
            print("[Float NativeRTC] receiver.error failed to process offer: \(reason)")
            clearActivePeerConnection(notifyStreamingStopped: true)
            throw error
        }
    }

    func addRemoteIceCandidate(_ ice: IceMessage) async throws {
        let candidate = RTCIceCandidate(
            sdp: ice.candidate,
            sdpMLineIndex: Int32(ice.sdpMLineIndex ?? 0),
            sdpMid: ice.sdpMid
        )

        guard let connection = peerConnection, connection.remoteDescription != nil else {
            queueRemoteCandidate(candidate)
            return
        }

        try await addIceCandidate(candidate, to: connection)
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        resetActiveSource()
        clearActivePeerConnection(notifyStreamingStopped: true)
        pipController.stop()
    }

    func updatePlaybackState(isPlaying: Bool) {
        pipController.updatePlaybackState(isPlaying)
    }

    func updatePlaybackProgress(elapsedSeconds: Double?, durationSeconds: Double?) {
        pipController.updatePlaybackProgress(elapsedSeconds: elapsedSeconds, durationSeconds: durationSeconds)
    }

    func setDebugLoggingEnabled(_ enabled: Bool) {
        debugLoggingEnabled = enabled
        if enabled {
            startStatsProbeIfNeeded()
        } else if !diagnosticsOverlayEnabled {
            stopStatsProbe()
        }
    }

    func setDiagnosticsOverlayEnabled(_ enabled: Bool) {
        guard diagnosticsOverlayEnabled != enabled else {
            return
        }

        diagnosticsOverlayEnabled = enabled
        if enabled {
            startStatsProbeIfNeeded()
        } else {
            pipController.updateDiagnosticsOverlay(nil)
            if !debugLoggingEnabled {
                stopStatsProbe()
            }
        }
    }

    private func makePeerConnection() throws -> RTCPeerConnection {
        let configuration = RTCConfiguration()
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce

        let constraints = makeMediaConstraints()

        guard let connection = peerConnectionFactory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self
        ) else {
            throw WebRTCReceiverError.peerConnectionUnavailable
        }

        log("webrtc.pc.create")
        return connection
    }

    private func clearActivePeerConnection(notifyStreamingStopped: Bool) {
        stopStatsProbe()
        pendingRemoteCandidates.removeAll()
        lastVideoInboundSnapshot = nil
        smoothedVideoFPS = nil
        lastReportedVideoSize = .zero
        pipController.updateDiagnosticsOverlay(nil)

        if let remoteVideoTrack {
            remoteVideoTrack.remove(videoView)
            self.remoteVideoTrack = nil
        }

        remoteAudioTrack = nil

        if let connection = peerConnection {
            connection.delegate = nil
            connection.close()
            peerConnection = nil
        }

        if notifyStreamingStopped {
            onStreamingChanged?(false)
        }
    }

    private func attachRemoteVideoTrack(_ track: RTCVideoTrack) {
        if let existing = remoteVideoTrack, existing.trackId == track.trackId {
            return
        }

        if let existing = remoteVideoTrack {
            existing.remove(videoView)
        }

        remoteVideoTrack = track
        track.isEnabled = true
        track.add(videoView)
        startStatsProbeIfNeeded()
        pipController.requestStart()
        onStreamingChanged?(true)

        log("track.attach kind=video trackId=\(track.trackId)")
    }

    private func attachRemoteAudioTrack(_ track: RTCAudioTrack) {
        if let existing = remoteAudioTrack, existing.trackId == track.trackId {
            return
        }

        remoteAudioTrack = track
        track.isEnabled = true
        log("track.attach kind=audio trackId=\(track.trackId)")
        startStatsProbeIfNeeded()
    }

    private func handleConnectionStateChange(_ newState: RTCPeerConnectionState) {
        log("webrtc.connectionState=\(newState.rawValue)")
        if Self.terminalConnectionStates.contains(newState) {
            onStreamingChanged?(false)
            pipController.stop()
        }
    }

    private func handleGeneratedLocalCandidate(_ candidate: RTCIceCandidate) {
        guard let tabId = currentTabId, let videoId = currentVideoId else {
            return
        }
        let payload = LocalIceCandidate(
            tabId: tabId,
            videoId: videoId,
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: Int(candidate.sdpMLineIndex)
        )
        onLocalIceCandidate?(payload)
    }

    private func setRemoteDescription(_ description: RTCSessionDescription, on connection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription, on connection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private func createAnswer(on connection: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = makeMediaConstraints()

        return try await withCheckedThrowingContinuation { continuation in
            connection.answer(for: constraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sdp else {
                    continuation.resume(throwing: WebRTCReceiverError.peerConnectionUnavailable)
                    return
                }
                continuation.resume(returning: sdp)
            }
        }
    }

    private func addIceCandidate(_ candidate: RTCIceCandidate, to connection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.add(candidate) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private func flushPendingRemoteCandidates(on connection: RTCPeerConnection) async throws {
        guard connection.remoteDescription != nil else {
            return
        }

        while !pendingRemoteCandidates.isEmpty {
            let candidate = pendingRemoteCandidates.removeFirst()
            try await addIceCandidate(candidate, to: connection)
        }
    }

    private func enforceStereoOpusInSdp(_ sdp: String) -> String {
        if sdp.isEmpty {
            return sdp
        }

        let lines = sdp.components(separatedBy: "\r\n")
        var opusPayloadTypes = Set<String>()
        for line in lines {
            if let payload = opusPayloadType(fromRtpmapLine: line) {
                opusPayloadTypes.insert(payload)
            }
        }
        if opusPayloadTypes.isEmpty {
            return sdp
        }

        var updatedAny = false
        var transformed = lines.map { line -> String in
            guard let payloadType = payloadType(fromFmtpLine: line), opusPayloadTypes.contains(payloadType) else {
                return line
            }
            updatedAny = true
            return upsertFmtpParameter(line: upsertFmtpParameter(line: line, key: "stereo", value: "1"), key: "sprop-stereo", value: "1")
        }

        if !updatedAny, let firstPayload = opusPayloadTypes.first {
            for index in transformed.indices {
                if transformed[index].lowercased() == "a=rtpmap:\(firstPayload) opus/48000/2".lowercased() {
                    transformed.insert("a=fmtp:\(firstPayload) stereo=1;sprop-stereo=1", at: index + 1)
                    break
                }
            }
        }

        return transformed.joined(separator: "\r\n")
    }

    private func opusPayloadType(fromRtpmapLine line: String) -> String? {
        payloadType(in: line, using: Self.opusRtpmapRegex)
    }

    private func payloadType(fromFmtpLine line: String) -> String? {
        payloadType(in: line, using: Self.fmtpPayloadRegex)
    }

    private func payloadType(in line: String, using regex: NSRegularExpression) -> String? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = regex.firstMatch(in: line, options: [], range: range), match.numberOfRanges > 1 else {
            return nil
        }
        return (line as NSString).substring(with: match.range(at: 1))
    }

    private func makeMediaConstraints() -> RTCMediaConstraints {
        let mandatory: [String: String] = [
            kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
            kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue,
            kRTCMediaConstraintsVoiceActivityDetection: kRTCMediaConstraintsValueFalse,
        ]
        let optional: [String: String] = [
            "googEchoCancellation": "false",
            "googAutoGainControl": "false",
            "googNoiseSuppression": "false",
            "googHighpassFilter": "false",
            "googAudioMirroring": "false",
        ]
        return RTCMediaConstraints(mandatoryConstraints: mandatory, optionalConstraints: optional)
    }

    private func queueRemoteCandidate(_ candidate: RTCIceCandidate) {
        pendingRemoteCandidates.append(candidate)
    }

    private func resetActiveSource() {
        currentTabId = nil
        currentVideoId = nil
    }

    private func upsertFmtpParameter(line: String, key: String, value: String) -> String {
        guard let prefixEnd = line.firstIndex(of: " ") else {
            return line
        }
        let prefix = String(line[..<line.index(after: prefixEnd)])
        let rawValue = String(line[line.index(after: prefixEnd)...])

        var segments = rawValue
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let target = "\(key)=\(value)"
        let keyPrefix = "\(key)=".lowercased()
        if let index = segments.firstIndex(where: { $0.lowercased().hasPrefix(keyPrefix) }) {
            segments[index] = target
        } else {
            segments.append(target)
        }

        return "\(prefix)\(segments.joined(separator: ";"))"
    }

    private func log(_ message: String) {
        guard debugLoggingEnabled else { return }
        print("[Float NativeRTC] \(message)")
    }

    private func serializeForLog(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return text
    }

    private func logCurrentAudioReceiverParameters(context: String) {
        guard debugLoggingEnabled else { return }
        guard let connection = peerConnection else { return }

        let payload: [[String: Any]] = connection.receivers.compactMap { receiver in
            guard let track = receiver.track, track.kind == kRTCMediaStreamTrackKindAudio else {
                return nil
            }

            let codecs = receiver.parameters.codecs
                .filter { $0.kind == kRTCMediaStreamTrackKindAudio }
                .map { codec in
                    [
                        "payloadType": codec.payloadType,
                        "name": codec.name,
                        "clockRate": codec.clockRate ?? NSNull(),
                        "numChannels": codec.numChannels ?? NSNull(),
                        "parameters": codec.parameters,
                    ] as [String: Any]
                }

            return [
                "receiverId": receiver.receiverId,
                "trackId": track.trackId,
                "trackEnabled": track.isEnabled,
                "codecCount": codecs.count,
                "codecs": codecs,
            ]
        }

        if !payload.isEmpty {
            log("receiver.audio.parameters context=\(context) payload=\(serializeForLog(payload))")
        }
    }

    private func startStatsProbeIfNeeded() {
        guard diagnosticsOverlayEnabled || debugLoggingEnabled else { return }
        guard peerConnection != nil else { return }
        guard statsProbeTimer == nil else { return }

        statsProbeTimer = Timer.scheduledTimer(withTimeInterval: Self.statsProbeIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.collectReceiverStats()
            }
        }
        collectReceiverStats()
    }

    private func stopStatsProbe() {
        statsProbeTimer?.invalidate()
        statsProbeTimer = nil
    }

    private func collectReceiverStats() {
        guard let connection = peerConnection else { return }

        connection.statistics { [weak self] report in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateVideoDiagnosticsOverlay(using: report)
                if self.debugLoggingEnabled {
                    self.logReceiverAudioStats(report)
                }
            }
        }
    }

    private func updateVideoDiagnosticsOverlay(using report: RTCStatisticsReport) {
        guard diagnosticsOverlayEnabled else {
            pipController.updateDiagnosticsOverlay(nil)
            return
        }

        guard remoteVideoTrack != nil else {
            pipController.updateDiagnosticsOverlay(nil)
            return
        }

        var selectedStat: RTCStatistics?
        for (_, stat) in report.statistics where stat.type == "inbound-rtp" {
            let values = stat.values
            let kind = (values["kind"] as? String) ?? (values["mediaType"] as? String)
            if kind == "video" {
                selectedStat = stat
                break
            }
        }

        guard let selectedStat else {
            pipController.updateDiagnosticsOverlay(nil)
            return
        }

        let values = selectedStat.values
        let reportedFPS = readDoubleStatValue(values["framesPerSecond"])
        let framesDecoded = readDoubleStatValue(values["framesDecoded"])
        let frameWidth = readIntStatValue(values["frameWidth"])
        let frameHeight = readIntStatValue(values["frameHeight"])
        let now = Date()

        let resolvedFPS = resolveReceiverFPS(
            reportedFPS: reportedFPS,
            framesDecoded: framesDecoded,
            sampleTime: now
        )
        let resolvedWidth = frameWidth ?? fallbackVideoDimension(lastReportedVideoSize.width)
        let resolvedHeight = frameHeight ?? fallbackVideoDimension(lastReportedVideoSize.height)

        let fpsText = resolvedFPS.map { String(format: "FPS %.1f", $0) } ?? "FPS --"
        var overlayText = fpsText
        if let resolvedWidth, let resolvedHeight, resolvedWidth > 0, resolvedHeight > 0 {
            overlayText += " | \(resolvedWidth)x\(resolvedHeight)"
        }

        pipController.updateDiagnosticsOverlay(overlayText)

        if debugLoggingEnabled {
            let fpsValue = resolvedFPS.map { String(format: "%.2f", $0) } ?? "null"
            let widthValue = resolvedWidth.map(String.init) ?? "null"
            let heightValue = resolvedHeight.map(String.init) ?? "null"
            log(
                "receiver.stats.video fps=\(fpsValue) width=\(widthValue) height=\(heightValue)"
            )
        }
    }

    private func resolveReceiverFPS(
        reportedFPS: Double?,
        framesDecoded: Double?,
        sampleTime: Date
    ) -> Double? {
        var nextMeasuredFPS: Double? = nil
        if let reportedFPS, reportedFPS.isFinite, reportedFPS >= 0 {
            nextMeasuredFPS = reportedFPS
        } else if let framesDecoded, framesDecoded.isFinite, framesDecoded >= 0,
                  let previous = lastVideoInboundSnapshot
        {
            let deltaFrames = framesDecoded - previous.framesDecoded
            let deltaTime = sampleTime.timeIntervalSince(previous.sampleTime)
            if deltaFrames >= 0, deltaTime > 0 {
                nextMeasuredFPS = deltaFrames / deltaTime
            }
        }

        if let framesDecoded, framesDecoded.isFinite, framesDecoded >= 0 {
            lastVideoInboundSnapshot = VideoInboundSnapshot(framesDecoded: framesDecoded, sampleTime: sampleTime)
        } else {
            lastVideoInboundSnapshot = nil
        }

        guard let nextMeasuredFPS, nextMeasuredFPS.isFinite, nextMeasuredFPS >= 0 else {
            return smoothedVideoFPS
        }

        let boundedFPS = min(240, max(0, nextMeasuredFPS))
        if let current = smoothedVideoFPS {
            smoothedVideoFPS = (current * (1 - Self.fpsSmoothingAlpha)) + (boundedFPS * Self.fpsSmoothingAlpha)
        } else {
            smoothedVideoFPS = boundedFPS
        }
        return smoothedVideoFPS
    }

    private func readDoubleStatValue(_ value: NSObject?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private func readIntStatValue(_ value: NSObject?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String, let intValue = Int(string) {
            return intValue
        }
        return nil
    }

    private func fallbackVideoDimension(_ value: CGFloat) -> Int? {
        guard value.isFinite, value > 0 else {
            return nil
        }
        return Int(value.rounded())
    }

    private func logReceiverAudioStats(_ report: RTCStatisticsReport) {
        guard debugLoggingEnabled else { return }

        let codecById = report.statistics.reduce(into: [String: RTCStatistics]()) { result, pair in
            let stat = pair.value
            if stat.type == "codec" {
                result[pair.key] = stat
            }
        }

        var entries: [[String: Any]] = []
        for (_, stat) in report.statistics where stat.type == "inbound-rtp" {
            let values = stat.values
            let kind = (values["kind"] as? String) ?? (values["mediaType"] as? String)
            if kind != "audio" {
                continue
            }

            let codecId = values["codecId"] as? String
            let codecValues = codecId.flatMap { codecById[$0]?.values }

            entries.append([
                "id": stat.id,
                "bytesReceived": values["bytesReceived"] ?? NSNull(),
                "packetsReceived": values["packetsReceived"] ?? NSNull(),
                "packetsLost": values["packetsLost"] ?? NSNull(),
                "jitter": values["jitter"] ?? NSNull(),
                "totalAudioEnergy": values["totalAudioEnergy"] ?? NSNull(),
                "totalSamplesDuration": values["totalSamplesDuration"] ?? NSNull(),
                "codecId": codecId ?? NSNull(),
                "codecMimeType": codecValues?["mimeType"] ?? NSNull(),
                "codecChannels": codecValues?["channels"] ?? NSNull(),
                "codecSdpFmtpLine": codecValues?["sdpFmtpLine"] ?? NSNull(),
            ])
        }

        if !entries.isEmpty {
            log("receiver.stats.audio payload=\(serializeForLog(["reports": entries]))")
        }
    }
}

extension NativeLibWebRTCReceiver: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        _ = peerConnection
        _ = stateChanged
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for videoTrack in stream.videoTracks {
                self.attachRemoteVideoTrack(videoTrack)
            }
            for audioTrack in stream.audioTracks {
                self.attachRemoteAudioTrack(audioTrack)
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        _ = peerConnection
        _ = stream
    }

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        _ = peerConnection
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        _ = peerConnection
        _ = newState
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        _ = peerConnection
        _ = newState
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.peerConnection === peerConnection else { return }
            self.handleGeneratedLocalCandidate(candidate)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        _ = peerConnection
        _ = candidates
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        _ = peerConnection
        _ = dataChannel
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.peerConnection === peerConnection else { return }
            self.handleConnectionStateChange(newState)
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.peerConnection === peerConnection else { return }

            if let videoTrack = rtpReceiver.track as? RTCVideoTrack {
                self.attachRemoteVideoTrack(videoTrack)
                return
            }
            if let audioTrack = rtpReceiver.track as? RTCAudioTrack {
                self.attachRemoteAudioTrack(audioTrack)
                self.logCurrentAudioReceiverParameters(context: "didAddReceiver.audioTrack")
            }

            for stream in mediaStreams {
                for videoTrack in stream.videoTracks {
                    self.attachRemoteVideoTrack(videoTrack)
                }
                for audioTrack in stream.audioTracks {
                    self.attachRemoteAudioTrack(audioTrack)
                }
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
        _ = peerConnection
        _ = rtpReceiver
    }
}

extension NativeLibWebRTCReceiver: RTCVideoViewDelegate {
    nonisolated func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        _ = videoView
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard size.width > 0, size.height > 0 else { return }
            self.lastReportedVideoSize = size
            self.pipController.updateExpectedVideoSize(size)
            self.pipController.requestStart()
            self.onStreamingChanged?(true)
        }
    }
}
#endif
