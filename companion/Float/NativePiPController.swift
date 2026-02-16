import AppKit
import Darwin
import Foundation
import ObjectiveC.runtime

@MainActor
final class NativePiPController: NSObject {
    private enum Constants {
        static let defaultHostSize = CGSize(width: 1280, height: 720)
        static let visibilityWatchdogInterval: TimeInterval = 0.4
    }

    var onPictureInPictureClosed: (() -> Void)?
    var onPlaybackCommand: ((Bool) -> Void)?
    var onSeekCommand: ((Double) -> Void)?
    var onPiPRenderSizeChanged: ((CGSize) -> Void)?

    private let hostView = NSView(
        frame: CGRect(origin: .zero, size: Constants.defaultHostSize)
    )
    private let contentContainerView = NSView()
    private let diagnosticsOverlayView = NSView()
    private let diagnosticsOverlayLabel = NSTextField(labelWithString: "")
    private weak var hostedContentView: NSView?

    private var privatePiPController: NSObject?
    private var privatePiPContentViewController = NSViewController()

    private var privatePiPPresented = false
    private var wantsStart = false
    private var isStartingPictureInPicture = false
    private var isStoppingPrivatePiPProgrammatically = false

    private var expectedVideoAspectRatio: CGFloat = 16.0 / 9.0

    private var privatePiPPanel: NSWindow?
    private var privatePiPPanelCloseObserver: NSObjectProtocol?
    private var privatePiPPanelResizeObserver: NSObjectProtocol?
    private var privatePiPVisibilityWatchdog: Timer?
    private var isObservingPrivatePiPPanel = false
    private var isObservingPrivatePiPPlaying = false
    private var privatePiPPanelKVOContext = 0
    private var privatePiPPlayingKVOContext = 0
    private var isUpdatingPlaybackStateProgrammatically = false
    private var suppressPlaybackCommands = false
    private var defaultPrivatePiPControls: UInt64 = 3
    private var defaultPrivatePiPControlStyle: Int = 1
    private var playbackElapsedSeconds: Double = 0
    private var playbackAnchorDate: Date?
    private var playbackIsPlaying = true
    private var playbackDurationSeconds: Double = 0
    private var lastReportedPiPRenderSize = CGSize.zero

    override init() {
        super.init()
        setupIfNeeded()
    }

    deinit {
        if isObservingPrivatePiPPlaying, let controller = privatePiPController {
            controller.removeObserver(self, forKeyPath: "playing", context: &privatePiPPlayingKVOContext)
            isObservingPrivatePiPPlaying = false
        }
        if let observer = privatePiPPanelCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            privatePiPPanelCloseObserver = nil
        }
        if let resizeObserver = privatePiPPanelResizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            privatePiPPanelResizeObserver = nil
        }
    }

    func setContentView(_ view: NSView) {
        if hostedContentView === view {
            return
        }

        hostedContentView?.removeFromSuperview()
        hostedContentView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),
        ])
    }

    func requestStart() {
        suppressPlaybackCommands = false
        wantsStart = true
        attemptStartPiP()
    }

    func stop() {
        suppressPlaybackCommands = true
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

    func updateDiagnosticsOverlay(_ text: String?) {
        let nextText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shouldShow = !nextText.isEmpty
        diagnosticsOverlayLabel.stringValue = nextText
        diagnosticsOverlayView.isHidden = !shouldShow
    }

    private func setupIfNeeded() {
        guard privatePiPController == nil else { return }

        setupPrivatePiPHostView()

        if !setupPrivatePiPController() {
            print("[Float PiP] Failed to initialize private PiP controller")
        }
    }

    private func setupPrivatePiPHostView() {
        hostView.wantsLayer = true
        if hostView.layer?.backgroundColor == nil {
            hostView.layer?.backgroundColor = NSColor.black.cgColor
        }

        contentContainerView.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.wantsLayer = true
        hostView.addSubview(contentContainerView)
        NSLayoutConstraint.activate([
            contentContainerView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            contentContainerView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            contentContainerView.topAnchor.constraint(equalTo: hostView.topAnchor),
            contentContainerView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])

        diagnosticsOverlayView.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsOverlayView.wantsLayer = true
        diagnosticsOverlayView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        diagnosticsOverlayView.layer?.cornerRadius = 6
        diagnosticsOverlayView.layer?.masksToBounds = true
        diagnosticsOverlayView.isHidden = true

        diagnosticsOverlayLabel.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsOverlayLabel.textColor = NSColor.white
        diagnosticsOverlayLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        diagnosticsOverlayLabel.lineBreakMode = .byTruncatingTail
        diagnosticsOverlayLabel.stringValue = ""

        diagnosticsOverlayView.addSubview(diagnosticsOverlayLabel)
        NSLayoutConstraint.activate([
            diagnosticsOverlayLabel.leadingAnchor.constraint(equalTo: diagnosticsOverlayView.leadingAnchor, constant: 8),
            diagnosticsOverlayLabel.trailingAnchor.constraint(equalTo: diagnosticsOverlayView.trailingAnchor, constant: -8),
            diagnosticsOverlayLabel.topAnchor.constraint(equalTo: diagnosticsOverlayView.topAnchor, constant: 4),
            diagnosticsOverlayLabel.bottomAnchor.constraint(equalTo: diagnosticsOverlayView.bottomAnchor, constant: -4),
        ])

        hostView.addSubview(diagnosticsOverlayView)
        NSLayoutConstraint.activate([
            diagnosticsOverlayView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor, constant: 12),
            diagnosticsOverlayView.topAnchor.constraint(equalTo: hostView.topAnchor, constant: 12),
            diagnosticsOverlayView.widthAnchor.constraint(lessThanOrEqualTo: hostView.widthAnchor, multiplier: 0.82),
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
        let completion: @convention(block) () -> Void = {}
        if callObjectSetter(
            on: controller,
            selectorName: "dismissPictureInPictureWithCompletionHandler:",
            value: unsafeBitCast(completion, to: AnyObject.self)
        ) {
            return true
        }
        return false
    }

    private func handlePrivatePiPStateDidChange(isPresented: Bool, notifyExternalClose: Bool) {
        privatePiPPresented = isPresented

        if isPresented {
            suppressPlaybackCommands = false
            startPrivatePiPPanelObservation()
            startPrivatePiPVisibilityWatchdog()
            refreshPrivatePiPPanelFromController()
            return
        }

        suppressPlaybackCommands = true
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

        removePrivatePiPPanelObservers()
        privatePiPPanel = nil
        lastReportedPiPRenderSize = .zero
    }

    private func refreshPrivatePiPPanelFromController() {
        let panel = currentPrivatePiPPanel()
        updateObservedPrivatePiPPanel(panel)
    }

    private func startPrivatePiPVisibilityWatchdog() {
        guard privatePiPVisibilityWatchdog == nil else { return }

        privatePiPVisibilityWatchdog = Timer.scheduledTimer(withTimeInterval: Constants.visibilityWatchdogInterval, repeats: true) { [weak self] _ in
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
            handlePrivatePiPStateDidChange(isPresented: false, notifyExternalClose: shouldNotifyExternalClose)
            return
        }

        guard panel.isVisible else {
            handlePrivatePiPStateDidChange(isPresented: false, notifyExternalClose: shouldNotifyExternalClose)
            return
        }

        maybeNotifyPiPRenderSizeChanged(for: panel)
    }

    private func currentPrivatePiPPanel() -> NSWindow? {
        guard let controller = privatePiPController else { return nil }
        return callObjectGetter(on: controller, selectorName: "panel") as? NSWindow
    }

    private func updateObservedPrivatePiPPanel(_ panel: NSWindow?) {
        guard privatePiPPanel !== panel else { return }

        removePrivatePiPPanelObservers()

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

        privatePiPPanelResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePrivatePiPPanelDidResize()
            }
        }

        maybeNotifyPiPRenderSizeChanged(for: panel)
    }

    private func handlePrivatePiPPanelWillClose() {
        guard privatePiPPresented else { return }

        handlePrivatePiPStateDidChange(isPresented: false, notifyExternalClose: shouldNotifyExternalClose)
    }

    private func handlePrivatePiPPanelDidResize() {
        guard privatePiPPresented else { return }
        guard let panel = privatePiPPanel else { return }
        maybeNotifyPiPRenderSizeChanged(for: panel)
    }

    private func effectivePiPContentSizePixels(for panel: NSWindow) -> CGSize {
        let pointsSize = panel.contentView?.bounds.size ?? panel.contentLayoutRect.size
        let scale = panel.backingScaleFactor > 0 ? panel.backingScaleFactor : 1
        return CGSize(
            width: max(1, pointsSize.width * scale),
            height: max(1, pointsSize.height * scale)
        )
    }

    private func maybeNotifyPiPRenderSizeChanged(for panel: NSWindow) {
        let size = effectivePiPContentSizePixels(for: panel)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }

        let widthDelta = abs(size.width - lastReportedPiPRenderSize.width)
        let heightDelta = abs(size.height - lastReportedPiPRenderSize.height)
        guard widthDelta >= 8 || heightDelta >= 8 || lastReportedPiPRenderSize == .zero else { return }

        lastReportedPiPRenderSize = size
        onPiPRenderSizeChanged?(size)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if context == &privatePiPPlayingKVOContext {
            guard !isUpdatingPlaybackStateProgrammatically else { return }
            guard !suppressPlaybackCommands else { return }
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
        switch action {
        case 0:
            forwardPlaybackCommand(isPlaying: !playbackIsPlaying)
        case 1:
            forwardPlaybackCommand(isPlaying: true)
        case 2:
            forwardPlaybackCommand(isPlaying: false)
        default:
            print("[Float PiP] unhandled action=\(action)")
        }
    }

    @objc(clientPIP:willCloseWithCompletion:)
    func clientPIP(_ pipID: UInt32, willCloseWithCompletion completion: @escaping () -> Void) {
        _ = pipID
        suppressPlaybackCommands = true
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
        suppressPlaybackCommands = true
    }

    private func forwardPlaybackCommand(isPlaying: Bool) {
        guard !suppressPlaybackCommands else { return }
        updatePlaybackClock(isPlaying: isPlaying)
        pushPlaybackStateToPiPController()
        onPlaybackCommand?(isPlaying)
    }

    private var shouldNotifyExternalClose: Bool {
        !isStoppingPrivatePiPProgrammatically
    }

    private func removePrivatePiPPanelObservers() {
        if let observer = privatePiPPanelCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            privatePiPPanelCloseObserver = nil
        }
        if let resizeObserver = privatePiPPanelResizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            privatePiPPanelResizeObserver = nil
        }
    }
}
