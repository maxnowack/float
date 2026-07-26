const assert = require("node:assert/strict");
const test = require("node:test");

require("../dist/protocol.js");

test("resolves Chrome tab transitions from the tracked active tab in each window", () => {
  const activeTabIdByWindow = new Map([
    [10, 101],
    [20, 201],
  ]);

  assert.equal(
    FloatProtocolPreviousTabForActivation(activeTabIdByWindow, {
      tabId: 102,
      windowId: 10,
    }),
    101,
  );
  assert.equal(
    FloatProtocolPreviousTabForActivation(activeTabIdByWindow, {
      tabId: 202,
      windowId: 20,
    }),
    201,
  );
});

test("prefers Firefox previousTabId over stale tracked state", () => {
  const activeTabIdByWindow = new Map([[10, 100]]);

  assert.equal(
    FloatProtocolPreviousTabForActivation(activeTabIdByWindow, {
      tabId: 102,
      windowId: 10,
      previousTabId: 101,
    }),
    101,
  );
});

test("fails closed for cold, same-tab, and invalid activation state", () => {
  assert.equal(
    FloatProtocolPreviousTabForActivation(new Map(), {
      tabId: 102,
      windowId: 10,
    }),
    null,
  );
  assert.equal(
    FloatProtocolPreviousTabForActivation(new Map([[10, 102]]), {
      tabId: 102,
      windowId: 10,
      previousTabId: 102,
    }),
    null,
  );
  assert.equal(
    FloatProtocolPreviousTabForActivation(new Map([[10, 101]]), {
      tabId: -1,
      windowId: 10,
    }),
    null,
  );
});

test("selects only a playing video for automatic PiP", () => {
  assert.equal(FloatProtocolAutoStartVideoId([]), null);
  assert.equal(
    FloatProtocolAutoStartVideoId([
      { videoId: "paused-a", playing: false },
      { videoId: "paused-b", playing: false },
    ]),
    null,
  );
  assert.equal(
    FloatProtocolAutoStartVideoId([
      { videoId: "paused", playing: false },
      { videoId: "playing-a", playing: true },
      { videoId: "playing-b", playing: true },
    ]),
    "playing-a",
  );
});

test("accepts only the current one-shot transition for each tab", () => {
  const latch = new FloatProtocolAutoStartTransitionLatch();
  const firstTabTransition = latch.begin(101);
  const secondTabTransition = latch.begin(202);

  assert.equal(latch.matches(101, firstTabTransition), true);
  assert.equal(latch.matches(202, secondTabTransition), true);
  assert.equal(latch.has(101), true);
  assert.equal(latch.consume(101, firstTabTransition), true);
  assert.equal(latch.consume(101, firstTabTransition), false);
  assert.equal(latch.has(101), false);
  assert.equal(latch.matches(202, secondTabTransition), true);
});

test("rejects stale transition responses after cancellation or reactivation", () => {
  const latch = new FloatProtocolAutoStartTransitionLatch();
  const staleTransition = latch.begin(101);
  const currentTransition = latch.begin(101);

  assert.notEqual(staleTransition, currentTransition);
  assert.equal(latch.consume(101, staleTransition), false);
  assert.equal(latch.matches(101, currentTransition), true);

  latch.cancel(101);
  assert.equal(latch.consume(101, currentTransition), false);

  const otherTabTransition = latch.begin(202);
  latch.cancelAll();
  assert.equal(latch.matches(202, otherTabTransition), false);
  assert.throws(() => latch.begin(-1));
});

test("orders offers by request while preserving manual video fallback", () => {
  const manualRequest = {
    tabId: 101,
    videoId: "requested",
    requestToken: 7,
    requireExactVideo: false,
  };
  assert.equal(
    FloatProtocolOfferMatchesStartRequest(manualRequest, {
      tabId: 101,
      videoId: "fallback",
      requestToken: 7,
    }),
    true,
  );
  assert.equal(
    FloatProtocolOfferMatchesStartRequest(
      { ...manualRequest, requireExactVideo: true },
      {
        tabId: 101,
        videoId: "fallback",
        requestToken: 7,
      },
    ),
    false,
  );
  assert.equal(
    FloatProtocolOfferMatchesStartRequest(manualRequest, {
      tabId: 101,
      videoId: "requested",
      requestToken: 6,
    }),
    false,
  );
});

test("scopes failed-start cleanup to the request that is still current", () => {
  const currentTarget = {
    tabId: 101,
    videoId: "manual-fallback-video",
    requestToken: 8,
  };

  assert.equal(
    FloatProtocolMediaRequestMatches(currentTarget, {
      tabId: 101,
      requestToken: 7,
    }),
    false,
  );
  assert.equal(
    FloatProtocolMediaRequestMatches(currentTarget, {
      tabId: 101,
      requestToken: 8,
    }),
    true,
  );
  assert.equal(
    FloatProtocolMediaRequestMatches(currentTarget, {
      tabId: 202,
      requestToken: 8,
    }),
    false,
  );
});

test("binds retried controls to the exact stream target", () => {
  const currentTarget = {
    tabId: 101,
    videoId: "video-a",
    frameId: 0,
    generation: 4,
    requestToken: 8,
  };

  assert.equal(
    FloatProtocolStreamTargetMatches(currentTarget, currentTarget),
    true,
  );
  assert.equal(
    FloatProtocolStreamTargetMatches(
      { ...currentTarget, generation: 5, requestToken: 9 },
      currentTarget,
    ),
    false,
  );
  assert.equal(
    FloatProtocolStreamTargetMatches(
      { ...currentTarget, frameId: 7 },
      currentTarget,
    ),
    false,
  );
});

test("stops only the media session named by a terminal error", () => {
  const currentSession = {
    videoId: "video-a",
    generation: 5,
    requestToken: 9,
  };

  assert.equal(
    FloatProtocolMediaSessionMatches(currentSession, currentSession),
    true,
  );
  assert.equal(
    FloatProtocolMediaSessionMatches(
      { ...currentSession, requestToken: 10 },
      currentSession,
    ),
    false,
  );
  assert.equal(
    FloatProtocolMediaSessionMatches(
      { ...currentSession, generation: 6 },
      currentSession,
    ),
    false,
  );
});

test("detects an invalidated content-script extension context", () => {
  assert.equal(
    FloatProtocolShouldDeactivateContentScript(undefined),
    true,
  );
  assert.equal(
    FloatProtocolShouldDeactivateContentScript(
      "extension-id",
      new Error("Extension context invalidated."),
    ),
    true,
  );
  assert.equal(
    FloatProtocolShouldDeactivateContentScript(
      "extension-id",
      new Error("Receiving end does not exist"),
    ),
    false,
  );
});

test("ignores only Chrome's benign one-way message-port closure", () => {
  assert.equal(
    FloatProtocolIsBenignOneWayMessageError(
      "The message port closed before a response was received.",
    ),
    true,
  );
  assert.equal(
    FloatProtocolIsBenignOneWayMessageError(
      new Error("The message port closed before a response was received."),
    ),
    true,
  );
  assert.equal(
    FloatProtocolIsBenignOneWayMessageError(
      "Could not establish connection. Receiving end does not exist.",
    ),
    false,
  );
  assert.equal(
    FloatProtocolIsBenignOneWayMessageError(
      "A listener indicated an asynchronous response by returning true, but the message channel closed before a response was received",
    ),
    false,
  );
});

test("ignores delayed media commands after a newer start", () => {
  const latestStartToken = 1_000_002;

  assert.equal(
    FloatProtocolIsNewerMediaCommandToken(latestStartToken, 1_000_001),
    false,
  );
  assert.equal(
    FloatProtocolIsNewerMediaCommandToken(latestStartToken, 1_000_003),
    true,
  );
});

test("resolves a pending capture when visibilitychange supplies the snapshot", () => {
  const coordinator = new FloatProtocolAutoStartCaptureCoordinator();
  coordinator.begin(11);

  assert.deepEqual(
    coordinator.resolve(null, "visible", 1_000, 1_000),
    [],
  );
  assert.deepEqual(
    coordinator.resolve(
      {
        capturedAtMilliseconds: 1_025,
        videoId: "playing-at-transition",
      },
      "hidden",
      1_025,
      1_000,
    ),
    [{ token: 11, videoId: "playing-at-transition" }],
  );
});

test("does not let app visibility or later playback reuse a transition", () => {
  const coordinator = new FloatProtocolAutoStartCaptureCoordinator();

  assert.deepEqual(
    coordinator.resolve(
      {
        capturedAtMilliseconds: 1_000,
        videoId: "app-hidden-video",
      },
      "hidden",
      1_000,
      1_000,
    ),
    [],
  );

  coordinator.begin(12);
  assert.deepEqual(
    coordinator.resolve(
      {
        capturedAtMilliseconds: 1_010,
        videoId: null,
      },
      "hidden",
      1_010,
      1_000,
    ),
    [{ token: 12, videoId: null }],
  );
  assert.deepEqual(
    coordinator.resolve(
      {
        capturedAtMilliseconds: 1_020,
        videoId: "played-later",
      },
      "hidden",
      1_020,
      1_000,
    ),
    [],
  );
});

test("enumerates Chrome tabs by callback and Firefox tabs by Promise", async () => {
  let chromeArgumentCount = 0;
  const chromeTabs = await new Promise((resolve, reject) => {
    FloatProtocolQueryTabsCompat(
      false,
      {
        query(...args) {
          chromeArgumentCount = args.length;
          args[1]([{ id: 101 }]);
        },
      },
      {},
      {},
      resolve,
      reject,
    );
  });
  assert.equal(chromeArgumentCount, 2);
  assert.deepEqual(chromeTabs, [{ id: 101 }]);

  let firefoxArgumentCount = 0;
  const firefoxTabs = await new Promise((resolve, reject) => {
    FloatProtocolQueryTabsCompat(
      true,
      {
        query(...args) {
          firefoxArgumentCount = args.length;
          return Promise.resolve([{ id: 202 }]);
        },
      },
      {},
      {},
      resolve,
      reject,
    );
  });
  assert.equal(firefoxArgumentCount, 1);
  assert.deepEqual(firefoxTabs, [{ id: 202 }]);
});

test("uses only the fresh hidden-state snapshot from the tab transition", () => {
  const playingSnapshot = {
    capturedAtMilliseconds: 1_000,
    videoId: "playing-at-transition",
  };
  assert.equal(
    FloatProtocolFreshAutoStartSnapshotVideoId(
      playingSnapshot,
      "hidden",
      1_025,
      1_000,
    ),
    "playing-at-transition",
  );
  assert.equal(
    FloatProtocolFreshAutoStartSnapshotVideoId(
      { capturedAtMilliseconds: 1_000, videoId: null },
      "hidden",
      1_025,
      1_000,
    ),
    null,
  );
  assert.equal(
    FloatProtocolFreshAutoStartSnapshotVideoId(
      playingSnapshot,
      "visible",
      1_025,
      1_000,
    ),
    null,
  );
  assert.equal(
    FloatProtocolFreshAutoStartSnapshotVideoId(
      playingSnapshot,
      "hidden",
      2_001,
      1_000,
    ),
    null,
  );
});
