import Combine
import Foundation
import Network

private let protocolDebugLoggingEnabled = true

@MainActor
final class SignalingServer: ObservableObject {
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
                return "cable.connector.slash"
            case .extensionConnectedNoVideo:
                return "pip.remove"
            case .extensionConnectedOneVideo:
                return "pip"
            case .extensionConnectedMultipleVideos:
                return "pip"
            case .extensionConnectedStreamingActive:
                return "pip.fill"
            case .error:
                return "exclamationmark.circle.fill"
            }
        }
    }

    static let port: UInt16 = 17891

    @Published private(set) var serverState: ServerState = .starting
    @Published private(set) var tabs: [TabState] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastHelloVersion: Int?
    @Published private(set) var isStreaming = false
    @Published private(set) var lastExtensionDebugLog: String?

    struct VideoSource: Identifiable {
        let tabId: Int
        let videoId: String
        let tabTitle: String
        let domain: String
        let resolution: String?

        var id: String { "\(tabId):\(videoId)" }
        var displayTitle: String {
            "\(tabTitle) (\(domain))"
        }
    }

    var hasDetectedVideos: Bool {
        tabs.contains { !$0.videos.isEmpty }
    }

    var availableSources: [VideoSource] {
        tabs.flatMap { tab in
            tab.videos.map { video in
                VideoSource(
                    tabId: tab.tabId,
                    videoId: video.videoId,
                    tabTitle: tab.title,
                    domain: tab.domain,
                    resolution: video.resolution
                )
            }
        }
    }

    private var listener: NWListener?
    private var clients: [UUID: WebSocketClient] = [:]
    private let queue = DispatchQueue(label: "com.float.signaling")
    private let webRTCReceiver: WebRTCReceiver
    private var activeTabId: Int?
    private var activeVideoId: String?

    init() {
        var receiver = makeWebRTCReceiver()
        self.webRTCReceiver = receiver
        receiver.onLocalIceCandidate = { [weak self] candidate in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let payload = OutgoingIceMessage(
                    type: FloatProtocol.MessageType.ice,
                    tabId: candidate.tabId,
                    videoId: candidate.videoId,
                    candidate: candidate.candidate,
                    sdpMid: candidate.sdpMid,
                    sdpMLineIndex: candidate.sdpMLineIndex
                )
                self.sendToAnyClientEncodable(payload)
            }
        }
        receiver.onStreamingChanged = { [weak self] isStreaming in
            Task { @MainActor [weak self] in
                if protocolDebugLoggingEnabled {
                    print("[Float Signal] receiver.onStreamingChanged value=\(isStreaming)")
                }
                self?.isStreaming = isStreaming
            }
        }
        receiver.onPlaybackCommand = { [weak self] isPlaying in
            Task { @MainActor [weak self] in
                self?.requestPlaybackChange(isPlaying: isPlaying)
            }
        }
        receiver.onSeekCommand = { [weak self] intervalSeconds in
            Task { @MainActor [weak self] in
                self?.requestSeekChange(intervalSeconds: intervalSeconds)
            }
        }
        start()
    }

    deinit {
        let clientsToClose = Array(clients.values)
        listener?.cancel()
        DispatchQueue.main.async {
            clientsToClose.forEach { $0.close() }
        }
    }

    func iconName() -> String {
        statusIconState().symbolName
    }

    private func statusIconState() -> StatusIconState {
        if case .error = serverState {
            return .error
        }
        if isStreaming {
            return .extensionConnectedStreamingActive
        }

        switch serverState {
        case .starting, .waiting:
            return .extensionNotConnected
        case .connected:
            switch availableSources.count {
            case 0:
                return .extensionConnectedNoVideo
            case 1:
                return .extensionConnectedOneVideo
            default:
                return .extensionConnectedMultipleVideos
            }
        case .error:
            return .error
        }
    }

    func stateDescription() -> String {
        switch serverState {
        case .starting:
            return "Starting"
        case .waiting:
            return "Waiting for extension"
        case .connected where isStreaming:
            return "Streaming in PiP"
        case .connected:
            return hasDetectedVideos ? "Videos detected" : "Connected"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    func requestStart(tabId: Int, videoId: String) {
        activeTabId = tabId
        activeVideoId = videoId
        webRTCReceiver.updatePlaybackState(isPlaying: true)
        let payload: [String: Any] = [
            "type": FloatProtocol.MessageType.start,
            "tabId": tabId,
            "videoId": videoId,
        ]

        sendToAnyClient(payload)
    }

    func requestStop() {
        if protocolDebugLoggingEnabled {
            print("[Float Signal] requestStop called")
        }
        webRTCReceiver.stop()
        isStreaming = false
        activeTabId = nil
        activeVideoId = nil
        sendToAnyClient(["type": FloatProtocol.MessageType.stop])
    }

    func isActiveSource(_ source: VideoSource) -> Bool {
        source.tabId == activeTabId && source.videoId == activeVideoId
    }

    private func start() {
        serverState = .starting

        do {
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            let tcpOptions = NWProtocolTCP.Options()
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            parameters.allowLocalEndpointReuse = true
            let port = NWEndpoint.Port(rawValue: Self.port) ?? .any
            let listener = try NWListener(using: parameters, on: port)

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.serverState = self.clients.isEmpty ? .waiting : .connected
                        self.log("Signaling server listening on ws://127.0.0.1:\(Self.port)")
                    case .failed(let error):
                        self.serverState = .error(error.localizedDescription)
                        self.lastError = error.localizedDescription
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
            serverState = .error(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    private func accept(connection: NWConnection) {
        let clientID = UUID()
        let client = WebSocketClient(
            connection: connection,
            queue: queue,
            onTextMessage: { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.handleText(text, from: clientID)
                }
            },
            onClose: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.disconnect(clientID: clientID)
                }
            }
        )

        clients[clientID] = client
        updateConnectionState()
        client.start()
    }

    nonisolated private func acceptFromListener(connection: NWConnection) {
        Task { @MainActor [weak self] in
            self?.accept(connection: connection)
        }
    }

    private func disconnect(clientID: UUID) {
        clients.removeValue(forKey: clientID)
        updateConnectionState()
    }

    private func updateConnectionState() {
        Task { @MainActor in
            if let error = lastError, clients.isEmpty {
                serverState = .error(error)
            } else {
                serverState = clients.isEmpty ? .waiting : .connected
            }
        }
    }

    private func handleText(_ text: String, from clientID: UUID) {
        log("<- \(text)")

        guard let data = text.data(using: .utf8) else {
            sendError("Message was not UTF-8", to: clientID)
            return
        }

        let decoder = JSONDecoder()

        do {
            let envelope = try decoder.decode(ProtocolEnvelope.self, from: data)
            switch envelope.type {
            case FloatProtocol.MessageType.hello:
                lastHelloVersion = envelope.version
                sendToClient(clientID, payload: [
                    "type": FloatProtocol.MessageType.hello,
                    "version": FloatProtocol.version,
                ])
            case FloatProtocol.MessageType.state:
                let state = try decoder.decode(StateMessage.self, from: data)
                Task { @MainActor in
                    self.tabs = state.tabs
                    self.syncReceiverPlaybackStateFromTabs()
                }
            case FloatProtocol.MessageType.stop:
                webRTCReceiver.stop()
                Task { @MainActor in
                    self.isStreaming = false
                    self.activeTabId = nil
                    self.activeVideoId = nil
                    self.tabs = []
                }
            case FloatProtocol.MessageType.offer:
                let offer = try decoder.decode(OfferMessage.self, from: data)
                Task { @MainActor in
                    await self.handleOffer(offer, clientID: clientID)
                }
            case FloatProtocol.MessageType.ice:
                let ice = try decoder.decode(IceMessage.self, from: data)
                Task { @MainActor in
                    await self.handleIce(ice, clientID: clientID)
                }
            case FloatProtocol.MessageType.error:
                let errorMessage = try decoder.decode(ErrorMessage.self, from: data)
                let reason = errorMessage.reason ?? "Received error from extension"
                lastError = reason
                log("Extension error: \(reason)")
            case FloatProtocol.MessageType.debug:
                let debugMessage = try decoder.decode(DebugMessage.self, from: data)
                let source = debugMessage.source ?? "extension"
                let event = debugMessage.event ?? "unknown-event"
                let tab = debugMessage.tabId.map(String.init) ?? "n/a"
                let frame = debugMessage.frameId.map(String.init) ?? "n/a"
                let url = debugMessage.url ?? "n/a"
                let payload = debugMessage.payload?.rawDescription ?? "null"
                let line = "[\(source)] \(event) tab=\(tab) frame=\(frame) url=\(url) payload=\(payload)"
                lastExtensionDebugLog = line
                log("Extension debug: \(line)")
            default:
                sendError("Unsupported message type: \(envelope.type)", to: clientID)
            }
        } catch {
            sendError("Invalid message: \(error.localizedDescription)", to: clientID)
        }
    }

    private func sendToAnyClient(_ payload: [String: Any]) {
        guard let clientID = clients.keys.first else {
            lastError = "No extension connection available"
            return
        }

        sendToClient(clientID, payload: payload)
    }

    private func requestPlaybackChange(isPlaying: Bool) {
        guard let activeTabId, let activeVideoId else {
            if protocolDebugLoggingEnabled {
                print("[Float Signal] requestPlaybackChange dropped: missing active target")
            }
            return
        }
        sendToAnyClient([
            "type": FloatProtocol.MessageType.playback,
            "tabId": activeTabId,
            "videoId": activeVideoId,
            "playing": isPlaying,
        ])
    }

    private func requestSeekChange(intervalSeconds: Double) {
        guard intervalSeconds.isFinite else { return }
        guard let activeTabId, let activeVideoId else {
            if protocolDebugLoggingEnabled {
                print("[Float Signal] requestSeekChange dropped: missing active target")
            }
            return
        }
        sendToAnyClient([
            "type": FloatProtocol.MessageType.seek,
            "tabId": activeTabId,
            "videoId": activeVideoId,
            "intervalSeconds": intervalSeconds,
        ])
    }

    private func syncReceiverPlaybackStateFromTabs() {
        guard let activeTabId, let activeVideoId else {
            return
        }
        guard let tab = tabs.first(where: { $0.tabId == activeTabId }) else {
            return
        }
        guard let video = tab.videos.first(where: { $0.videoId == activeVideoId }) else {
            if protocolDebugLoggingEnabled {
                print("[Float Signal] syncReceiverPlaybackStateFromTabs: active video not found videoId=\(activeVideoId) tabId=\(activeTabId)")
            }
            return
        }
        if let playing = video.playing {
            webRTCReceiver.updatePlaybackState(isPlaying: playing)
        }
        webRTCReceiver.updatePlaybackProgress(elapsedSeconds: video.currentTime, durationSeconds: video.duration)
    }

    private func sendToClient(_ clientID: UUID, payload: [String: Any]) {
        guard let client = clients[clientID] else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
            guard let text = String(data: data, encoding: .utf8) else {
                sendError("Failed to encode JSON as UTF-8", to: clientID)
                return
            }

            log("-> \(text)")
            client.send(text: text)
        } catch {
            sendError("Failed to encode payload: \(error.localizedDescription)", to: clientID)
        }
    }

    private func sendError(_ message: String, to clientID: UUID) {
        lastError = message
        sendToClient(clientID, payload: [
            "type": FloatProtocol.MessageType.error,
            "reason": message,
        ])
    }

    private func handleOffer(_ offer: OfferMessage, clientID: UUID) async {
        do {
            activeTabId = offer.tabId
            activeVideoId = offer.videoId
            let answerSDP = try await webRTCReceiver.handleOffer(offer)
            let answer = AnswerMessage(
                type: FloatProtocol.MessageType.answer,
                tabId: offer.tabId,
                videoId: offer.videoId,
                sdp: answerSDP
            )
            sendEncodable(answer, to: clientID)
        } catch {
            sendError("Failed to process offer for \(offer.videoId): \(error.localizedDescription)", to: clientID)
        }
    }

    private func handleIce(_ ice: IceMessage, clientID: UUID) async {
        do {
            try await webRTCReceiver.addRemoteIceCandidate(ice)
        } catch {
            sendError("Failed to add ICE candidate: \(error.localizedDescription)", to: clientID)
        }
    }

    private func sendEncodable<T: Encodable>(_ value: T, to clientID: UUID) {
        do {
            let data = try JSONEncoder().encode(value)
            guard
                let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                sendError("Failed to serialize encoded payload", to: clientID)
                return
            }
            sendToClient(clientID, payload: raw)
        } catch {
            sendError("Failed to encode payload: \(error.localizedDescription)", to: clientID)
        }
    }

    private func sendToAnyClientEncodable<T: Encodable>(_ value: T) {
        guard let clientID = clients.keys.first else {
            lastError = "No extension connection available"
            return
        }
        sendEncodable(value, to: clientID)
    }

    private func log(_ message: String) {
        guard protocolDebugLoggingEnabled else { return }
        print("[Float Signaling] \(message)")
    }
}

private final class WebSocketClient {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onTextMessage: (String) -> Void
    private let onClose: () -> Void

    private var isClosed = false

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        onTextMessage: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.onTextMessage = onTextMessage
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveNextMessage()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    func send(text: String) {
        guard !isClosed else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.fail("WebSocket send error: \(error.localizedDescription)")
            }
        })
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose()
    }

    private func receiveNextMessage() {
        guard !isClosed else { return }

        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }

            if let error {
                self.fail("WebSocket receive error: \(error.localizedDescription)")
                return
            }

            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .close:
                    self.close()
                    return
                case .text:
                    if let data, let text = String(data: data, encoding: .utf8) {
                        self.onTextMessage(text)
                    }
                default:
                    break
                }
            }

            self.receiveNextMessage()
        }
    }

    private func fail(_ reason: String) {
        if protocolDebugLoggingEnabled {
            print("[Float WS] \(reason)")
        }
        close()
    }
}
