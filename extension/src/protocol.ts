const globalScope = globalThis as typeof globalThis & Record<string, unknown>;

if (!globalScope.FloatProtocol) {
  globalScope.FloatProtocol = {
    version: 2,
    messageType: {
      authChallenge: "authChallenge",
      authResponse: "authResponse",
      authResult: "authResult",
      hello: "hello",
      state: "state",
      start: "start",
      offer: "offer",
      answer: "answer",
      ice: "ice",
      stop: "stop",
      playback: "playback",
      seek: "seek",
      qualityHint: "qualityHint",
      autoStartBackground: "autoStartBackground",
      autoStopForeground: "autoStopForeground",
      error: "error",
      debug: "debug",
    },
  };
}

type UnknownRecord = Record<string, unknown>;

function isUnknownRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null;
}

function readTypeField(message: unknown): string | null {
  if (!isUnknownRecord(message)) {
    return null;
  }

  const value = message.type;
  return typeof value === "string" ? value : null;
}

function isStartMessage(message: unknown): message is { type: "start"; tabId: number; videoId: string } {
  if (!isUnknownRecord(message)) {
    return false;
  }

  return (
    message.type === FloatProtocol.messageType.start &&
    typeof message.tabId === "number" &&
    typeof message.videoId === "string"
  );
}

function isStopMessage(
  message: unknown,
): message is {
  type: "stop";
  pauseSource?: boolean;
  tabId?: number;
  videoId?: string;
  generation?: number;
} {
  if (!isUnknownRecord(message)) {
    return false;
  }
  const hasNoSource =
    typeof message.tabId === "undefined" &&
    typeof message.videoId === "undefined" &&
    typeof message.generation === "undefined";
  const hasValidSource =
    message.pauseSource === true &&
    Number.isSafeInteger(message.tabId) &&
    (message.tabId as number) >= 0 &&
    typeof message.videoId === "string" &&
    message.videoId.length > 0 &&
    Number.isSafeInteger(message.generation) &&
    (message.generation as number) > 0 &&
    (message.generation as number) <= 0x7fff_ffff;
  const hasValidPlainStop =
    (typeof message.pauseSource === "undefined" ||
      message.pauseSource === false) &&
    hasNoSource;
  return (
    message.type === FloatProtocol.messageType.stop &&
    (hasValidPlainStop || hasValidSource)
  );
}

function isAutoStartBackgroundMessage(
  message: unknown,
): message is { type: "autoStartBackground"; enabled: boolean } {
  if (!isUnknownRecord(message)) {
    return false;
  }

  return (
    message.type === FloatProtocol.messageType.autoStartBackground &&
    typeof message.enabled === "boolean"
  );
}

function isAutoStopForegroundMessage(
  message: unknown,
): message is { type: "autoStopForeground"; enabled: boolean } {
  if (!isUnknownRecord(message)) {
    return false;
  }

  return (
    message.type === FloatProtocol.messageType.autoStopForeground &&
    typeof message.enabled === "boolean"
  );
}

function isPlaybackMessage(
  message: unknown,
): message is { type: "playback"; tabId: number; videoId: string; playing: boolean } {
  if (!isUnknownRecord(message)) {
    return false;
  }

  return (
    message.type === FloatProtocol.messageType.playback &&
    typeof message.tabId === "number" &&
    typeof message.videoId === "string" &&
    typeof message.playing === "boolean"
  );
}

function isSeekMessage(
  message: unknown,
): message is { type: "seek"; tabId: number; videoId: string; intervalSeconds: number } {
  if (!isUnknownRecord(message)) {
    return false;
  }

  return (
    message.type === FloatProtocol.messageType.seek &&
    typeof message.tabId === "number" &&
    typeof message.videoId === "string" &&
    typeof message.intervalSeconds === "number"
  );
}

function isQualityHintMessage(
  message: unknown,
): message is {
  type: "qualityHint";
  tabId: number;
  videoId: string;
  profile: "high" | "balanced" | "performance";
  pipWidth?: number;
  pipHeight?: number;
} {
  if (!isUnknownRecord(message)) {
    return false;
  }

  const profile = message.profile;
  const isKnownProfile = profile === "high" || profile === "balanced" || profile === "performance";
  const pipWidth = message.pipWidth;
  const pipHeight = message.pipHeight;
  const hasNoPiPSize = typeof pipWidth === "undefined" && typeof pipHeight === "undefined";
  const hasPiPSize =
    typeof pipWidth === "number" &&
    Number.isFinite(pipWidth) &&
    pipWidth > 0 &&
    typeof pipHeight === "number" &&
    Number.isFinite(pipHeight) &&
    pipHeight > 0;
  return (
    message.type === FloatProtocol.messageType.qualityHint &&
    typeof message.tabId === "number" &&
    typeof message.videoId === "string" &&
    isKnownProfile &&
    (hasNoPiPSize || hasPiPSize)
  );
}

function isAnswerMessage(
  message: unknown,
): message is {
  type: "answer";
  tabId: number;
  videoId: string;
  generation: number;
  sdp: string;
} {
  if (!isUnknownRecord(message)) {
    return false;
  }

  return (
    message.type === FloatProtocol.messageType.answer &&
    typeof message.tabId === "number" &&
    typeof message.videoId === "string" &&
    Number.isSafeInteger(message.generation) &&
    (message.generation as number) > 0 &&
    typeof message.sdp === "string"
  );
}

function isIceMessage(
  message: unknown,
): message is {
  type: "ice";
  tabId: number;
  videoId: string;
  generation: number;
  candidate: string;
  sdpMid: string | null;
  sdpMLineIndex: number | null;
} {
  if (!isUnknownRecord(message)) {
    return false;
  }

  const mid = message.sdpMid;
  const mLine = message.sdpMLineIndex;
  return (
    message.type === FloatProtocol.messageType.ice &&
    typeof message.tabId === "number" &&
    typeof message.videoId === "string" &&
    Number.isSafeInteger(message.generation) &&
    (message.generation as number) > 0 &&
    typeof message.candidate === "string" &&
    (typeof mid === "string" || mid === null) &&
    (typeof mLine === "number" || mLine === null)
  );
}

function isErrorMessage(
  message: unknown,
): message is {
  type: "error";
  reason?: string;
  tabId?: number;
  videoId?: string;
  generation?: number;
} {
  return (
    isUnknownRecord(message) &&
    message.type === FloatProtocol.messageType.error &&
    (typeof message.reason === "undefined" || typeof message.reason === "string") &&
    (typeof message.tabId === "undefined" || typeof message.tabId === "number") &&
    (typeof message.videoId === "undefined" || typeof message.videoId === "string") &&
    (typeof message.generation === "undefined" ||
      (Number.isSafeInteger(message.generation) && (message.generation as number) > 0))
  );
}

function asErrorMessage(reason: string): { type: "error"; reason: string } {
  return {
    type: FloatProtocol.messageType.error,
    reason,
  };
}

function makeVideoID(randomBytes: Uint8Array, sequence: number): string {
  if (randomBytes.byteLength !== 16) {
    throw new Error("Video IDs require exactly 16 random bytes");
  }
  if (!Number.isSafeInteger(sequence) || sequence < 1) {
    throw new Error("Video ID sequence must be a positive safe integer");
  }
  const randomHex = Array.from(randomBytes, (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  return `vid_${randomHex}_${sequence.toString(36)}`;
}

function isFirefoxExtensionOrigin(origin: string): boolean {
  return origin.startsWith("moz-extension://");
}

function frameIdForVideo(
  frames: ReadonlyArray<{ frameId: number; videoIds: readonly string[] }>,
  videoId: string,
): number | null {
  if (videoId.length === 0) {
    return null;
  }
  for (const frame of frames) {
    if (
      Number.isSafeInteger(frame.frameId) &&
      frame.frameId >= 0 &&
      frame.videoIds.includes(videoId)
    ) {
      return frame.frameId;
    }
  }
  return null;
}

function previousTabForActivation(
  activeTabIdByWindow: ReadonlyMap<number, number>,
  activeInfo: {
    tabId: number;
    windowId: number;
    previousTabId?: number;
  },
): number | null {
  if (
    !Number.isSafeInteger(activeInfo.tabId) ||
    activeInfo.tabId < 0 ||
    !Number.isSafeInteger(activeInfo.windowId) ||
    activeInfo.windowId < 0
  ) {
    return null;
  }

  const browserPreviousTabId = activeInfo.previousTabId;
  if (
    Number.isSafeInteger(browserPreviousTabId) &&
    (browserPreviousTabId as number) >= 0 &&
    browserPreviousTabId !== activeInfo.tabId
  ) {
    return browserPreviousTabId as number;
  }

  const trackedPreviousTabId = activeTabIdByWindow.get(activeInfo.windowId);
  if (
    Number.isSafeInteger(trackedPreviousTabId) &&
    (trackedPreviousTabId as number) >= 0 &&
    trackedPreviousTabId !== activeInfo.tabId
  ) {
    return trackedPreviousTabId as number;
  }

  return null;
}

function autoStartVideoId(
  videos: ReadonlyArray<{ videoId: string; playing: boolean }>,
): string | null {
  const candidate = videos.find(
    (video) =>
      video.playing === true &&
      typeof video.videoId === "string" &&
      video.videoId.length > 0,
  );
  return candidate?.videoId ?? null;
}

function offerMatchesStartRequest(
  request: {
    tabId: number;
    videoId: string;
    requestToken: number;
    requireExactVideo: boolean;
  },
  offer: {
    tabId: number;
    videoId: string;
    requestToken: number;
  },
): boolean {
  return (
    request.tabId === offer.tabId &&
    request.requestToken === offer.requestToken &&
    (!request.requireExactVideo || request.videoId === offer.videoId)
  );
}

function mediaRequestMatches(
  target: { tabId: number; requestToken: number } | null,
  request: { tabId: number; requestToken: number },
): boolean {
  return (
    target !== null &&
    target.tabId === request.tabId &&
    target.requestToken === request.requestToken
  );
}

function streamTargetMatches(
  target: {
    tabId: number;
    videoId: string;
    frameId: number | null;
    generation: number | null;
    requestToken: number;
  } | null,
  expected: {
    tabId: number;
    videoId: string;
    frameId: number | null;
    generation: number | null;
    requestToken: number;
  },
): boolean {
  return (
    target !== null &&
    target.tabId === expected.tabId &&
    target.videoId === expected.videoId &&
    target.frameId === expected.frameId &&
    target.generation === expected.generation &&
    target.requestToken === expected.requestToken
  );
}

function mediaSessionMatches(
  target: {
    videoId: string | null;
    generation: number | null;
    requestToken: number | null;
  },
  expected: {
    videoId: string;
    generation: number;
    requestToken: number;
  },
): boolean {
  return (
    target.videoId === expected.videoId &&
    target.generation === expected.generation &&
    target.requestToken === expected.requestToken
  );
}

function shouldDeactivateContentScript(
  runtimeId: unknown,
  error?: unknown,
): boolean {
  if (typeof runtimeId !== "string" || runtimeId.length === 0) {
    return true;
  }
  const reason =
    error instanceof Error
      ? error.message
      : typeof error === "string"
        ? error
        : "";
  return reason.toLowerCase().includes("extension context invalidated");
}

function isBenignOneWayMessageError(error: unknown): boolean {
  const reason =
    error instanceof Error
      ? error.message
      : typeof error === "string"
        ? error
        : "";
  return (
    reason.trim().toLowerCase() ===
    "the message port closed before a response was received."
  );
}

function isNewerMediaCommandToken(
  latestToken: number,
  candidateToken: unknown,
): candidateToken is number {
  return (
    Number.isSafeInteger(latestToken) &&
    latestToken >= 0 &&
    Number.isSafeInteger(candidateToken) &&
    (candidateToken as number) > latestToken
  );
}

function isFreshAutoStartSnapshot(
  snapshot: {
    capturedAtMilliseconds: number;
    videoId: string | null;
  } | null,
  visibilityState: string,
  nowMilliseconds: number,
  maximumAgeMilliseconds: number,
): snapshot is {
  capturedAtMilliseconds: number;
  videoId: string | null;
} {
  if (
    visibilityState !== "hidden" ||
    snapshot === null ||
    !Number.isFinite(snapshot.capturedAtMilliseconds) ||
    !Number.isFinite(nowMilliseconds) ||
    !Number.isFinite(maximumAgeMilliseconds) ||
    maximumAgeMilliseconds < 0
  ) {
    return false;
  }
  const age = nowMilliseconds - snapshot.capturedAtMilliseconds;
  return age >= 0 && age <= maximumAgeMilliseconds;
}

function freshAutoStartSnapshotVideoId(
  snapshot: {
    capturedAtMilliseconds: number;
    videoId: string | null;
  } | null,
  visibilityState: string,
  nowMilliseconds: number,
  maximumAgeMilliseconds: number,
): string | null {
  if (
    !isFreshAutoStartSnapshot(
      snapshot,
      visibilityState,
      nowMilliseconds,
      maximumAgeMilliseconds,
    )
  ) {
    return null;
  }
  return snapshot.videoId;
}

class AutoStartCaptureCoordinator {
  private readonly pendingTokens = new Set<number>();

  begin(token: number): void {
    if (!Number.isSafeInteger(token) || token <= 0) {
      throw new Error("Auto-start capture token must be a positive safe integer");
    }
    this.pendingTokens.add(token);
  }

  cancel(token: number): void {
    this.pendingTokens.delete(token);
  }

  cancelAll(): void {
    this.pendingTokens.clear();
  }

  resolve(
    snapshot: {
      capturedAtMilliseconds: number;
      videoId: string | null;
    } | null,
    visibilityState: string,
    nowMilliseconds: number,
    maximumAgeMilliseconds: number,
  ): Array<{ token: number; videoId: string | null }> {
    if (
      !isFreshAutoStartSnapshot(
        snapshot,
        visibilityState,
        nowMilliseconds,
        maximumAgeMilliseconds,
      )
    ) {
      return [];
    }

    const responses = Array.from(this.pendingTokens, (token) => ({
      token,
      videoId: snapshot.videoId,
    }));
    this.pendingTokens.clear();
    return responses;
  }
}

function queryTabsCompat(
  usePromiseAPI: boolean,
  tabsAPI: {
    query: (...args: any[]) => unknown;
  },
  runtimeAPI: {
    lastError?: { message?: string };
  },
  queryInfo: Record<string, unknown>,
  onTabs: (tabs: any[]) => void,
  onError?: (reason: string) => void,
): void {
  const fail = (error: unknown): void => {
    const reason = error instanceof Error ? error.message : String(error);
    onError?.(reason);
  };

  try {
    if (usePromiseAPI) {
      const result = tabsAPI.query(queryInfo);
      if (
        !result ||
        typeof (result as { then?: unknown }).then !== "function"
      ) {
        fail(new Error("tabs.query did not return a Promise"));
        return;
      }
      void (result as Promise<any[]>).then(onTabs).catch(fail);
      return;
    }

    tabsAPI.query(queryInfo, (tabs: any[]) => {
      const reason = runtimeAPI.lastError?.message;
      if (typeof reason === "string" && reason.length > 0) {
        fail(new Error(reason));
        return;
      }
      onTabs(tabs);
    });
  } catch (error) {
    fail(error);
  }
}

class AutoStartTransitionLatch {
  private readonly tokenByTab = new Map<number, number>();
  private nextToken = 0;

  begin(tabId: number): number {
    if (!Number.isSafeInteger(tabId) || tabId < 0) {
      throw new Error("Auto-start tab ID must be a non-negative safe integer");
    }
    this.nextToken =
      this.nextToken >= Number.MAX_SAFE_INTEGER ? 1 : this.nextToken + 1;
    this.tokenByTab.set(tabId, this.nextToken);
    return this.nextToken;
  }

  matches(tabId: number, token: number): boolean {
    return (
      Number.isSafeInteger(tabId) &&
      tabId >= 0 &&
      Number.isSafeInteger(token) &&
      token > 0 &&
      this.tokenByTab.get(tabId) === token
    );
  }

  has(tabId: number): boolean {
    return this.tokenByTab.has(tabId);
  }

  consume(tabId: number, token: number): boolean {
    if (!this.matches(tabId, token)) {
      return false;
    }
    this.tokenByTab.delete(tabId);
    return true;
  }

  cancel(tabId: number): void {
    this.tokenByTab.delete(tabId);
  }

  cancelAll(): void {
    this.tokenByTab.clear();
  }
}

function nextMediaGeneration(current: number): number {
  if (!Number.isSafeInteger(current) || current < 0 || current > 0x7fff_ffff) {
    throw new Error("Media generation must be a non-negative 32-bit integer");
  }
  return current >= 0x7fff_ffff ? 1 : current + 1;
}

// Expose helpers for script-mode TS files without modules.
globalScope.FloatProtocolReadTypeField = readTypeField;
globalScope.FloatProtocolIsStartMessage = isStartMessage;
globalScope.FloatProtocolIsStopMessage = isStopMessage;
globalScope.FloatProtocolIsAutoStartBackgroundMessage = isAutoStartBackgroundMessage;
globalScope.FloatProtocolIsAutoStopForegroundMessage = isAutoStopForegroundMessage;
globalScope.FloatProtocolIsPlaybackMessage = isPlaybackMessage;
globalScope.FloatProtocolIsSeekMessage = isSeekMessage;
globalScope.FloatProtocolIsQualityHintMessage = isQualityHintMessage;
globalScope.FloatProtocolIsAnswerMessage = isAnswerMessage;
globalScope.FloatProtocolIsIceMessage = isIceMessage;
globalScope.FloatProtocolIsErrorMessage = isErrorMessage;
globalScope.FloatProtocolError = asErrorMessage;
globalScope.FloatProtocolVideoID = makeVideoID;
globalScope.FloatProtocolIsFirefoxExtensionOrigin = isFirefoxExtensionOrigin;
globalScope.FloatProtocolFrameIdForVideo = frameIdForVideo;
globalScope.FloatProtocolPreviousTabForActivation = previousTabForActivation;
globalScope.FloatProtocolAutoStartVideoId = autoStartVideoId;
globalScope.FloatProtocolOfferMatchesStartRequest = offerMatchesStartRequest;
globalScope.FloatProtocolMediaRequestMatches = mediaRequestMatches;
globalScope.FloatProtocolStreamTargetMatches = streamTargetMatches;
globalScope.FloatProtocolMediaSessionMatches = mediaSessionMatches;
globalScope.FloatProtocolShouldDeactivateContentScript =
  shouldDeactivateContentScript;
globalScope.FloatProtocolIsBenignOneWayMessageError =
  isBenignOneWayMessageError;
globalScope.FloatProtocolIsNewerMediaCommandToken = isNewerMediaCommandToken;
globalScope.FloatProtocolIsFreshAutoStartSnapshot = isFreshAutoStartSnapshot;
globalScope.FloatProtocolFreshAutoStartSnapshotVideoId =
  freshAutoStartSnapshotVideoId;
globalScope.FloatProtocolAutoStartCaptureCoordinator =
  AutoStartCaptureCoordinator;
globalScope.FloatProtocolAutoStartTransitionLatch = AutoStartTransitionLatch;
globalScope.FloatProtocolQueryTabsCompat = queryTabsCompat;
globalScope.FloatProtocolNextMediaGeneration = nextMediaGeneration;
