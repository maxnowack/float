#if canImport(WebKit)
import AppKit
import Darwin
import Foundation
import ObjectiveC.runtime
import WebKit

@MainActor
final class NativeWebRTCReceiver: NSObject, WebRTCReceiver {
    var onLocalIceCandidate: ((LocalIceCandidate) -> Void)?
    var onStreamingChanged: ((Bool) -> Void)?
    var onPlaybackCommand: ((Bool) -> Void)?
    var onSeekCommand: ((Double) -> Void)?

    private let scriptMessageName = "floatReceiverBridge"
    private let pipController = NativePiPController()
    private var currentTabId: Int?
    private var currentVideoId: String?

    private var bridgeReady = false
    private lazy var messageHandlerProxy = WeakScriptMessageHandler(delegate: self)

    override init() {
        super.init()

        pipController.onPictureInPictureClosed = { [weak self] in
            self?.stop()
        }
        pipController.onPlaybackCommand = { [weak self] isPlaying in
            self?.onPlaybackCommand?(isPlaying)
        }
        pipController.onSeekCommand = { [weak self] intervalSeconds in
            self?.onSeekCommand?(intervalSeconds)
        }

        let userContentController = pipController.webView.configuration.userContentController
        userContentController.add(messageHandlerProxy, name: scriptMessageName)

        do {
            let html = try Self.loadWebReceiverHTML()
            pipController.loadReceiverPage(html)
        } catch {
            print("[Float WK] receiver.error failed to load receiver.html: \(error.localizedDescription)")
        }
    }

    func handleOffer(_ offer: OfferMessage) async throws -> String {
        currentTabId = offer.tabId
        currentVideoId = offer.videoId

        try await waitForBridgeReady()

        let result = try await pipController.webView.callAsyncJavaScript(
            "return window.FloatReceiver.handleOffer(offerSdp);",
            arguments: ["offerSdp": offer.sdp],
            in: nil,
            contentWorld: .page
        )

        guard let answerSDP = result as? String, !answerSDP.isEmpty else {
            throw WebRTCReceiverError.peerConnectionUnavailable
        }

        pipController.requestStart()
        onStreamingChanged?(true)

        return answerSDP
    }

    func addRemoteIceCandidate(_ ice: IceMessage) async throws {
        try await waitForBridgeReady()

        let candidatePayload: [String: Any] = [
            "candidate": ice.candidate,
            "sdpMid": ice.sdpMid ?? NSNull(),
            "sdpMLineIndex": ice.sdpMLineIndex ?? NSNull(),
        ]

        _ = try await pipController.webView.callAsyncJavaScript(
            "return window.FloatReceiver.addIceCandidate(candidate);",
            arguments: ["candidate": candidatePayload],
            in: nil,
            contentWorld: .page
        )
    }

    func stop() {
        currentTabId = nil
        currentVideoId = nil
        onStreamingChanged?(false)

        pipController.webView.evaluateJavaScript("window.FloatReceiver && window.FloatReceiver.stop();", completionHandler: nil)
        pipController.stop()
    }

    func updatePlaybackState(isPlaying: Bool) {
        pipController.updatePlaybackState(isPlaying)
    }

    func updatePlaybackProgress(elapsedSeconds: Double?, durationSeconds: Double?) {
        pipController.updatePlaybackProgress(elapsedSeconds: elapsedSeconds, durationSeconds: durationSeconds)
    }

    private func waitForBridgeReady() async throws {
        if bridgeReady {
            return
        }

        let timeoutDate = Date().addingTimeInterval(8)
        while !bridgeReady {
            if Date() >= timeoutDate {
                throw WebRTCReceiverError.bridgeNotReady
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func markBridgeReady() {
        bridgeReady = true
    }

    private func handleScriptMessage(_ body: Any) {
        guard let payload = body as? [String: Any], let type = payload["type"] as? String else {
            return
        }

        switch type {
        case "ready":
            markBridgeReady()
            let secure = (payload["isSecureContext"] as? Bool) ?? false
            let hasRTCPeerConnection = (payload["hasRTCPeerConnection"] as? Bool) ?? false
            print("[Float WK] receiver.ready secure=\(secure) hasRTCPeerConnection=\(hasRTCPeerConnection)")
        case "localIce":
            guard
                let tabId = currentTabId,
                let videoId = currentVideoId,
                let candidate = payload["candidate"] as? String
            else {
                return
            }

            let local = LocalIceCandidate(
                tabId: tabId,
                videoId: videoId,
                candidate: candidate,
                sdpMid: payload["sdpMid"] as? String,
                sdpMLineIndex: payload["sdpMLineIndex"] as? Int
            )
            onLocalIceCandidate?(local)
        case "videoSize":
            guard let width = payload["width"] as? Double,
                  let height = payload["height"] as? Double,
                  width > 0,
                  height > 0
            else {
                return
            }
            pipController.updateExpectedVideoSize(CGSize(width: width, height: height))
        case "streaming":
            let isStreaming = (payload["isStreaming"] as? Bool) ?? false
            onStreamingChanged?(isStreaming)
            if isStreaming {
                pipController.requestStart()
            }
        case "connectionState":
            guard let state = payload["state"] as? String else { return }
            if state == "failed" || state == "closed" || state == "disconnected" {
                onStreamingChanged?(false)
            }
        case "error":
            let reason = (payload["reason"] as? String) ?? "unknown"
            print("[Float WK] receiver.error \(reason)")
        default:
            break
        }
    }

    private static func loadWebReceiverHTML() throws -> String {
        guard let url = Bundle.main.url(forResource: "receiver", withExtension: "html") else {
            throw WebRTCReceiverError.notConfigured
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

extension NativeWebRTCReceiver: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handleScriptMessage(message.body)
        }
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler?) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
private final class NativePiPController: NSObject {
    var onPictureInPictureClosed: (() -> Void)?
    var onPlaybackCommand: ((Bool) -> Void)?
    var onSeekCommand: ((Double) -> Void)?

    let webView: WKWebView

    private var privatePiPController: NSObject?
    private var privatePiPContentViewController = NSViewController()

    private var privatePiPPresented = false
    private var wantsStart = false
    private var isStartingPictureInPicture = false
    private var isStoppingPrivatePiPProgrammatically = false

    private var expectedVideoAspectRatio: CGFloat = 16.0 / 9.0

    private var privatePiPPanel: NSWindow?
    private var privatePiPPanelCloseObserver: NSObjectProtocol?
    private var privatePiPVisibilityWatchdog: Timer?
    private var isObservingPrivatePiPPanel = false
    private var isObservingPrivatePiPPlaying = false
    private var privatePiPPanelKVOContext = 0
    private var privatePiPPlayingKVOContext = 0
    private var isUpdatingPlaybackStateProgrammatically = false
    private var defaultPrivatePiPControls: UInt64 = 3
    private var defaultPrivatePiPControlStyle: Int = 1
    private var playbackElapsedSeconds: Double = 0
    private var playbackAnchorDate: Date?
    private var playbackIsPlaying = true
    private var playbackDurationSeconds: Double = 0

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        setupIfNeeded()
    }

    deinit {
        if isObservingPrivatePiPPlaying, let controller = privatePiPController {
            controller.removeObserver(self, forKeyPath: "playing", context: &privatePiPPlayingKVOContext)
            isObservingPrivatePiPPlaying = false
        }
    }

    func loadReceiverPage(_ html: String) {
        webView.loadHTMLString(html, baseURL: URL(string: "https://float.local/"))
    }

    func requestStart() {
        wantsStart = true
        attemptStartPiP()
    }

    func stop() {
        wantsStart = false
        isStartingPictureInPicture = false

        guard privatePiPPresented else { return }

        isStoppingPrivatePiPProgrammatically = true
        handlePrivatePiPStateDidChange(isPresented: false, notifyExternalClose: false)

        if let privatePiPController {
            _ = dismissPrivatePictureInPicture(on: privatePiPController)
        }

        isStoppingPrivatePiPProgrammatically = false
    }

    func updateExpectedVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let ratio = size.width / size.height
        guard ratio.isFinite, ratio > 0 else { return }
        guard abs(ratio - expectedVideoAspectRatio) >= 0.01 else { return }

        expectedVideoAspectRatio = ratio
        applyPrivatePiPAspectConstraints()
    }

    func updatePlaybackState(_ isPlaying: Bool) {
        updatePlaybackClock(isPlaying: isPlaying)
        pushPlaybackStateToPiPController()
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
            } else if !durationSeconds.isFinite {
                playbackDurationSeconds = .infinity
            } else {
                playbackDurationSeconds = 0
            }
        }

        playbackElapsedSeconds = clampElapsedTime(playbackElapsedSeconds)
        pushPlaybackStateToPiPController()
    }

    private func setupIfNeeded() {
        guard privatePiPController == nil else { return }

        webView.translatesAutoresizingMaskIntoConstraints = false
        setupPrivatePiPHostView()

        if !setupPrivatePiPController() {
            print("[Float PiP] Failed to initialize private PiP controller")
        }
    }

    private func setupPrivatePiPHostView() {
        let hostView = NSView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
        hostView.wantsLayer = true
        hostView.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: hostView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])

        privatePiPContentViewController = NSViewController()
        privatePiPContentViewController.view = hostView
    }

    private func setupPrivatePiPController() -> Bool {
        let path = "/System/Library/PrivateFrameworks/PIP.framework/Versions/A/PIP"
        guard dlopen(path, RTLD_NOW) != nil else {
            return false
        }

        guard let pipClass = NSClassFromString("PIPViewController") as? NSObject.Type else {
            return false
        }

        let controller = pipClass.init()
        let presentSelector = NSSelectorFromString("presentViewControllerAsPictureInPicture:")
        guard controller.responds(to: presentSelector) else {
            return false
        }

        ensurePrivatePiPDelegateProtocolConformance()
        privatePiPController = controller
        _ = callObjectSetter(on: controller, selectorName: "setDelegate:", value: self)
        let defaultControls = callUInt64Getter(on: controller, selectorName: "controls") ?? 3
        defaultPrivatePiPControls = defaultControls == 0 ? 3 : defaultControls
        let defaultStyle = callIntGetter(on: controller, selectorName: "controlStyle") ?? 1
        defaultPrivatePiPControlStyle = defaultStyle
        applyPrivatePiPControlsConfiguration()
        _ = updatePrivatePlaybackState(on: controller, isPlaying: true)
        logPrivatePlaybackState(prefix: "[Float PiP] playback configured")
        if let effectiveControls = callUInt64Getter(on: controller, selectorName: "controls"),
           let effectiveStyle = callIntGetter(on: controller, selectorName: "controlStyle")
        {
            print("[Float PiP] controls configured default=\(defaultControls) requested=\(defaultPrivatePiPControls) effective=\(effectiveControls) style=\(effectiveStyle) defaultStyle=\(defaultStyle)")
        }
        controller.addObserver(self, forKeyPath: "playing", options: [.new], context: &privatePiPPlayingKVOContext)
        isObservingPrivatePiPPlaying = true
        applyPrivatePiPAspectConstraints()
        return true
    }

    private func ensurePrivatePiPDelegateProtocolConformance() {
        let cls: AnyClass = type(of: self)
        for protocolName in ["PIPClientXPCProtocol", "PIPViewControllerDelegate"] {
            guard let protocolRef = NSProtocolFromString(protocolName) else { continue }
            if class_conformsToProtocol(cls, protocolRef) {
                continue
            }
            _ = class_addProtocol(cls, protocolRef)
        }

        let clientConforms = NSProtocolFromString("PIPClientXPCProtocol").map { class_conformsToProtocol(cls, $0) } ?? false
        let legacyConforms = NSProtocolFromString("PIPViewControllerDelegate").map { class_conformsToProtocol(cls, $0) } ?? false
        print("[Float PiP] delegate conformance client=\(clientConforms) legacy=\(legacyConforms)")

        for selectorName in [
            "clientPIP:setPlaying:",
            "clientPIP:action:",
            "clientPIP:skipInterval:",
            "pipActionPlay:",
            "pipActionPause:",
            "pipActionStop:",
        ] {
            let responds = responds(to: NSSelectorFromString(selectorName))
            print("[Float PiP] delegate responds \(selectorName)=\(responds)")
        }
    }

    private func attemptStartPiP() {
        guard wantsStart else { return }
        guard !privatePiPPresented else { return }
        guard !isStartingPictureInPicture else { return }
        guard let privatePiPController else { return }

        let selectorName = "presentViewControllerAsPictureInPicture:"
        guard privatePiPController.responds(to: NSSelectorFromString(selectorName)) else { return }

        isStartingPictureInPicture = true
        applyPrivatePiPAspectConstraints()

        let didPresent = callObjectSetter(
            on: privatePiPController,
            selectorName: selectorName,
            value: privatePiPContentViewController
        )

        isStartingPictureInPicture = false

        guard didPresent else { return }
        applyPrivatePiPControlsConfiguration()
        _ = updatePrivatePlaybackState(on: privatePiPController, isPlaying: playbackIsPlaying)
        callBoolSetter(on: privatePiPController, selectorName: "setPlaying:", value: playbackIsPlaying)
        logPrivatePlaybackState(prefix: "[Float PiP] playback after present")
        if let effectiveControls = callUInt64Getter(on: privatePiPController, selectorName: "controls"),
           let effectiveStyle = callIntGetter(on: privatePiPController, selectorName: "controlStyle")
        {
            print("[Float PiP] controls after present requested=\(defaultPrivatePiPControls) effective=\(effectiveControls) style=\(effectiveStyle)")
        }
        handlePrivatePiPStateDidChange(isPresented: true, notifyExternalClose: false)
    }

    private func applyPrivatePiPControlsConfiguration() {
        guard let controller = privatePiPController else { return }
        callUInt64Setter(on: controller, selectorName: "setControls:", value: defaultPrivatePiPControls)
        callIntSetter(on: controller, selectorName: "setControlStyle:", value: defaultPrivatePiPControlStyle)
    }

    private func applyPrivatePiPAspectConstraints() {
        guard let controller = privatePiPController else { return }

        let ratio = max(0.2, min(5.0, expectedVideoAspectRatio))
        let aspectSize = CGSize(width: ratio, height: 1.0)

        callBoolSetter(on: controller, selectorName: "setUserCanResize:", value: true)
        callCGSizeSetter(on: controller, selectorName: "setAspectRatio:", value: aspectSize)
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

    private func callIntSetter(on controller: NSObject, selectorName: String, value: Int) {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return }

        typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Setter.self)
        fn(controller, selector, value)
    }

    private func callUInt64Setter(on controller: NSObject, selectorName: String, value: UInt64) {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return }

        typealias Setter = @convention(c) (AnyObject, Selector, UInt64) -> Void
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Setter.self)
        fn(controller, selector, value)
    }

    @discardableResult
    private func callObjectSetter(on controller: NSObject, selectorName: String, value: AnyObject?) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return false }

        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Setter.self)
        fn(controller, selector, value)
        return true
    }

    @discardableResult
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

    private func callBoolGetter(on controller: NSObject, selectorName: String) -> Bool? {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return nil }

        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Getter.self)
        return fn(controller, selector)
    }

    private func callIntGetter(on controller: NSObject, selectorName: String) -> Int? {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return nil }

        typealias Getter = @convention(c) (AnyObject, Selector) -> Int
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Getter.self)
        return fn(controller, selector)
    }

    private func callUInt64Getter(on controller: NSObject, selectorName: String) -> UInt64? {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return nil }

        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt64
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Getter.self)
        return fn(controller, selector)
    }

    private func updatePrivatePlaybackState(on controller: NSObject, isPlaying: Bool) -> Bool {
        let selector = NSSelectorFromString("updatePlaybackStateUsingBlock:")
        guard controller.responds(to: selector) else { return false }

        let elapsed = currentPlaybackElapsedSeconds()
        let block: @convention(block) (AnyObject) -> Void = { state in
            guard let stateObject = state as? NSObject else { return }
            self.callBoolSetter(on: stateObject, selectorName: "setMuted:", value: false)
            self.callBoolSetter(on: stateObject, selectorName: "setRequiresLinearPlayback:", value: false)
            let isLive = !self.playbackDurationSeconds.isFinite || self.playbackDurationSeconds <= 0
            self.callIntSetter(on: stateObject, selectorName: "setContentType:", value: isLive ? 1 : 0)
            self.callDoubleSetter(
                on: stateObject,
                selectorName: "setContentDuration:",
                value: isLive ? 0 : self.playbackDurationSeconds
            )
            self.callPlaybackTimingSetter(
                on: stateObject,
                selectorName: "setPlaybackRate:elapsedTime:timeControlStatus:",
                playbackRate: isPlaying ? 1.0 : 0.0,
                elapsedTime: elapsed,
                timeControlStatus: isPlaying ? 2 : 0
            )
        }

        return callObjectSetter(on: controller, selectorName: "updatePlaybackStateUsingBlock:", value: unsafeBitCast(block, to: AnyObject.self))
    }

    private func callDoubleSetter(on controller: NSObject, selectorName: String, value: Double) {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return }

        typealias Setter = @convention(c) (AnyObject, Selector, Double) -> Void
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Setter.self)
        fn(controller, selector, value)
    }

    private func callDoubleGetter(on controller: NSObject, selectorName: String) -> Double? {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return nil }

        typealias Getter = @convention(c) (AnyObject, Selector) -> Double
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Getter.self)
        return fn(controller, selector)
    }

    private func callPlaybackTimingSetter(
        on controller: NSObject,
        selectorName: String,
        playbackRate: Double,
        elapsedTime: Double,
        timeControlStatus: Int
    ) {
        let selector = NSSelectorFromString(selectorName)
        guard controller.responds(to: selector) else { return }

        typealias Setter = @convention(c) (AnyObject, Selector, Double, Double, Int) -> Void
        let imp = controller.method(for: selector)
        let fn = unsafeBitCast(imp, to: Setter.self)
        fn(controller, selector, playbackRate, elapsedTime, timeControlStatus)
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

    private func pushPlaybackStateToPiPController() {
        guard let controller = privatePiPController else { return }
        isUpdatingPlaybackStateProgrammatically = true
        _ = updatePrivatePlaybackState(on: controller, isPlaying: playbackIsPlaying)
        // Keep deprecated state in sync; some macOS builds still gate play/pause controls on it.
        callBoolSetter(on: controller, selectorName: "setPlaying:", value: playbackIsPlaying)
        isUpdatingPlaybackStateProgrammatically = false
    }

    private func forwardSeekCommand(interval: Double) {
        guard interval.isFinite else { return }

        playbackElapsedSeconds = clampElapsedTime(currentPlaybackElapsedSeconds() + interval)
        playbackAnchorDate = playbackIsPlaying ? Date() : nil
        pushPlaybackStateToPiPController()
        onSeekCommand?(interval)
    }

    private func logPrivatePlaybackState(prefix: String) {
        guard let controller = privatePiPController else { return }
        guard let state = callObjectGetter(on: controller, selectorName: "playbackState") as? NSObject else { return }

        let contentType = callIntGetter(on: state, selectorName: "contentType") ?? -1
        let duration = callDoubleGetter(on: state, selectorName: "contentDuration") ?? -1
        let elapsed = callDoubleGetter(on: state, selectorName: "elapsedTime") ?? -1
        let rate = callDoubleGetter(on: state, selectorName: "playbackRate") ?? -1
        let timeControlStatus = callIntGetter(on: state, selectorName: "timeControlStatus") ?? -1
        print("\(prefix) contentType=\(contentType) duration=\(duration) elapsed=\(elapsed) rate=\(rate) status=\(timeControlStatus)")
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

    private func handlePrivatePiPStateDidChange(isPresented: Bool, notifyExternalClose: Bool) {
        privatePiPPresented = isPresented

        if isPresented {
            startPrivatePiPPanelObservation()
            startPrivatePiPVisibilityWatchdog()
            refreshPrivatePiPPanelFromController()
            return
        }

        stopPrivatePiPVisibilityWatchdog()
        stopPrivatePiPPanelObservation()
        if notifyExternalClose {
            onPictureInPictureClosed?()
        }
    }

    private func startPrivatePiPPanelObservation() {
        guard let controller = privatePiPController else { return }
        guard !isObservingPrivatePiPPanel else { return }

        controller.addObserver(self, forKeyPath: "panel", options: [.initial, .new], context: &privatePiPPanelKVOContext)
        isObservingPrivatePiPPanel = true
    }

    private func stopPrivatePiPPanelObservation() {
        if isObservingPrivatePiPPanel, let controller = privatePiPController {
            controller.removeObserver(self, forKeyPath: "panel", context: &privatePiPPanelKVOContext)
            isObservingPrivatePiPPanel = false
        }

        if let observer = privatePiPPanelCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            privatePiPPanelCloseObserver = nil
        }

        privatePiPPanel = nil
    }

    private func refreshPrivatePiPPanelFromController() {
        let panel = currentPrivatePiPPanel()
        updateObservedPrivatePiPPanel(panel)
    }

    private func startPrivatePiPVisibilityWatchdog() {
        guard privatePiPVisibilityWatchdog == nil else { return }

        privatePiPVisibilityWatchdog = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPrivatePiPVisibility()
            }
        }
    }

    private func stopPrivatePiPVisibilityWatchdog() {
        privatePiPVisibilityWatchdog?.invalidate()
        privatePiPVisibilityWatchdog = nil
    }

    private func checkPrivatePiPVisibility() {
        guard privatePiPPresented else { return }

        let panel = currentPrivatePiPPanel()
        updateObservedPrivatePiPPanel(panel)

        guard let panel else {
            let notifyExternalClose = !isStoppingPrivatePiPProgrammatically
            handlePrivatePiPStateDidChange(isPresented: false, notifyExternalClose: notifyExternalClose)
            return
        }

        guard panel.isVisible else {
            let notifyExternalClose = !isStoppingPrivatePiPProgrammatically
            handlePrivatePiPStateDidChange(isPresented: false, notifyExternalClose: notifyExternalClose)
            return
        }
    }

    private func currentPrivatePiPPanel() -> NSWindow? {
        guard let controller = privatePiPController else { return nil }
        return callObjectGetter(on: controller, selectorName: "panel") as? NSWindow
    }

    private func updateObservedPrivatePiPPanel(_ panel: NSWindow?) {
        guard privatePiPPanel !== panel else { return }

        if let observer = privatePiPPanelCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            privatePiPPanelCloseObserver = nil
        }

        privatePiPPanel = panel
        guard let panel else { return }

        privatePiPPanelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePrivatePiPPanelWillClose()
            }
        }
    }

    private func handlePrivatePiPPanelWillClose() {
        guard privatePiPPresented else { return }

        let notifyExternalClose = !isStoppingPrivatePiPProgrammatically
        handlePrivatePiPStateDidChange(isPresented: false, notifyExternalClose: notifyExternalClose)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if context == &privatePiPPlayingKVOContext {
            guard !isUpdatingPlaybackStateProgrammatically else { return }
            guard let controller = privatePiPController else { return }
            guard let isPlaying = callBoolGetter(on: controller, selectorName: "playing") else { return }
            onPlaybackCommand?(isPlaying)
            return
        }

        guard context == &privatePiPPanelKVOContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        guard keyPath == "panel" else { return }
        refreshPrivatePiPPanelFromController()
    }

    @objc(clientPIP:setPlaying:)
    func clientPIP(_ pipID: UInt32, setPlaying isPlaying: Bool) {
        _ = pipID
        forwardPlaybackCommand(isPlaying: isPlaying)
    }

    @objc(clientPIP:action:)
    func clientPIP(_ pipID: UInt32, action: Int64) {
        _ = pipID
        if action == 0 {
            forwardPlaybackCommand(isPlaying: !playbackIsPlaying)
            return
        }
        if action == 1 {
            forwardPlaybackCommand(isPlaying: true)
            return
        }
        if action == 2 {
            forwardPlaybackCommand(isPlaying: false)
            return
        }

        print("[Float PiP] unhandled action=\(action)")
    }

    @objc(clientPIP:willCloseWithCompletion:)
    func clientPIP(_ pipID: UInt32, willCloseWithCompletion completion: @escaping () -> Void) {
        _ = pipID
        completion()
    }

    @objc(clientPIP:setWindowContentRect:completion:)
    func clientPIP(_ pipID: UInt32, setWindowContentRect rect: CGRect, completion: @escaping () -> Void) {
        _ = pipID
        _ = rect
        completion()
    }

    @objc(clientPIP:setMicrophoneMuted:)
    func clientPIP(_ pipID: UInt32, setMicrophoneMuted muted: Bool) {
        _ = pipID
        _ = muted
    }

    @objc(clientPIP:skipInterval:)
    func clientPIP(_ pipID: UInt32, skipInterval interval: Double) {
        _ = pipID
        forwardSeekCommand(interval: interval)
    }

    @objc(pipAction:skipInterval:)
    func pipAction(_ pip: Any?, skipInterval interval: Double) {
        _ = pip
        forwardSeekCommand(interval: interval)
    }

    // Legacy PIPViewControllerDelegate callbacks still used by some macOS builds.
    @objc(pipActionPlay:)
    func pipActionPlay(_ pip: Any?) {
        _ = pip
        forwardPlaybackCommand(isPlaying: true)
    }

    @objc(pipActionPause:)
    func pipActionPause(_ pip: Any?) {
        _ = pip
        forwardPlaybackCommand(isPlaying: false)
    }

    @objc(pipActionStop:)
    func pipActionStop(_ pip: Any?) {
        _ = pip
        forwardPlaybackCommand(isPlaying: false)
    }

    private func forwardPlaybackCommand(isPlaying: Bool) {
        updatePlaybackClock(isPlaying: isPlaying)
        pushPlaybackStateToPiPController()
        onPlaybackCommand?(isPlaying)
    }
}
#endif
