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
        let sources = signalingServer.availableSources
        if signalingServer.isStreaming {
            if sources.count == 1, let source = sources.first, signalingServer.isActiveSource(source) {
                return
            }
            guard sources.count > 1 else {
                return
            }
            presentSourceMenu(sources)
            return
        }

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
        signalingServer.requestStart(tabId: source.tabId, videoId: source.videoId)
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
        let menu = NSMenu()
        if signalingServer.isStreaming {
            let stopItem = NSMenuItem(title: "Stop Floating", action: #selector(handleStopRequested), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
            menu.addItem(.separator())
        }
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

    func menuDidClose(_ menu: NSMenu) {
        if statusItem.menu === menu {
            statusItem.menu = nil
        }
    }
}
