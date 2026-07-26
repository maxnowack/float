import AppKit
import Combine
import SwiftUI

@main
struct FloatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let signalingServer = SignalingServer()
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(signalingServer: signalingServer)
    }
}

@MainActor
private final class StatusBarController: NSObject, NSMenuDelegate {
    private let signalingServer: SignalingServer
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellables = Set<AnyCancellable>()

    init(signalingServer: SignalingServer) {
        self.signalingServer = signalingServer
        super.init()
        configureStatusItem()
        bindState()
        refreshStatusItemAppearance()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
    }

    private func bindState() {
        Publishers.CombineLatest3(
            signalingServer.$tabs,
            signalingServer.$isStreaming,
            signalingServer.$serverState
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in
            self?.refreshStatusItemAppearance()
        }
        .store(in: &cancellables)
    }

    private func refreshStatusItemAppearance() {
        let iconName = signalingServer.iconName()
        let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: "Float")
            ?? NSImage(systemSymbolName: "pip", accessibilityDescription: "Float")
        icon?.isTemplate = true

        statusItem.button?.image = icon
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        let eventType = NSApp.currentEvent?.type
        if eventType == .rightMouseUp {
            presentQuitMenu()
            return
        }
        handlePrimaryClick()
    }

    private func handlePrimaryClick() {
        if signalingServer.isStreaming {
            signalingServer.requestStop()
            return
        }

        let sources = signalingServer.availableSources
        if sources.count == 1, let source = sources.first {
            startFloating(source)
            return
        }

        guard sources.count > 1 else {
            NSSound.beep()
            return
        }

        presentSourceMenu(sources)
    }

    private func startFloating(_ source: SignalingServer.VideoSource) {
        signalingServer.requestStart(source)
    }

    private func presentSourceMenu(_ sources: [SignalingServer.VideoSource]) {
        let menu = NSMenu()
        for source in sources {
            let title: String
            if let resolution = source.resolution, !resolution.isEmpty {
                title = "\(source.displayTitle) • \(resolution)"
            } else {
                title = source.displayTitle
            }
            let item = NSMenuItem(title: title, action: #selector(handleSourceSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source
            if signalingServer.isStreaming && signalingServer.isActiveSource(source) {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
        presentMenu(menu)
    }

    private func presentQuitMenu() {
        signalingServer.refreshLaunchAtLoginState()
        let menu = NSMenu()

        let autoStartItem = NSMenuItem(
            title: "Auto-start PiP",
            action: #selector(handleAutoStartBackgroundToggled(_:)),
            keyEquivalent: ""
        )
        autoStartItem.target = self
        autoStartItem.state = signalingServer.autoStartBackgroundEnabled ? .on : .off
        menu.addItem(autoStartItem)

        let autoStopItem = NSMenuItem(
            title: "Auto-stop PiP",
            action: #selector(handleAutoStopForegroundToggled(_:)),
            keyEquivalent: ""
        )
        autoStopItem.target = self
        autoStopItem.state = signalingServer.autoStopForegroundEnabled ? .on : .off
        menu.addItem(autoStopItem)

        let launchAtLoginItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(handleLaunchAtLoginToggled(_:)),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        launchAtLoginItem.state = signalingServer.launchAtLoginEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        let debugOverlayItem = NSMenuItem(
            title: "Debug Overlay",
            action: #selector(handleDebugOverlayToggled(_:)),
            keyEquivalent: ""
        )
        debugOverlayItem.target = self
        debugOverlayItem.state = signalingServer.diagnosticsOverlayEnabled ? .on : .off
        menu.addItem(debugOverlayItem)

        menu.addItem(.separator())

        let statusItem = NSMenuItem(
            title: signalingServer.stateDescription(),
            action: nil,
            keyEquivalent: ""
        )
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        let copyPairingItem = NSMenuItem(
            title: "Copy Sensitive Pairing Secret",
            action: #selector(handleCopyPairingSecret),
            keyEquivalent: ""
        )
        copyPairingItem.target = self
        menu.addItem(copyPairingItem)

        let rotatePairingItem = NSMenuItem(
            title: "Rotate Pairing Secret…",
            action: #selector(handleRotatePairingSecret),
            keyEquivalent: ""
        )
        rotatePairingItem.target = self
        menu.addItem(rotatePairingItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Float", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        presentMenu(menu)
    }

    private func presentMenu(_ menu: NSMenu) {
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    @objc private func handleSourceSelected(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? SignalingServer.VideoSource else { return }
        startFloating(source)
    }

    @objc private func handleQuit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func handleStopRequested() {
        signalingServer.requestStop()
    }

    @objc private func handleAutoStartBackgroundToggled(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        signalingServer.setAutoStartBackgroundEnabled(enabled)
        sender.state = enabled ? .on : .off
    }

    @objc private func handleAutoStopForegroundToggled(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        signalingServer.setAutoStopForegroundEnabled(enabled)
        sender.state = enabled ? .on : .off
    }

    @objc private func handleLaunchAtLoginToggled(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        signalingServer.setLaunchAtLoginEnabled(enabled)
        sender.state = signalingServer.launchAtLoginEnabled ? .on : .off
    }

    @objc private func handleDebugOverlayToggled(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        signalingServer.setDiagnosticsOverlayEnabled(enabled)
        sender.state = enabled ? .on : .off
    }

    @objc private func handleCopyPairingSecret() {
        do {
            let value = try signalingServer.pairingCredentialForDisplay()
            guard SensitivePasteboard.copy(value) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            presentPairingError(error)
        }
    }

    @objc private func handleRotatePairingSecret() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Rotate Float pairing secret?"
        alert.informativeText =
            "All connected extensions will be disconnected. The new sensitive secret will remain on the clipboard for at most 60 seconds."
        alert.addButton(withTitle: "Rotate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let value = try signalingServer.rotatePairingCredential()
            guard SensitivePasteboard.copy(value) else {
                throw CocoaError(.fileWriteUnknown)
            }

            let completed = NSAlert()
            completed.messageText = "Pairing secret rotated"
            completed.informativeText =
                "Paste the new secret into each Float extension. Float clears it after successful pairing or 60 seconds if the clipboard remains unchanged."
            completed.runModal()
        } catch {
            presentPairingError(error)
        }
    }

    private func presentPairingError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Float pairing failed"
        alert.runModal()
    }

    func menuDidClose(_ menu: NSMenu) {
        if statusItem.menu === menu {
            statusItem.menu = nil
        }
    }
}
