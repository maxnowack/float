# Dependency provenance

## LiveKit WebRTC

Float uses the `LiveKitWebRTC` Swift package product from:

- Repository: `https://github.com/livekit/webrtc-xcframework`
- Exact version: `144.7559.11`
- Git revision: `46f2af86f06b9a8a9158d37cadda5cb5a214e4c4`
- Release archive:
  `LiveKitWebRTC.xcframework.zip`
- SwiftPM archive SHA-256:
  `07c5caf718058af3c528dcabd257298c40e5a8527e4fb9f47c48336ba5899853`

The version and revision are locked in
`companion/Float.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`;
the project requirement is an exact version. The checksum is declared by the
upstream package manifest for that release and was independently verified
against the downloaded archive during the upgrade.

The artifact contains one universal macOS framework slice supporting `arm64`
and `x86_64`. Float uses the raw prefixed `LKRTC` peer-connection, audio/video
track, ICE, SDP, and Metal-renderer APIs. It configures no STUN or TURN servers.

Licenses and notices are collected in
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

## Extension toolchain

Extension source is compiled with the exact TypeScript version in
`extension/package.json` and `extension/yarn.lock`. No runtime JavaScript
package is shipped.
