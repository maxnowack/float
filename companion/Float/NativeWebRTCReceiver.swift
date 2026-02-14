#if canImport(WebKit)
import AppKit
import Darwin
import Foundation
import WebKit

@MainActor
final class NativeWebRTCReceiver: NSObject, WebRTCReceiver {
    var onLocalIceCandidate: ((LocalIceCandidate) -> Void)?
    var onStreamingChanged: ((Bool) -> Void)?

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
    private var privatePiPPanelKVOContext = 0

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        setupIfNeeded()
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

        privatePiPController = controller
        applyPrivatePiPAspectConstraints()
        return true
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
        handlePrivatePiPStateDidChange(isPresented: true, notifyExternalClose: false)
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
        guard context == &privatePiPPanelKVOContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        guard keyPath == "panel" else { return }
        refreshPrivatePiPPanelFromController()
    }
}
#endif
