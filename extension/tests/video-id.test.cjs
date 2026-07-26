const assert = require("node:assert/strict");
const test = require("node:test");

require("../dist/protocol.js");

test("video IDs consume full randomness and remain unique across elements and frames", () => {
  const firstRandom = Uint8Array.from({ length: 16 }, (_, index) => index);
  const secondRandom = Uint8Array.from({ length: 16 }, (_, index) => 255 - index);

  const first = FloatProtocolVideoID(firstRandom, 1);
  const nextElement = FloatProtocolVideoID(firstRandom, 2);
  const otherFrame = FloatProtocolVideoID(secondRandom, 1);

  assert.match(first, /^vid_[0-9a-f]{32}_[0-9a-z]+$/);
  assert.notEqual(first, nextElement);
  assert.notEqual(first, otherFrame);
  assert.notEqual(nextElement, otherFrame);
  assert.ok(first.length <= 256);
});

test("video IDs reject malformed entropy and sequence values", () => {
  assert.throws(() => FloatProtocolVideoID(new Uint8Array(15), 1));
  assert.throws(() => FloatProtocolVideoID(new Uint8Array(16), 0));
  assert.throws(() => FloatProtocolVideoID(new Uint8Array(16), Number.NaN));
});

test("detects Firefox by extension origin instead of API namespace aliases", () => {
  assert.equal(
    FloatProtocolIsFirefoxExtensionOrigin(
      "moz-extension://87245664-9384-4d2d-a5f7-e3d266bc060c",
    ),
    true,
  );
  assert.equal(
    FloatProtocolIsFirefoxExtensionOrigin(
      "chrome-extension://abcdefghijklmnopabcdefghijklmnop",
    ),
    false,
  );
});

test("routes video commands to the frame that reported the selected source", () => {
  const frames = [
    { frameId: 0, videoIds: [] },
    { frameId: 17, videoIds: ["vid_child_a", "vid_child_b"] },
    { frameId: 23, videoIds: ["vid_other"] },
  ];

  assert.equal(FloatProtocolFrameIdForVideo(frames, "vid_child_b"), 17);
  assert.equal(FloatProtocolFrameIdForVideo(frames, "vid_other"), 23);
  assert.equal(FloatProtocolFrameIdForVideo(frames, "missing"), null);
  assert.equal(
    FloatProtocolFrameIdForVideo([{ frameId: Number.NaN, videoIds: ["vid"] }], "vid"),
    null,
  );
});

test("advances media generations and rejects stale protocol generations", () => {
  assert.equal(FloatProtocolNextMediaGeneration(0), 1);
  assert.equal(FloatProtocolNextMediaGeneration(1), 2);
  assert.equal(FloatProtocolNextMediaGeneration(0x7fff_ffff), 1);
  assert.throws(() => FloatProtocolNextMediaGeneration(-1));
  assert.throws(() => FloatProtocolNextMediaGeneration(Number.NaN));

  assert.equal(
    FloatProtocolIsAnswerMessage({
      type: "answer",
      tabId: 1,
      videoId: "video",
      generation: 1,
      sdp: "answer",
    }),
    true,
  );
  assert.equal(
    FloatProtocolIsAnswerMessage({
      type: "answer",
      tabId: 1,
      videoId: "video",
      generation: 0,
      sdp: "stale",
    }),
    false,
  );
  assert.equal(
    FloatProtocolIsIceMessage({
      type: "ice",
      tabId: 1,
      videoId: "video",
      generation: 0,
      candidate: "candidate",
      sdpMid: null,
      sdpMLineIndex: null,
    }),
    false,
  );
});

test("validates optional source-pause intent on stop messages", () => {
  assert.equal(FloatProtocolIsStopMessage({ type: "stop" }), true);
  assert.equal(
    FloatProtocolIsStopMessage({ type: "stop", pauseSource: true }),
    false,
  );
  assert.equal(
    FloatProtocolIsStopMessage({ type: "stop", pauseSource: false }),
    true,
  );
  assert.equal(
    FloatProtocolIsStopMessage({
      type: "stop",
      pauseSource: true,
      tabId: 42,
      videoId: "video",
      generation: 7,
    }),
    true,
  );
  assert.equal(
    FloatProtocolIsStopMessage({ type: "stop", pauseSource: "true" }),
    false,
  );
  assert.equal(
    FloatProtocolIsStopMessage({
      type: "stop",
      pauseSource: true,
      tabId: 42,
    }),
    false,
  );
  assert.equal(
    FloatProtocolIsStopMessage({
      type: "stop",
      tabId: 42,
      videoId: "video",
      generation: 7,
    }),
    false,
  );
  assert.equal(
    FloatProtocolIsStopMessage({
      type: "stop",
      pauseSource: false,
      tabId: 42,
      videoId: "video",
      generation: 7,
    }),
    false,
  );
});
