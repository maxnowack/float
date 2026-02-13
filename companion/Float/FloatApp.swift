import SwiftUI

@main
struct FloatApp: App {
    @StateObject private var signalingServer = SignalingServer()

    var body: some Scene {
        MenuBarExtra("Float", systemImage: signalingServer.iconName()) {
            MenuContentView(signalingServer: signalingServer)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuContentView: View {
    @ObservedObject var signalingServer: SignalingServer

    var body: some View {
        Text("Float")
            .font(.headline)
        Text(signalingServer.stateDescription())
            .font(.caption)
            .foregroundStyle(.secondary)

        Divider()

        if signalingServer.tabs.isEmpty {
            Text("No videos detected")
                .foregroundStyle(.secondary)
        } else {
            ForEach(signalingServer.tabs) { tab in
                if tab.videos.isEmpty {
                    Text("\(tab.title) - \(tab.domain)")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tab.videos) { video in
                        Button("Float \(tab.title) - \(tab.domain)") {
                            signalingServer.requestStart(tabId: tab.tabId, videoId: video.videoId)
                        }
                    }
                }
            }
        }

        Divider()

        Button("Stop Floating") {
            signalingServer.requestStop()
        }

        if let error = signalingServer.lastError {
            Divider()
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            Button("Copy Error") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(error, forType: .string)
            }
        }

        Divider()

        if let helloVersion = signalingServer.lastHelloVersion {
            Text("Protocol v\(helloVersion)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        Text("ws://127.0.0.1:\(SignalingServer.port)")
            .font(.caption2)
            .foregroundStyle(.secondary)

        Divider()

        Button("Quit Float") {
            NSApplication.shared.terminate(nil)
        }
    }
}
