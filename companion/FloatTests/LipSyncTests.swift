import XCTest
@testable import Float

final class LipSyncTests: XCTestCase {
    private let offer = [
        "v=0",
        "o=- 1 2 IN IP4 127.0.0.1",
        "s=-",
        "a=msid-semantic: WMS stream",
        "m=video 9 UDP/TLS/RTP/SAVPF 96",
        "a=msid:stream video-track",
        "a=ssrc:111 msid:stream video-track",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111",
        "a=msid:stream audio-track",
        "a=ssrc:222 msid:stream audio-track",
        "a=ssrc:222 cname:source",
        "",
    ].joined(separator: "\r\n")

    func testSeparatingAudioSyncGroupRewritesOnlyAudioStreamIds() {
        let rewritten = LipSyncSDP.separatingAudioSyncGroup(in: offer).components(separatedBy: "\r\n")

        XCTAssertTrue(rewritten.contains("a=msid:stream video-track"))
        XCTAssertTrue(rewritten.contains("a=ssrc:111 msid:stream video-track"))
        XCTAssertTrue(rewritten.contains("a=msid:stream-float-audio audio-track"))
        XCTAssertTrue(rewritten.contains("a=ssrc:222 msid:stream-float-audio audio-track"))
        XCTAssertTrue(rewritten.contains("a=ssrc:222 cname:source"))
        XCTAssertTrue(rewritten.contains("a=msid-semantic: WMS stream"))
    }

    func testSeparatingAudioSyncGroupKeepsStreamlessTracks() {
        let streamless = offer.replacingOccurrences(of: "a=msid:stream audio-track", with: "a=msid:- audio-track")
        let rewritten = LipSyncSDP.separatingAudioSyncGroup(in: streamless)

        XCTAssertTrue(rewritten.contains("a=msid:- audio-track"))
    }

    func testLipSyncModeDisablesWebRTCAlignmentOnlyForChrome() {
        XCTAssertEqual(LipSyncMode(extensionOrigin: "chrome-extension://abcdef"), .disabled)
        XCTAssertEqual(LipSyncMode(extensionOrigin: "moz-extension://abcdef"), .webRTC)
        XCTAssertEqual(LipSyncMode(extensionOrigin: ""), .webRTC)
    }
}
