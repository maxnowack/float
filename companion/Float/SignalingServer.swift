import Combine
import Foundation
import Network
import OSLog
import ServiceManagement

private let diagnosticsOverlayDefaultsKey = "Float.diagnosticsOverlayEnabled"

private func loadDiagnosticsOverlayEnabled() -> Bool {
    UserDefaults.standard.object(forKey: diagnosticsOverlayDefaultsKey) as? Bool ?? true
}

private final class HandshakeRegistry: @unchecked Sendable {
    private struct Record {
        let origin: String
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]

    func record(token: String, origin: String, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(now: now)
        guard records.count < ProtocolLimits.maximumConnections,
              records[token] == nil
        else {
            return false
        }
        records[token] = Record(
            origin: origin,
            expiresAt: now.addingTimeInterval(ProtocolLimits.handshakeRecordTimeout)
        )
        return true
    }

    func consume(token: String, now: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        purgeExpired(now: now)
        return records.removeValue(forKey: token)?.origin
    }

    private func purgeExpired(now: Date) {
        records = records.filter { $0.value.expiresAt >= now }
    }
}

@MainActor
final class SignalingServer: ObservableObject {
    private static let launchAtLoginUnavailableMessage =
        "Start at Login is not supported on this macOS version."

    enum ServerState {
        case starting
        case waiting
        case connected
        case error(String)
    }

    private enum StatusIconState {
        case extensionNotConnected
        case extensionConnectedNoVideo
        case extensionConnectedOneVideo
        case extensionConnectedMultipleVideos
        case extensionConnectedStreamingActive
        case error

        var symbolName: String {
            switch self {
            case .extensionNotConnected:
                return "rectangle.slash"
            case .extensionConnectedNoVideo:
                return "rectangle"
            case .extensionConnectedOneVideo, .extensionConnectedMultipleVideos:
                return "pip"
            case .extensionConnectedStreamingActive:
                return "pip.fill"
            case .error:
                return "exclamationmark.circle.fill"
            }
        }
    }

    private enum VideoQualityProfileHint: String {
        case high
        case balanced
        case performance
    }

    private struct LastVideoQualityHint {
        let targetID: String
        let profile: VideoQualityProfileHint
        let pipWidth: Int
        let pipHeight: Int
    }

    private final class ClientContext {
        let origin: String
        let credentialGeneration: UInt64
        let authentication: AuthenticationSession
        var authenticationTimeoutTask: Task<Void, Never>?
        var protocolState = ClientProtocolStateMachine()
        var tabs: [TabState] = []
        var helloVersion: Int?
        var remoteICECandidateCount = BoundedCounter(
            limit: ProtocolLimits.maximumPendingICECandidates
        )
        var stateRateLimiter = StateUpdateRateLimiter(now: Date())
        var isSendingError = false

        init(
            origin: String,
            credentialGeneration: UInt64,
            authentication: AuthenticationSession
        ) {
            self.origin = origin
            self.credentialGeneration = credentialGeneration
            self.authentication = authentication
        }
    }

    static let port: UInt16 = 17891
    private static let autoStartBackgroundDefaultsKey =
        "Float.autoStartBackgroundEnabled"
    private static let autoStopForegroundDefaultsKey =
        "Float.autoStopForegroundEnabled"

    @Published private(set) var serverState: ServerState = .starting
    @Published private(set) var tabs: [TabState] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastHelloVersion: Int?
    @Published private(set) var isStreaming = false
    @Published private(set) var lastExtensionDebugLog: String?
    @Published private(set) var autoStartBackgroundEnabled = false
    @Published private(set) var autoStopForegroundEnabled = true
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var diagnosticsOverlayEnabled = true

    struct VideoSource: Identifiable {
        fileprivate let clientID: UUID
        let tabId: Int
        let videoId: String
        let tabTitle: String
        let domain: String
        let resolution: String?
        let browserName: String

        var id: String { "\(clientID.uuidString):\(tabId):\(videoId)" }
        var displayTitle: String {
            "\(tabTitle) (\(domain)) — \(browserName)"
        }
    }

    var hasDetectedVideos: Bool {
        !availableSources.isEmpty
    }

    var availableSources: [VideoSource] {
        authenticatedClients.clients.flatMap { clientID -> [VideoSource] in
            guard let context = clientContexts[clientID] else { return [] }
            let browserName = Self.browserName(for: context.origin)
            return context.tabs.flatMap { tab in
                tab.videos.map { video in
                    VideoSource(
                        clientID: clientID,
                        tabId: tab.tabId,
                        videoId: video.videoId,
                        tabTitle: tab.title,
                        domain: tab.domain,
                        resolution: video.resolution,
                        browserName: browserName
                    )
                }
            }
        }
    }

    private var listener: NWListener?
    private var clients: [UUID: WebSocketClient] = [:]
    private var clientContexts: [UUID: ClientContext] = [:]
    private var authenticatedClients = AuthenticatedClientRegistry<UUID>()
    private let queue = DispatchQueue(label: "de.unsou.Float.signaling")
    private let handshakeRegistry = HandshakeRegistry()
    private let webRTCReceiver: WebRTCReceiver
    private let credentialManager: PairingCredentialManager
    private let randomBytes: (Int) throws -> Data
    private var credentialGeneration: UInt64 = 0
    private var activeClientID: UUID?
    private var activeTabId: Int?
    private var activeVideoId: String?
    private var activeGeneration: Int?
    private var mediaOperationID: UInt64 = 0
    private var offerTask: Task<Void, Never>?
    private var stopRequestInFlight = false
    private var latestPiPRenderSize: CGSize?
    private var lastVideoQualityHint: LastVideoQualityHint?

    init(
        credentialStore: PairingCredentialStore = KeychainPairingCredentialStore(),
        randomBytes: @escaping (Int) throws -> Data = SecureRandom.bytes
    ) {
        credentialManager = PairingCredentialManager(
            store: credentialStore,
            randomBytes: randomBytes
        )
        self.randomBytes = randomBytes
        autoStartBackgroundEnabled =
            UserDefaults.standard.object(
                forKey: Self.autoStartBackgroundDefaultsKey
            ) as? Bool ?? false
        autoStopForegroundEnabled =
            UserDefaults.standard.object(
                forKey: Self.autoStopForegroundDefaultsKey
            ) as? Bool ?? true
        launchAtLoginEnabled = Self.resolveLaunchAtLoginEnabled()
        diagnosticsOverlayEnabled = loadDiagnosticsOverlayEnabled()

        var receiver = makeWebRTCReceiver()
        webRTCReceiver = receiver
        receiver.setDiagnosticsOverlayEnabled(diagnosticsOverlayEnabled)
        receiver.onLocalIceCandidate = { [weak self] candidate in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard candidate.tabId == self.activeTabId,
                      candidate.videoId == self.activeVideoId,
                      candidate.generation == self.activeGeneration
                else {
                    return
                }
                self.sendEncodableToActiveClient(
                    OutgoingIceMessage(
                        type: FloatProtocol.MessageType.ice,
                        tabId: candidate.tabId,
                        videoId: candidate.videoId,
                        generation: candidate.generation,
                        candidate: candidate.candidate,
                        sdpMid: candidate.sdpMid,
                        sdpMLineIndex: candidate.sdpMLineIndex
                    )
                )
            }
        }
        receiver.onStreamingChanged = { [weak self] source, isStreaming in
            Task { @MainActor [weak self] in
                self?.handleReceiverStreamingChanged(
                    source: source,
                    isStreaming: isStreaming
                )
            }
        }
        receiver.onPictureInPictureClosed = { [weak self] tabId, videoId, generation in
            Task { @MainActor [weak self] in
                self?.handlePictureInPictureClosed(
                    tabId: tabId,
                    videoId: videoId,
                    generation: generation
                )
            }
        }
        receiver.onPlaybackCommand = { [weak self] source, isPlaying in
            Task { @MainActor [weak self] in
                self?.requestPlaybackChange(
                    source: source,
                    isPlaying: isPlaying
                )
            }
        }
        receiver.onSeekCommand = { [weak self] source, intervalSeconds in
            Task { @MainActor [weak self] in
                self?.requestSeekChange(
                    source: source,
                    intervalSeconds: intervalSeconds
                )
            }
        }
        receiver.onPiPRenderSizeChanged = { [weak self] source, size in
            Task { @MainActor [weak self] in
                self?.handlePiPRenderSizeChanged(
                    source: source,
                    size: size
                )
            }
        }
        start()
    }

    deinit {
        let clientsToClose = Array(clients.values)
        listener?.cancel()
        clientsToClose.forEach {
            $0.close(code: .protocolCode(.goingAway), reason: "Float stopped")
        }
    }

    func iconName() -> String {
        statusIconState().symbolName
    }

    func stateDescription() -> String {
        switch serverState {
        case .starting:
            return "Starting"
        case .waiting:
            return "Waiting for paired extension"
        case .connected where isStreaming:
            return "Streaming in PiP"
        case .connected:
            return hasDetectedVideos ? "Videos detected" : "Paired extension connected"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    func pairingCredentialForDisplay() throws -> String {
        try credentialManager.displayCredential()
    }

    func rotatePairingCredential() throws -> String {
        let credential = try credentialManager.rotate()
        credentialGeneration &+= 1
        disconnectAllClients(reason: "Pairing credential rotated")
        clearClientOwnedState(stopReceiver: true)
        return Base64URL.encode(credential)
    }

    func requestStart(_ source: VideoSource) {
        guard authenticatedClients.contains(source.clientID) else {
            lastError = "No authenticated extension connection available"
            return
        }
        let previousClientID = activeClientID
        clearActiveMediaState(stopReceiver: true)
        if let previousClientID {
            sendVersionedPayload([
                "type": FloatProtocol.MessageType.stop,
            ], to: previousClientID)
        }
        stopRequestInFlight = false
        activeClientID = source.clientID
        activeTabId = source.tabId
        activeVideoId = source.videoId
        activeGeneration = nil
        lastVideoQualityHint = nil
        webRTCReceiver.updatePlaybackState(isPlaying: true)
        sendVersionedPayload([
            "type": FloatProtocol.MessageType.start,
            "tabId": source.tabId,
            "videoId": source.videoId,
        ], to: source.clientID)
        sendVideoQualityHintIfNeeded(force: true)
    }

    func requestStop() {
        requestStop(pauseSource: false)
    }

    private func requestStop(pauseSource: Bool) {
        guard !stopRequestInFlight else { return }
        let targetClientID = activeClientID
        let targetTabId = activeTabId
        let targetVideoId = activeVideoId
        let targetGeneration = activeGeneration
        stopRequestInFlight = true
        if let targetClientID {
            var payload: [String: Any] = [
                "type": FloatProtocol.MessageType.stop,
            ]
            if pauseSource,
               let targetTabId,
               let targetVideoId,
               let targetGeneration
            {
                payload["pauseSource"] = true
                payload["tabId"] = targetTabId
                payload["videoId"] = targetVideoId
                payload["generation"] = targetGeneration
            }
            sendVersionedPayload(payload, to: targetClientID)
        }
        clearActiveMediaState(stopReceiver: true)
    }

    func setAutoStartBackgroundEnabled(_ enabled: Bool) {
        guard autoStartBackgroundEnabled != enabled else { return }
        autoStartBackgroundEnabled = enabled
        UserDefaults.standard.set(
            enabled,
            forKey: Self.autoStartBackgroundDefaultsKey
        )
        sendAutoStartBackgroundSetting()
    }

    func setAutoStopForegroundEnabled(_ enabled: Bool) {
        guard autoStopForegroundEnabled != enabled else { return }
        autoStopForegroundEnabled = enabled
        UserDefaults.standard.set(
            enabled,
            forKey: Self.autoStopForegroundDefaultsKey
        )
        sendAutoStopForegroundSetting()
    }

    func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = Self.resolveLaunchAtLoginEnabled()
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            launchAtLoginEnabled = false
            lastError = Self.launchAtLoginUnavailableMessage
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            lastError = "Failed to update Start at Login: \(error.localizedDescription)"
        }
    }

    func setDiagnosticsOverlayEnabled(_ enabled: Bool) {
        guard diagnosticsOverlayEnabled != enabled else { return }
        diagnosticsOverlayEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: diagnosticsOverlayDefaultsKey)
        webRTCReceiver.setDiagnosticsOverlayEnabled(enabled)
    }

    func isActiveSource(_ source: VideoSource) -> Bool {
        source.clientID == activeClientID
            && source.tabId == activeTabId
            && source.videoId == activeVideoId
    }

    private func statusIconState() -> StatusIconState {
        if case .error = serverState {
            return .error
        }
        if isStreaming {
            return .extensionConnectedStreamingActive
        }
        guard !authenticatedClients.isEmpty else {
            return .extensionNotConnected
        }
        switch availableSources.count {
        case 0:
            return .extensionConnectedNoVideo
        case 1:
            return .extensionConnectedOneVideo
        default:
            return .extensionConnectedMultipleVideos
        }
    }

    private static func resolveLaunchAtLoginEnabled() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    private static func browserName(for origin: String) -> String {
        if origin.hasPrefix("chrome-extension://") {
            return "Chrome"
        }
        if origin.hasPrefix("moz-extension://") {
            return "Firefox"
        }
        return "Browser"
    }

    private func start() {
        serverState = .starting
        do {
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            wsOptions.maximumMessageSize = ProtocolLimits.maximumWebSocketMessageBytes
            let registry = handshakeRegistry
            wsOptions.setClientRequestHandler(queue) { subprotocols, headers in
                let originValues = headers
                    .filter { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }
                    .map(\.value)
                guard originValues.count == 1,
                      let validatedOrigin = ExtensionOrigin.validate(originValues[0])
                else {
                    return NWProtocolWebSocket.Response(
                        status: .reject,
                        subprotocol: nil
                    )
                }

                let tokens = subprotocols.filter(WebSocketHandshakeToken.validate)
                guard subprotocols.count == 1,
                      tokens.count == 1,
                      registry.record(
                          token: tokens[0],
                          origin: validatedOrigin.value,
                          now: Date()
                      )
                else {
                    return NWProtocolWebSocket.Response(
                        status: .reject,
                        subprotocol: nil
                    )
                }
                return NWProtocolWebSocket.Response(
                    status: .accept,
                    subprotocol: tokens[0]
                )
            }

            let parameters = NWParameters(
                tls: nil,
                tcp: NWProtocolTCP.Options()
            )
            parameters.defaultProtocolStack.applicationProtocols.insert(
                wsOptions,
                at: 0
            )
            let port = NWEndpoint.Port(rawValue: Self.port)!
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: port
            )

            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.serverState =
                            self.authenticatedClients.isEmpty ? .waiting : .connected
                        FloatLog.signaling.notice(
                            "Signaling listener ready on 127.0.0.1:17891"
                        )
                    case .failed(let error):
                        let message =
                            "Float could not bind 127.0.0.1:17891: \(error.localizedDescription)"
                        self.lastError = message
                        self.serverState = .error(message)
                        FloatLog.signaling.error(
                            "\(message, privacy: .private(mask: .hash))"
                        )
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptFromListener(connection: connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            let message =
                "Float could not bind 127.0.0.1:17891: \(error.localizedDescription)"
            lastError = message
            serverState = .error(message)
        }
    }

    nonisolated private func acceptFromListener(connection: NWConnection) {
        Task { @MainActor [weak self] in
            self?.accept(connection: connection)
        }
    }

    private func accept(connection: NWConnection) {
        guard Self.isIPv4Loopback(endpoint: connection.endpoint) else {
            FloatLog.signaling.error("Rejected non-loopback remote endpoint")
            connection.cancel()
            return
        }
        guard ConnectionLimitPolicy.permits(
            totalConnections: clients.count,
            unauthenticatedConnections: unauthenticatedClientCount
        )
        else {
            FloatLog.signaling.warning("Rejected connection due to connection limit")
            connection.cancel()
            return
        }

        let clientID = UUID()
        let client = WebSocketClient(
            connection: connection,
            queue: queue,
            connectionTimeout: ProtocolLimits.connectionTimeout,
            onReady: { [weak self] selectedSubprotocol in
                Task { @MainActor [weak self] in
                    self?.clientBecameReady(
                        clientID: clientID,
                        selectedSubprotocol: selectedSubprotocol
                    )
                }
            },
            onTextMessage: { [weak self] data, processingCompleted in
                Task { @MainActor [weak self] in
                    defer { processingCompleted() }
                    await self?.handleMessageData(data, from: clientID)
                }
            },
            onClose: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.disconnect(clientID: clientID)
                }
            }
        )
        clients[clientID] = client
        client.start()
    }

    private static func isIPv4Loopback(endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        guard case .ipv4(let address) = host else { return false }
        return address.rawValue.first == 127
    }

    private var unauthenticatedClientCount: Int {
        clients.keys.reduce(into: 0) { count, clientID in
            if !authenticatedClients.contains(clientID) {
                count += 1
            }
        }
    }

    private func clientBecameReady(
        clientID: UUID,
        selectedSubprotocol: String?
    ) {
        guard let client = clients[clientID],
              let selectedSubprotocol,
              let origin = handshakeRegistry.consume(
                  token: selectedSubprotocol,
                  now: Date()
              )
        else {
            closeClient(
                clientID,
                code: .protocolCode(.policyViolation),
                reason: "Unauthorized WebSocket handshake"
            )
            return
        }

        do {
            let nonce = Base64URL.encode(
                try randomBytes(FloatAuthentication.nonceByteCount)
            )
            guard Base64URL.decode(nonce)?.count == FloatAuthentication.nonceByteCount else {
                throw PairingCredentialStoreError.invalidCredentialLength
            }
            _ = try credentialManager.credential()
            let authentication = AuthenticationSession(
                origin: origin,
                nonce: nonce,
                issuedAt: Date()
            )
            let context = ClientContext(
                origin: origin,
                credentialGeneration: credentialGeneration,
                authentication: authentication
            )
            clientContexts[clientID] = context
            client.markHandshakeAuthenticated()
            context.authenticationTimeoutTask = Task { @MainActor [weak self, weak context] in
                try? await Task.sleep(
                    for: .seconds(ProtocolLimits.authenticationTimeout)
                )
                guard let self, let context,
                      context.authentication.state == .challenged
                else {
                    return
                }
                self.closeClient(
                    clientID,
                    code: .protocolCode(.policyViolation),
                    reason: "Authentication timed out"
                )
            }
            sendEncodable(
                AuthenticationChallengeMessage(origin: origin, nonce: nonce),
                to: clientID
            )
        } catch {
            let message = "Pairing credential unavailable: \(error.localizedDescription)"
            lastError = message
            serverState = .error(message)
            closeClient(
                clientID,
                code: .protocolCode(.internalServerError),
                reason: "Credential unavailable"
            )
        }
    }

    private func handleMessageData(_ data: Data, from clientID: UUID) async {
        guard data.count <= ProtocolLimits.maximumWebSocketMessageBytes else {
            closeClient(
                clientID,
                code: .protocolCode(.messageTooBig),
                reason: "Message too large"
            )
            return
        }
        guard let context = clientContexts[clientID],
              context.credentialGeneration == credentialGeneration
        else {
            closeClient(
                clientID,
                code: .protocolCode(.policyViolation),
                reason: "Handshake not authorized"
            )
            return
        }

        do {
            let envelope = try ProtocolValidator.decode(
                ProtocolEnvelope.self,
                from: data
            )
            if context.authentication.state != .authenticated {
                try handlePreAuthenticationMessage(
                    data,
                    envelope: envelope,
                    clientID: clientID,
                    context: context
                )
                return
            }
            guard authenticatedClients.contains(clientID) else {
                throw ProtocolValidationError.invalidState("client revoked")
            }
            try await handleAuthenticatedMessage(
                data,
                envelope: envelope,
                clientID: clientID,
                context: context
            )
        } catch let error as ProtocolValidationError {
            rejectClient(clientID, error: error)
        } catch {
            rejectClient(clientID, error: .malformedJSON)
        }
    }

    private func handlePreAuthenticationMessage(
        _ data: Data,
        envelope: ProtocolEnvelope,
        clientID: UUID,
        context: ClientContext
    ) throws {
        guard envelope.type == FloatProtocol.MessageType.authResponse else {
            throw ProtocolValidationError.invalidState("authentication required")
        }
        let response = try ProtocolValidator.decode(
            AuthenticationResponseMessage.self,
            from: data
        )
        let decision = context.authentication.authenticate(
            version: response.version,
            encodedProof: response.proof,
            secret: try credentialManager.credential(),
            now: Date()
        )

        switch decision {
        case .authenticated:
            context.authenticationTimeoutTask?.cancel()
            try context.protocolState.authenticationSucceeded()
            let staleClientID = authenticatedClients.insert(
                clientID,
                origin: context.origin
            )
            if let staleClientID {
                invalidateClient(
                    staleClientID,
                    reason: "Replaced by a newer connection from the same extension"
                )
            }
            sendEncodable(
                AuthenticationResultMessage(authenticated: true),
                to: clientID
            )
            if let credential = try? credentialManager.displayCredential() {
                SensitivePasteboard.clearIfMatching(credential)
            }
            serverState = .connected
            lastError = nil
            FloatLog.authentication.notice(
                "Extension authenticated origin=\(context.origin, privacy: .private(mask: .hash))"
            )
        case .retry:
            return
        case .reject, .expired, .replay:
            closeClient(
                clientID,
                code: .protocolCode(.policyViolation),
                reason: "Authentication failed"
            )
        }
    }

    private func handleAuthenticatedMessage(
        _ data: Data,
        envelope: ProtocolEnvelope,
        clientID: UUID,
        context: ClientContext
    ) async throws {
        try ProtocolValidator.requireVersion(envelope.version)
        try context.protocolState.accept(messageType: envelope.type)

        switch envelope.type {
        case FloatProtocol.MessageType.hello:
            context.helloVersion = envelope.version
            refreshPublishedClientState()
            sendVersionedPayload([
                "type": FloatProtocol.MessageType.hello,
                "source": "companion",
            ], to: clientID)
            sendAutoStartBackgroundSetting(to: clientID)
            sendAutoStopForegroundSetting(to: clientID)

        case FloatProtocol.MessageType.state:
            guard context.stateRateLimiter.allow(now: Date()) else {
                throw ProtocolValidationError.rateLimitExceeded
            }
            let state = try ProtocolValidator.decode(StateMessage.self, from: data)
            try state.validate()
            context.tabs = state.tabs
            refreshPublishedClientState()
            if activeClientID == clientID {
                syncReceiverPlaybackStateFromTabs()
            }

        case FloatProtocol.MessageType.stop:
            context.remoteICECandidateCount.reset()
            context.tabs = []
            refreshPublishedClientState()
            if activeClientID == clientID {
                let shouldStopReceiver = !stopRequestInFlight
                stopRequestInFlight = false
                clearActiveMediaState(stopReceiver: shouldStopReceiver)
            }

        case FloatProtocol.MessageType.offer:
            let offer = try ProtocolValidator.decode(OfferMessage.self, from: data)
            try offer.validate()
            context.remoteICECandidateCount.reset()
            await scheduleOffer(offer, clientID: clientID)

        case FloatProtocol.MessageType.ice:
            let ice = try ProtocolValidator.decode(IceMessage.self, from: data)
            try ice.validate()
            guard clientID == activeClientID,
                  ice.tabId == activeTabId,
                  ice.videoId == activeVideoId,
                  ice.generation == activeGeneration
            else {
                throw ProtocolValidationError.invalidState("ICE target is not active")
            }
            guard context.remoteICECandidateCount.increment() else {
                throw ProtocolValidationError.limitExceeded("ICE candidates")
            }
            await handleIce(ice, clientID: clientID)

        case FloatProtocol.MessageType.error:
            let message = try ProtocolValidator.decode(ErrorMessage.self, from: data)
            try message.validate()
            lastError = message.reason ?? "Received a bounded error from the extension"
            FloatLog.signaling.error("Extension reported an error")

        case FloatProtocol.MessageType.debug:
            let message = try ProtocolValidator.decode(DebugMessage.self, from: data)
            try message.validate()
#if DEBUG
            let source = message.source ?? "extension"
            let event = message.event ?? "unknown"
            lastExtensionDebugLog = "[\(source)] \(event) \(message.payload?.redactedDescription ?? "null")"
            FloatLog.debug(
                FloatLog.signaling,
                "Extension debug \(source):\(event)"
            )
#endif

        default:
            throw ProtocolValidationError.invalidMessage("type")
        }
    }

    private func rejectClient(
        _ clientID: UUID,
        error: ProtocolValidationError
    ) {
        lastError = error.localizedDescription
        let closeCode: NWProtocolWebSocket.CloseCode =
            if case .limitExceeded = error {
                .protocolCode(.messageTooBig)
            } else {
                .protocolCode(.policyViolation)
            }
        closeClient(clientID, code: closeCode, reason: error.localizedDescription)
    }

    private func closeClient(
        _ clientID: UUID,
        code: NWProtocolWebSocket.CloseCode,
        reason: String
    ) {
        clients[clientID]?.close(code: code, reason: reason)
    }

    private func disconnect(clientID: UUID) {
        let wasAuthenticated = authenticatedClients.remove(clientID)
        let wasActive = activeClientID == clientID
        clientContexts[clientID]?.authenticationTimeoutTask?.cancel()
        clientContexts[clientID]?.protocolState.close()
        clientContexts.removeValue(forKey: clientID)
        clients.removeValue(forKey: clientID)
        if wasAuthenticated {
            refreshPublishedClientState()
        }
        if wasActive {
            clearActiveMediaState(stopReceiver: true)
        }
        updateConnectionState()
    }

    private func invalidateClient(_ clientID: UUID, reason: String) {
        let client = clients.removeValue(forKey: clientID)
        authenticatedClients.remove(clientID)
        let wasActive = activeClientID == clientID
        clientContexts[clientID]?.authenticationTimeoutTask?.cancel()
        clientContexts[clientID]?.protocolState.close()
        clientContexts.removeValue(forKey: clientID)
        if wasActive {
            clearActiveMediaState(stopReceiver: true)
        }
        refreshPublishedClientState()
        updateConnectionState()
        client?.close(code: .protocolCode(.goingAway), reason: reason)
    }

    private func disconnectAllClients(reason: String) {
        invalidateMediaOperation()
        for context in clientContexts.values {
            context.authenticationTimeoutTask?.cancel()
            context.protocolState.close()
        }
        clientContexts.removeAll()
        authenticatedClients.clear()
        let values = Array(clients.values)
        clients.removeAll()
        refreshPublishedClientState()
        updateConnectionState()
        values.forEach {
            $0.close(code: .protocolCode(.goingAway), reason: reason)
        }
    }

    private func updateConnectionState() {
        if case .error = serverState {
            return
        }
        serverState = authenticatedClients.isEmpty ? .waiting : .connected
    }

    private func clearClientOwnedState(stopReceiver: Bool) {
        for context in clientContexts.values {
            context.tabs = []
            context.helloVersion = nil
        }
        tabs = []
        lastHelloVersion = nil
        lastExtensionDebugLog = nil
        clearActiveMediaState(stopReceiver: stopReceiver)
    }

    private func refreshPublishedClientState() {
        tabs = authenticatedClients.clients.flatMap { clientID in
            clientContexts[clientID]?.tabs ?? []
        }
        lastHelloVersion = authenticatedClients.clients
            .compactMap { clientContexts[$0]?.helloVersion }
            .last
    }

    private func clearActiveMediaState(stopReceiver: Bool) {
        invalidateMediaOperation()
        isStreaming = false
        activeClientID = nil
        activeTabId = nil
        activeVideoId = nil
        activeGeneration = nil
        lastVideoQualityHint = nil
        if stopReceiver {
            webRTCReceiver.stop()
        }
    }

    private func handleReceiverStreamingChanged(
        source: WebRTCMediaSource,
        isStreaming streaming: Bool
    ) {
        guard source.matches(
            tabId: activeTabId,
            videoId: activeVideoId,
            generation: activeGeneration
        ) else {
            return
        }
        let wasStreaming = isStreaming
        isStreaming = streaming
        if streaming {
            stopRequestInFlight = false
        }
        guard wasStreaming && !streaming,
              let activeClientID,
              activeTabId != nil,
              activeVideoId != nil,
              !stopRequestInFlight
        else {
            return
        }
        self.activeClientID = nil
        activeTabId = nil
        activeVideoId = nil
        activeGeneration = nil
        invalidateMediaOperation()
        lastVideoQualityHint = nil
        stopRequestInFlight = true
        sendVersionedPayload([
            "type": FloatProtocol.MessageType.stop,
        ], to: activeClientID)
    }

    private func handlePictureInPictureClosed(
        tabId: Int,
        videoId: String,
        generation: Int
    ) {
        guard activeTabId == tabId,
              activeVideoId == videoId,
              activeGeneration == generation
        else {
            return
        }
        // The extension applies pause and teardown atomically in the source
        // frame so a fast stop cannot overtake the pause command.
        requestStop(pauseSource: true)
    }

    private func handlePiPRenderSizeChanged(
        source: WebRTCMediaSource,
        size: CGSize
    ) {
        guard source.matches(
            tabId: activeTabId,
            videoId: activeVideoId,
            generation: activeGeneration
        ),
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0
        else {
            return
        }
        latestPiPRenderSize = size
        sendVideoQualityHintIfNeeded(force: false)
    }

    private func videoQualityProfileHint(
        forPiPRenderSize size: CGSize
    ) -> VideoQualityProfileHint {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let longEdge = max(width, height)
        let area = width * height
        if longEdge >= 1_900 || area >= 1_700_000 {
            return .high
        }
        if longEdge >= 1_450 || area >= 1_000_000 {
            return .balanced
        }
        return .performance
    }

    private func sendVideoQualityHintIfNeeded(force: Bool) {
        guard let activeTabId,
              let activeVideoId,
              let size = latestPiPRenderSize
        else {
            return
        }
        let profile = videoQualityProfileHint(forPiPRenderSize: size)
        let pipWidth = Int(size.width.rounded())
        let pipHeight = Int(size.height.rounded())
        let target = "\(activeTabId):\(activeVideoId)"
        if !force,
           let lastVideoQualityHint,
           lastVideoQualityHint.targetID == target,
           lastVideoQualityHint.profile == profile,
           lastVideoQualityHint.pipWidth == pipWidth,
           lastVideoQualityHint.pipHeight == pipHeight
        {
            return
        }
        lastVideoQualityHint = LastVideoQualityHint(
            targetID: target,
            profile: profile,
            pipWidth: pipWidth,
            pipHeight: pipHeight
        )
        sendEncodableToActiveClient(
            QualityHintMessage(
                type: FloatProtocol.MessageType.qualityHint,
                tabId: activeTabId,
                videoId: activeVideoId,
                profile: profile.rawValue,
                pipWidth: pipWidth,
                pipHeight: pipHeight
            )
        )
    }

    private func requestPlaybackChange(
        source: WebRTCMediaSource,
        isPlaying: Bool
    ) {
        guard source.matches(
            tabId: activeTabId,
            videoId: activeVideoId,
            generation: activeGeneration
        ),
              let activeClientID,
              let activeTabId,
              let activeVideoId
        else {
            return
        }
        sendVersionedPayload([
            "type": FloatProtocol.MessageType.playback,
            "tabId": activeTabId,
            "videoId": activeVideoId,
            "playing": isPlaying,
        ], to: activeClientID)
    }

    private func requestSeekChange(
        source: WebRTCMediaSource,
        intervalSeconds: Double
    ) {
        guard source.matches(
            tabId: activeTabId,
            videoId: activeVideoId,
            generation: activeGeneration
        ),
              intervalSeconds.isFinite,
              let activeClientID,
              let activeTabId,
              let activeVideoId
        else {
            return
        }
        sendVersionedPayload([
            "type": FloatProtocol.MessageType.seek,
            "tabId": activeTabId,
            "videoId": activeVideoId,
            "intervalSeconds": intervalSeconds,
        ], to: activeClientID)
    }

    private func syncReceiverPlaybackStateFromTabs() {
        guard let activeClientID,
              let activeTabId,
              let activeVideoId,
              let tab = clientContexts[activeClientID]?.tabs.first(
                  where: { $0.tabId == activeTabId }
              ),
              let video = tab.videos.first(where: { $0.videoId == activeVideoId })
        else {
            return
        }
        if let playing = video.playing {
            webRTCReceiver.updatePlaybackState(isPlaying: playing)
        }
        webRTCReceiver.updatePlaybackProgress(
            elapsedSeconds: video.currentTime,
            durationSeconds: video.duration
        )
    }

    private func invalidateMediaOperation() {
        mediaOperationID &+= 1
        offerTask?.cancel()
        offerTask = nil
    }

    private func scheduleOffer(
        _ offer: OfferMessage,
        clientID: UUID
    ) async {
        if let activeClientID, activeClientID != clientID {
            sendVersionedPayload([
                "type": FloatProtocol.MessageType.stop,
            ], to: clientID)
            return
        }
        invalidateMediaOperation()
        let operationID = mediaOperationID
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.handleOffer(
                offer,
                clientID: clientID,
                operationID: operationID
            )
        }
        offerTask = task
        await task.value
        if mediaOperationID == operationID {
            offerTask = nil
        }
    }

    private func handleOffer(
        _ offer: OfferMessage,
        clientID: UUID,
        operationID: UInt64
    ) async {
        guard !Task.isCancelled,
              mediaOperationID == operationID,
              authenticatedClients.contains(clientID),
              clientContexts[clientID]?.credentialGeneration == credentialGeneration
        else {
            return
        }
        do {
            stopRequestInFlight = false
            activeClientID = clientID
            activeTabId = offer.tabId
            activeVideoId = offer.videoId
            activeGeneration = offer.generation
            lastVideoQualityHint = nil
            let lipSync = LipSyncMode(extensionOrigin: clientContexts[clientID]?.origin ?? "")
            let answerSDP = try await webRTCReceiver.handleOffer(offer, lipSync: lipSync)
            guard !Task.isCancelled,
                  mediaOperationID == operationID,
                  authenticatedClients.contains(clientID),
                  activeClientID == clientID,
                  activeTabId == offer.tabId,
                  activeVideoId == offer.videoId,
                  activeGeneration == offer.generation
            else {
                return
            }
            guard answerSDP.utf8.count <= ProtocolLimits.maximumSDPBytes else {
                throw ProtocolValidationError.limitExceeded("answer SDP")
            }
            sendEncodable(
                AnswerMessage(
                    type: FloatProtocol.MessageType.answer,
                    tabId: offer.tabId,
                    videoId: offer.videoId,
                    generation: offer.generation,
                    sdp: answerSDP
                ),
                to: clientID
            )
            sendVideoQualityHintIfNeeded(force: true)
        } catch {
            guard mediaOperationID == operationID,
                  activeClientID == clientID,
                  activeTabId == offer.tabId,
                  activeVideoId == offer.videoId,
                  activeGeneration == offer.generation
            else {
                return
            }
            lastError = "Failed to process WebRTC offer"
            FloatLog.media.error(
                "Failed to process offer: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            clearActiveMediaState(stopReceiver: true)
            sendVersionedPayload([
                "type": FloatProtocol.MessageType.error,
                "reason": "WebRTC negotiation failed",
                "tabId": offer.tabId,
                "videoId": offer.videoId,
                "generation": offer.generation,
            ], to: clientID)
            sendVersionedPayload([
                "type": FloatProtocol.MessageType.stop,
            ], to: clientID)
        }
    }

    private func handleIce(
        _ ice: IceMessage,
        clientID: UUID
    ) async {
        guard clientID == activeClientID,
              ice.tabId == activeTabId,
              ice.videoId == activeVideoId,
              ice.generation == activeGeneration
        else {
            return
        }
        do {
            try await webRTCReceiver.addRemoteIceCandidate(ice)
            guard clientID == activeClientID,
                  ice.tabId == activeTabId,
                  ice.videoId == activeVideoId,
                  ice.generation == activeGeneration
            else {
                return
            }
        } catch {
            lastError = "Failed to add an ICE candidate"
            FloatLog.media.error(
                "ICE candidate rejected: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
    }

    private func sendAutoStartBackgroundSetting(to clientID: UUID) {
        sendVersionedPayload([
            "type": FloatProtocol.MessageType.autoStartBackground,
            "enabled": autoStartBackgroundEnabled,
        ], to: clientID)
    }

    private func sendAutoStopForegroundSetting(to clientID: UUID) {
        sendVersionedPayload([
            "type": FloatProtocol.MessageType.autoStopForeground,
            "enabled": autoStopForegroundEnabled,
        ], to: clientID)
    }

    private func sendAutoStartBackgroundSetting() {
        for clientID in authenticatedClients.clients {
            sendAutoStartBackgroundSetting(to: clientID)
        }
    }

    private func sendAutoStopForegroundSetting() {
        for clientID in authenticatedClients.clients {
            sendAutoStopForegroundSetting(to: clientID)
        }
    }

    private func sendEncodableToActiveClient<T: Encodable>(_ value: T) {
        guard let activeClientID else {
            lastError = "No authenticated extension connection available"
            return
        }
        sendEncodable(value, to: activeClientID)
    }

    private func sendVersionedPayload(
        _ payload: [String: Any],
        to clientID: UUID
    ) {
        guard let client = clients[clientID] else { return }
        do {
            let data = try ProtocolMessageEncoder.encodeVersionedPayload(payload)
            client.send(data: data)
        } catch {
            lastError = "Failed to encode an outbound protocol message"
            FloatLog.signaling.error("Failed to encode outbound message")
        }
    }

    private func sendEncodable<T: Encodable>(_ value: T, to clientID: UUID) {
        guard let client = clients[clientID] else { return }
        do {
            let data = try JSONEncoder().encode(value)
            guard data.count <= ProtocolLimits.maximumWebSocketMessageBytes else {
                throw ProtocolValidationError.limitExceeded("outbound message")
            }
            client.send(data: data)
        } catch {
            lastError = "Failed to encode an outbound protocol message"
            FloatLog.signaling.error("Failed to encode outbound message")
        }
    }
}

nonisolated private final class WebSocketClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let connectionTimeout: TimeInterval
    private let onReady: (String?) -> Void
    private let onTextMessage: (
        Data,
        @escaping @Sendable () -> Void
    ) -> Void
    private let onClose: () -> Void

    private var isClosed = false
    private var isReady = false
    private var handshakeAuthenticated = false
    private var isReceivePending = false
    private var inboundMessageGate = InboundMessageGate(
        maximumBytes: ProtocolLimits.maximumWebSocketMessageBytes
    )

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        connectionTimeout: TimeInterval,
        onReady: @escaping (String?) -> Void,
        onTextMessage: @escaping (
            Data,
            @escaping @Sendable () -> Void
        ) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.connectionTimeout = connectionTimeout
        self.onReady = onReady
        self.onTextMessage = onTextMessage
        self.onClose = onClose
    }

    func start() {
        queue.async { [self] in
            startOnQueue()
        }
    }

    func markHandshakeAuthenticated() {
        queue.async { [self] in
            handshakeAuthenticated = true
        }
    }

    func send(data: Data) {
        queue.async { [self] in
            sendOnQueue(data: data)
        }
    }

    func close(
        code: NWProtocolWebSocket.CloseCode,
        reason: String
    ) {
        queue.async { [self] in
            closeOnQueue(code: code, reason: reason)
        }
    }

    private func startOnQueue() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isReady = true
                let metadata = self.connection.metadata(
                    definition: NWProtocolWebSocket.definition
                ) as? NWProtocolWebSocket.Metadata
                self.onReady(metadata?.selectedSubprotocol)
                self.receiveNextMessage()
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + connectionTimeout) { [weak self] in
            guard let self, !self.isReady else { return }
            self.closeOnQueue(
                code: .protocolCode(.policyViolation),
                reason: "Connection timed out"
            )
        }
    }

    private func sendOnQueue(data: Data) {
        guard !isClosed, isReady, handshakeAuthenticated else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "float-v2-text",
            metadata: [metadata]
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                if error != nil {
                    self?.finish()
                }
            }
        )
    }

    private func closeOnQueue(
        code: NWProtocolWebSocket.CloseCode,
        reason: String
    ) {
        guard !isClosed else { return }
        isClosed = true
        let boundedReason = Data(reason.utf8.prefix(123))
        guard isReady else {
            connection.cancel()
            onClose()
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(
            identifier: "float-v2-close",
            metadata: [metadata]
        )
        connection.send(
            content: boundedReason,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.connection.cancel()
                self.onClose()
            }
        )
    }

    private func receiveNextMessage() {
        guard !isClosed,
              !isReceivePending,
              inboundMessageGate.retainedMessageCount == 0
        else {
            return
        }
        isReceivePending = true
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            self.isReceivePending = false
            if error != nil {
                self.finish()
                return
            }
            guard let metadata = context?.protocolMetadata(
                definition: NWProtocolWebSocket.definition
            ) as? NWProtocolWebSocket.Metadata
            else {
                self.closeOnQueue(
                    code: .protocolCode(.protocolError),
                    reason: "Missing WebSocket metadata"
                )
                return
            }
            switch metadata.opcode {
            case .close:
                self.finish()
                return
            case .text:
                guard let data else {
                    self.closeOnQueue(
                        code: .protocolCode(.invalidFramePayloadData),
                        reason: "Missing text payload"
                    )
                    return
                }
                if data.count > ProtocolLimits.maximumWebSocketMessageBytes {
                    self.closeOnQueue(
                        code: .protocolCode(.messageTooBig),
                        reason: "Message too large"
                    )
                    return
                }
                guard self.inboundMessageGate.beginProcessing(
                    byteCount: data.count
                ) else {
                    self.closeOnQueue(
                        code: .protocolCode(.messageTooBig),
                        reason: "Inbound message backlog exceeded"
                    )
                    return
                }
                self.onTextMessage(data) { [weak self] in
                    guard let self else { return }
                    self.queue.async {
                        guard !self.isClosed else { return }
                        self.inboundMessageGate.finishProcessing()
                        self.receiveNextMessage()
                    }
                }
                return
            default:
                self.closeOnQueue(
                    code: .protocolCode(.unsupportedData),
                    reason: "Only text messages are supported"
                )
                return
            }
        }
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose()
    }
}
