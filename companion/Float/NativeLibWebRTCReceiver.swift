#if canImport(WebRTC)
import AppKit
import Foundation
import WebRTC

@MainActor
final class NativeLibWebRTCReceiver: NSObject, WebRTCReceiver {
    // ========================================================================
    // AUDIO QUALITY CONFIGURATION
    // ========================================================================
    // Target audio bitrate in bits per second (bps)
    // Must match the value in extension/src/content_script.ts
    // Recommended values:
    //   - 128000 (128 kbps): Good quality, lower bandwidth
    //   - 192000 (192 kbps): Very good quality, balanced
    //   - 256000 (256 kbps): Excellent quality (default)
    //   - 510000 (510 kbps): Maximum Opus quality
    private static let opusTargetBitrateBps: Int = 256_000
    // ========================================================================
    
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
    private var missingVideoInboundProbeCount = 0
    private var hasLoggedVideoInbound = false
    private var localIceCandidateCount = 0
    private var remoteIceCandidateCount = 0
    private var lastAudioBytesReceived: Double?
    private var lastAudioStatsTime: Date?
    private var audioStatsLogCount = 0
    private var lastVideoBytesReceived: Double?
    private var lastVideoStatsTime: Date?
    private var currentConnectionState: RTCPeerConnectionState?

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
        info("offer.received tabId=\(offer.tabId) videoId=\(offer.videoId) sdpLength=\(offer.sdp.count)")
        currentTabId = offer.tabId
        currentVideoId = offer.videoId
        pipController.setPiPContentReady(false)

        pipController.stop()
        clearActivePeerConnection(notifyStreamingStopped: false)

        let connection = try makePeerConnection()
        peerConnection = connection

        do {
            let remoteOffer = RTCSessionDescription(type: .offer, sdp: offer.sdp)
            try await setRemoteDescription(remoteOffer, on: connection)
            info("offer.remoteDescription.applied")
            try await flushPendingRemoteCandidates(on: connection)

            let createdAnswer = try await createAnswer(on: connection)
            let localAnswer = RTCSessionDescription(type: .answer, sdp: createdAnswer.sdp)
            try await setLocalDescription(localAnswer, on: connection)
            info("answer.localDescription.applied sdpLength=\(createdAnswer.sdp.count)")

            try await flushPendingRemoteCandidates(on: connection)

            let outboundAnswerSdp = connection.localDescription?.sdp ?? createdAnswer.sdp
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
        let rawCandidate = ice.candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawCandidate.isEmpty else {
            log("webrtc.ice.remote.skip reason=empty-candidate")
            return
        }
        remoteIceCandidateCount += 1
        info("webrtc.ice.remote.received count=\(remoteIceCandidateCount) mid=\(ice.sdpMid ?? "nil") mline=\(ice.sdpMLineIndex ?? -1)")

        let candidate = RTCIceCandidate(
            sdp: rawCandidate,
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
        pipController.setPiPContentReady(false)
        stopStatsProbe()
        pendingRemoteCandidates.removeAll()
        lastVideoInboundSnapshot = nil
        smoothedVideoFPS = nil
        lastReportedVideoSize = .zero
        missingVideoInboundProbeCount = 0
        hasLoggedVideoInbound = false
        localIceCandidateCount = 0
        remoteIceCandidateCount = 0
        lastVideoBytesReceived = nil
        lastVideoStatsTime = nil
        currentConnectionState = nil
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
        pipController.setPiPContentReady(true)
        pipController.requestStart()
        startStatsProbeIfNeeded()
        onStreamingChanged?(true)

        info("pip.start.request reason=track-attached trackId=\(track.trackId)")
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
        currentConnectionState = newState
        info("webrtc.connectionState.changed value=\(newState.rawValue)")
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
        localIceCandidateCount += 1
        info("webrtc.ice.local.generated count=\(localIceCandidateCount) mid=\(candidate.sdpMid ?? "nil") mline=\(candidate.sdpMLineIndex)")
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

        let answer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
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
        
        // Ensure answer SDP preserves high-quality Opus parameters from offer
        let manipulatedSdp = preserveOpusQualityInAnswer(sdp: answer.sdp)
        return RTCSessionDescription(type: .answer, sdp: manipulatedSdp)
    }
    
    private func preserveOpusQualityInAnswer(sdp: String) -> String {
        let lines = sdp.components(separatedBy: "\r\n")
        var inAudioSection = false
        var opusPayloadType: String?
        
        // Find Opus payload type
        for line in lines {
            if line.hasPrefix("a=rtpmap:") && line.lowercased().contains("opus/48000") {
                if let match = line.range(of: #"^a=rtpmap:(\d+)"#, options: .regularExpression) {
                    opusPayloadType = String(line[match].dropFirst("a=rtpmap:".count).split(separator: " ")[0])
                    break
                }
            }
        }
        
        guard let payloadType = opusPayloadType else {
            return sdp
        }
        
        var resultLines: [String] = []
        var foundFmtp = false
        
        for i in 0..<lines.count {
            let line = lines[i]
            
            if line.hasPrefix("m=audio") {
                inAudioSection = true
                resultLines.append(line)
                // Add bandwidth constraints
                let bandwidthKbps = Self.opusTargetBitrateBps / 1000
                resultLines.append("b=AS:\(bandwidthKbps)")
                resultLines.append("b=TIAS:\(Self.opusTargetBitrateBps)")
                continue
            } else if line.hasPrefix("m=") {
                inAudioSection = false
            }
            
            if inAudioSection && line.hasPrefix("a=fmtp:\(payloadType)") {
                // Replace with high-quality parameters
                let params = [
                    "minptime=10",
                    "useinbandfec=1",
                    "stereo=1",
                    "sprop-stereo=1",
                    "maxaveragebitrate=\(Self.opusTargetBitrateBps)",
                    "maxplaybackrate=48000",
                ]
                resultLines.append("a=fmtp:\(payloadType) \(params.joined(separator: ";"))")
                foundFmtp = true
                info("receiver.sdp.answer.fmtpReplaced payloadType=\(payloadType) bitrate=\(Self.opusTargetBitrateBps)")
                continue
            }
            
            // Skip existing bandwidth lines in audio section
            if inAudioSection && (line.hasPrefix("b=AS:") || line.hasPrefix("b=TIAS:")) {
                continue
            }
            
            resultLines.append(line)
        }
        
        if !foundFmtp && opusPayloadType != nil {
            info("receiver.sdp.answer.warning fmtp not found in answer")
        }
        
        return resultLines.joined(separator: "\r\n")
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
            info("receiver.audio.parameters context=\(context) payload=\(serializeForLog(payload))")
        }
        
        // Also log relevant SDP audio sections
        if let remoteSdp = connection.remoteDescription?.sdp {
            logAudioSdpSection(sdp: remoteSdp, label: "\(context).offer")
        }
        if let localSdp = connection.localDescription?.sdp {
            logAudioSdpSection(sdp: localSdp, label: "\(context).answer")
        }
    }
    
    private func logAudioSdpSection(sdp: String, label: String) {
        let lines = sdp.components(separatedBy: "\r\n")
        var inAudioSection = false
        var audioLines: [String] = []
        
        for line in lines {
            if line.hasPrefix("m=audio") {
                inAudioSection = true
                audioLines.append(line)
            } else if line.hasPrefix("m=") {
                inAudioSection = false
            } else if inAudioSection {
                // Collect relevant audio lines
                if line.hasPrefix("a=rtpmap:") || line.hasPrefix("a=fmtp:") || 
                   line.hasPrefix("a=ptime:") || line.hasPrefix("a=maxptime:") {
                    audioLines.append(line)
                }
            }
        }
        
        if !audioLines.isEmpty {
            info("receiver.audio.sdp label=\(label) lines=\(audioLines.joined(separator: " | "))")
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
                self.logTransportCandidatePairStats(report)
                self.logReceiverAudioStats(report)
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
            missingVideoInboundProbeCount += 1
            if missingVideoInboundProbeCount == 1 || missingVideoInboundProbeCount % 5 == 0 {
                info("receiver.stats.video.inbound-rtp.missing probes=\(missingVideoInboundProbeCount)")
            }
            pipController.updateDiagnosticsOverlay(nil)
            return
        }
        missingVideoInboundProbeCount = 0

        let values = selectedStat.values
        let reportedFPS = readDoubleStatValue(values["framesPerSecond"])
        let framesDecoded = readDoubleStatValue(values["framesDecoded"])
        let bytesReceived = readDoubleStatValue(values["bytesReceived"])
        let packetsReceived = readDoubleStatValue(values["packetsReceived"])
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

        // Calculate bitrate
        var bitrateKbps: Double?
        if let bytesReceived, let lastBytes = lastVideoBytesReceived, let lastTime = lastVideoStatsTime {
            let deltaBytes = bytesReceived - lastBytes
            let deltaTime = now.timeIntervalSince(lastTime)
            if deltaTime > 0 && deltaBytes >= 0 {
                bitrateKbps = (deltaBytes * 8) / (deltaTime * 1000) // bits per second to kbps
            }
        }
        lastVideoBytesReceived = bytesReceived
        lastVideoStatsTime = now

        // Get RTT from candidate pair stats
        var rttMs: Double?
        for (_, stat) in report.statistics where stat.type == "candidate-pair" {
            let pairValues = stat.values
            let selected = pairValues["selected"] as? Bool
            let nominated = pairValues["nominated"] as? Bool
            let state = pairValues["state"] as? String
            if selected == true || nominated == true || state == "succeeded" {
                if let rtt = readDoubleStatValue(pairValues["currentRoundTripTime"]) {
                    rttMs = rtt * 1000 // Convert to ms
                }
                break
            }
        }

        // Build overlay text
        let fpsText = resolvedFPS.map { String(format: "%.1f fps", $0) } ?? "-- fps"
        var overlayParts: [String] = [fpsText]
        
        if let resolvedWidth, let resolvedHeight, resolvedWidth > 0, resolvedHeight > 0 {
            overlayParts.append("\(resolvedWidth)×\(resolvedHeight)")
        }
        
        if let bitrateKbps, bitrateKbps > 0 {
            if bitrateKbps >= 1000 {
                overlayParts.append(String(format: "%.1f Mbps", bitrateKbps / 1000))
            } else {
                overlayParts.append(String(format: "%.0f kbps", bitrateKbps))
            }
        }
        
        if let rttMs {
            overlayParts.append(String(format: "%.0f ms", rttMs))
        }
        
        if let state = currentConnectionState {
            let stateText: String
            switch state {
            case .new: stateText = "new"
            case .connecting: stateText = "connecting"
            case .connected: stateText = "connected"
            case .disconnected: stateText = "disconnected"
            case .failed: stateText = "failed"
            case .closed: stateText = "closed"
            @unknown default: stateText = "unknown"
            }
            if state != .connected {
                overlayParts.append(stateText)
            }
        }
        
        let overlayText = overlayParts.joined(separator: " | ")
        pipController.updateDiagnosticsOverlay(overlayText)

        if debugLoggingEnabled {
            let fpsValue = resolvedFPS.map { String(format: "%.2f", $0) } ?? "null"
            let widthValue = resolvedWidth.map(String.init) ?? "null"
            let heightValue = resolvedHeight.map(String.init) ?? "null"
            log(
                "receiver.stats.video fps=\(fpsValue) width=\(widthValue) height=\(heightValue)"
            )
        }

        if !hasLoggedVideoInbound {
            hasLoggedVideoInbound = true
            info("receiver.stats.video.inbound-rtp.detected")
        }
        let decodedValue = framesDecoded.map { String(format: "%.0f", $0) } ?? "null"
        let bytesValue = bytesReceived.map { String(format: "%.0f", $0) } ?? "null"
        let packetsValue = packetsReceived.map { String(format: "%.0f", $0) } ?? "null"
        let fpsValue = resolvedFPS.map { String(format: "%.2f", $0) } ?? "null"
        let widthValue = resolvedWidth.map(String.init) ?? "null"
        let heightValue = resolvedHeight.map(String.init) ?? "null"
        info(
            "receiver.stats.video inbound decoded=\(decodedValue) bytes=\(bytesValue) packets=\(packetsValue) fps=\(fpsValue) width=\(widthValue) height=\(heightValue)"
        )
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
            let bytesReceived = readDoubleStatValue(values["bytesReceived"])
            
            // Calculate bitrate
            var bitrateKbps: Double?
            let now = Date()
            if let bytesReceived = bytesReceived,
               let lastBytes = lastAudioBytesReceived,
               let lastTime = lastAudioStatsTime {
                let bytesDiff = bytesReceived - lastBytes
                let timeDiff = now.timeIntervalSince(lastTime)
                if timeDiff > 0 {
                    bitrateKbps = (bytesDiff * 8) / (timeDiff * 1000) // Convert to kbps
                }
            }
            lastAudioBytesReceived = bytesReceived
            lastAudioStatsTime = now

            var entry: [String: Any] = [
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
                "codecClockRate": codecValues?["clockRate"] ?? NSNull(),
                "codecSdpFmtpLine": codecValues?["sdpFmtpLine"] ?? NSNull(),
            ]
            
            if let bitrateKbps = bitrateKbps {
                entry["bitrateKbps"] = String(format: "%.1f", bitrateKbps)
            }
            
            entries.append(entry)
        }

        if !entries.isEmpty {
            // Log first 10 times always, then only if debug enabled
            audioStatsLogCount += 1
            if audioStatsLogCount <= 10 || debugLoggingEnabled {
                info("receiver.stats.audio count=\(audioStatsLogCount) payload=\(serializeForLog(["reports": entries]))")
            }
        }
    }

    private func info(_ message: String) {
        print("[Float NativeRTC] \(message)")
    }

    private func logTransportCandidatePairStats(_ report: RTCStatisticsReport) {
        var selectedPair: RTCStatistics?
        for (_, stat) in report.statistics where stat.type == "candidate-pair" {
            let selected = stat.values["selected"] as? Bool
            let nominated = stat.values["nominated"] as? Bool
            let state = stat.values["state"] as? String
            if selected == true || nominated == true || state == "succeeded" {
                selectedPair = stat
                break
            }
        }

        guard let selectedPair else {
            info("receiver.stats.transport candidatePair=missing")
            return
        }

        let values = selectedPair.values
        let state = values["state"] as? String ?? "unknown"
        let nominated = (values["nominated"] as? Bool) == true
        let selected = (values["selected"] as? Bool) == true
        let writable = (values["writable"] as? Bool) == true
        let readable = (values["readable"] as? Bool) == true
        let bytesReceived = readDoubleStatValue(values["bytesReceived"]).map { String(format: "%.0f", $0) } ?? "null"
        let bytesSent = readDoubleStatValue(values["bytesSent"]).map { String(format: "%.0f", $0) } ?? "null"
        let currentRtt = readDoubleStatValue(values["currentRoundTripTime"]).map { String(format: "%.4f", $0) } ?? "null"
        info("receiver.stats.transport state=\(state) selected=\(selected) nominated=\(nominated) writable=\(writable) readable=\(readable) bytesRx=\(bytesReceived) bytesTx=\(bytesSent) rtt=\(currentRtt)")
    }
}

extension NativeLibWebRTCReceiver: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        _ = peerConnection
        Task { @MainActor [weak self] in
            self?.info("webrtc.signalingState.changed value=\(stateChanged.rawValue)")
        }
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
        Task { @MainActor [weak self] in
            self?.info("webrtc.iceConnectionState.changed value=\(newState.rawValue)")
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        _ = peerConnection
        Task { @MainActor [weak self] in
            self?.info("webrtc.iceGatheringState.changed value=\(newState.rawValue)")
        }
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
            self.pipController.setPiPContentReady(true)
            self.pipController.requestStart()
            self.onStreamingChanged?(true)
        }
    }
}
#endif
