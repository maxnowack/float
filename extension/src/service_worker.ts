declare function importScripts(...urls: string[]): void;

const maybeImportScripts = (globalThis as any).importScripts as
  | ((...urls: string[]) => void)
  | undefined;
if (typeof maybeImportScripts === "function") {
  const requiredScripts: string[] = [];
  if (!(globalThis as any).FloatSecurity) {
    requiredScripts.push("./security.js");
  }
  if (!(globalThis as any).FloatProtocol) {
    requiredScripts.push("./protocol.js");
  }
  if (requiredScripts.length > 0) {
    maybeImportScripts(...requiredScripts);
  }
}

const companionPort = 17891;
const companionUrl = `ws://127.0.0.1:${companionPort}`;
const debugLogEnabled = false;
const serviceWorkerExt: any = (globalThis as any).browser ?? (globalThis as any).chrome;
const extensionOrigin = serviceWorkerExt.runtime.getURL("").replace(/\/$/, "");
const isFirefoxExtension = FloatProtocolIsFirefoxExtensionOrigin(extensionOrigin);
const shouldMuteSourceTabDuringStreaming = !isFirefoxExtension;
const pairingPopupUrl = serviceWorkerExt.runtime.getURL("popup.html");
const pairingCredentialRepository = new FloatSecurity.PairingCredentialRepository(
  new FloatSecurity.IndexedDBPairingCredentialStore(globalThis.indexedDB),
);
const reconnectBackoff = new FloatSecurity.ReconnectBackoff();

function ensureProtocolGlobals(): void {
  const scope = globalThis as any;
  if (scope.FloatProtocol) {
    return;
  }

  scope.FloatProtocol = {
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

  type SWUnknownRecord = Record<string, unknown>;
  const isRecord = (value: unknown): value is SWUnknownRecord =>
    typeof value === "object" && value !== null;
  const readType = (message: unknown): string | null => {
    if (!isRecord(message)) {
      return null;
    }
    const value = message.type;
    return typeof value === "string" ? value : null;
  };
  scope.FloatProtocolReadTypeField = readType;
  scope.FloatProtocolError = (reason: string) => ({
    type: scope.FloatProtocol.messageType.error,
    reason,
  });
  scope.FloatProtocolIsStartMessage = (message: unknown): boolean =>
    isRecord(message) &&
    message.type === scope.FloatProtocol.messageType.start &&
    typeof message.tabId === "number" &&
    typeof message.videoId === "string";
  scope.FloatProtocolIsStopMessage = (message: unknown): boolean => {
    if (!isRecord(message)) {
      return false;
    }
    const hasNoSource =
      typeof message.tabId === "undefined" &&
      typeof message.videoId === "undefined" &&
      typeof message.generation === "undefined";
    const hasValidSource =
      message.pauseSource === true &&
      typeof message.tabId === "number" &&
      Number.isSafeInteger(message.tabId) &&
      message.tabId >= 0 &&
      typeof message.videoId === "string" &&
      message.videoId.length > 0 &&
      typeof message.generation === "number" &&
      Number.isSafeInteger(message.generation) &&
      message.generation > 0 &&
      message.generation <= 0x7fff_ffff;
    const hasValidPlainStop =
      (typeof message.pauseSource === "undefined" ||
        message.pauseSource === false) &&
      hasNoSource;
    return (
      message.type === scope.FloatProtocol.messageType.stop &&
      (hasValidPlainStop || hasValidSource)
    );
  };
  scope.FloatProtocolIsAutoStartBackgroundMessage = (message: unknown): boolean =>
    isRecord(message) &&
    message.type === scope.FloatProtocol.messageType.autoStartBackground &&
    typeof message.enabled === "boolean";
  scope.FloatProtocolIsAutoStopForegroundMessage = (message: unknown): boolean =>
    isRecord(message) &&
    message.type === scope.FloatProtocol.messageType.autoStopForeground &&
    typeof message.enabled === "boolean";
  scope.FloatProtocolIsPlaybackMessage = (message: unknown): boolean =>
    isRecord(message) &&
    message.type === scope.FloatProtocol.messageType.playback &&
    typeof message.tabId === "number" &&
    typeof message.videoId === "string" &&
    typeof message.playing === "boolean";
  scope.FloatProtocolIsSeekMessage = (message: unknown): boolean =>
    isRecord(message) &&
    message.type === scope.FloatProtocol.messageType.seek &&
    typeof message.tabId === "number" &&
    typeof message.videoId === "string" &&
    typeof message.intervalSeconds === "number";
  scope.FloatProtocolIsQualityHintMessage = (message: unknown): boolean => {
    if (!isRecord(message)) {
      return false;
    }
    const profile = message.profile;
    const validProfile =
      profile === "high" || profile === "balanced" || profile === "performance";
    const pipWidth = message.pipWidth;
    const pipHeight = message.pipHeight;
    const noPiPSize =
      typeof pipWidth === "undefined" && typeof pipHeight === "undefined";
    const hasPiPSize =
      typeof pipWidth === "number" &&
      Number.isFinite(pipWidth) &&
      pipWidth > 0 &&
      typeof pipHeight === "number" &&
      Number.isFinite(pipHeight) &&
      pipHeight > 0;
    return (
      message.type === scope.FloatProtocol.messageType.qualityHint &&
      typeof message.tabId === "number" &&
      typeof message.videoId === "string" &&
      validProfile &&
      (noPiPSize || hasPiPSize)
    );
  };
  scope.FloatProtocolIsAnswerMessage = (message: unknown): boolean =>
    isRecord(message) &&
    message.type === scope.FloatProtocol.messageType.answer &&
    typeof message.tabId === "number" &&
    typeof message.videoId === "string" &&
    Number.isSafeInteger(message.generation) &&
    (message.generation as number) > 0 &&
    typeof message.sdp === "string";
  scope.FloatProtocolIsIceMessage = (message: unknown): boolean => {
    if (!isRecord(message)) {
      return false;
    }
    const mid = message.sdpMid;
    const mLine = message.sdpMLineIndex;
    return (
      message.type === scope.FloatProtocol.messageType.ice &&
      typeof message.tabId === "number" &&
      typeof message.videoId === "string" &&
      Number.isSafeInteger(message.generation) &&
      (message.generation as number) > 0 &&
      typeof message.candidate === "string" &&
      (typeof mid === "string" || mid === null) &&
      (typeof mLine === "number" || mLine === null)
    );
  };
  scope.FloatProtocolIsErrorMessage = (message: unknown): boolean =>
    isRecord(message) &&
    message.type === scope.FloatProtocol.messageType.error &&
    (typeof message.reason === "undefined" || typeof message.reason === "string") &&
    (typeof message.tabId === "undefined" || typeof message.tabId === "number") &&
    (typeof message.videoId === "undefined" || typeof message.videoId === "string") &&
    (typeof message.generation === "undefined" ||
      (Number.isSafeInteger(message.generation) && (message.generation as number) > 0));
  scope.FloatProtocolPreviousTabForActivation = (
    activeTabIdByWindow: ReadonlyMap<number, number>,
    activeInfo: {
      tabId: number;
      windowId: number;
      previousTabId?: number;
    },
  ): number | null => {
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
  };
  scope.FloatProtocolAutoStartVideoId = (
    videos: ReadonlyArray<{ videoId: string; playing: boolean }>,
  ): string | null => {
    const candidate = videos.find(
      (video) =>
        video.playing === true &&
        typeof video.videoId === "string" &&
        video.videoId.length > 0,
    );
    return candidate?.videoId ?? null;
  };
  scope.FloatProtocolOfferMatchesStartRequest = (
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
  ): boolean =>
    request.tabId === offer.tabId &&
    request.requestToken === offer.requestToken &&
    (!request.requireExactVideo || request.videoId === offer.videoId);
  scope.FloatProtocolMediaRequestMatches = (
    target: { tabId: number; requestToken: number } | null,
    request: { tabId: number; requestToken: number },
  ): boolean =>
    target !== null &&
    target.tabId === request.tabId &&
    target.requestToken === request.requestToken;
  scope.FloatProtocolStreamTargetMatches = (
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
  ): boolean =>
    target !== null &&
    target.tabId === expected.tabId &&
    target.videoId === expected.videoId &&
    target.frameId === expected.frameId &&
    target.generation === expected.generation &&
    target.requestToken === expected.requestToken;
  scope.FloatProtocolMediaSessionMatches = (
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
  ): boolean =>
    target.videoId === expected.videoId &&
    target.generation === expected.generation &&
    target.requestToken === expected.requestToken;
  scope.FloatProtocolIsBenignOneWayMessageError = (
    error: unknown,
  ): boolean => {
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
  };
  scope.FloatProtocolIsNewerMediaCommandToken = (
    latestToken: number,
    candidateToken: unknown,
  ): candidateToken is number =>
    Number.isSafeInteger(latestToken) &&
    latestToken >= 0 &&
    Number.isSafeInteger(candidateToken) &&
    (candidateToken as number) > latestToken;
  scope.FloatProtocolIsFreshAutoStartSnapshot = (
    snapshot: {
      capturedAtMilliseconds: number;
      videoId: string | null;
    } | null,
    visibilityState: string,
    nowMilliseconds: number,
    maximumAgeMilliseconds: number,
  ): boolean => {
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
  };
  scope.FloatProtocolFreshAutoStartSnapshotVideoId = (
    snapshot: {
      capturedAtMilliseconds: number;
      videoId: string | null;
    } | null,
    visibilityState: string,
    nowMilliseconds: number,
    maximumAgeMilliseconds: number,
  ): string | null => {
    if (
      !scope.FloatProtocolIsFreshAutoStartSnapshot(
        snapshot,
        visibilityState,
        nowMilliseconds,
        maximumAgeMilliseconds,
      ) ||
      snapshot === null
    ) {
      return null;
    }
    return snapshot.videoId;
  };
  scope.FloatProtocolAutoStartCaptureCoordinator = class {
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
        !scope.FloatProtocolIsFreshAutoStartSnapshot(
          snapshot,
          visibilityState,
          nowMilliseconds,
          maximumAgeMilliseconds,
        ) ||
        snapshot === null
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
  };
  scope.FloatProtocolQueryTabsCompat = (
    usePromiseAPI: boolean,
    tabsAPI: { query: (...args: any[]) => unknown },
    runtimeAPI: { lastError?: { message?: string } },
    queryInfo: Record<string, unknown>,
    onTabs: (tabs: any[]) => void,
    onError?: (reason: string) => void,
  ): void => {
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
  };
  scope.FloatProtocolAutoStartTransitionLatch = class {
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
  };
}

ensureProtocolGlobals();

type WorkerVideoCandidate = {
  videoId: string;
  playing: boolean;
  muted: boolean;
  resolution: string;
  currentTime?: number | null;
  duration?: number | null;
};

type FrameState = {
  frameId: number;
  title: string;
  url: string;
  videos: WorkerVideoCandidate[];
};

type TabState = {
  tabId: number;
  title: string;
  url: string;
  videos: WorkerVideoCandidate[];
};

type MutedTabState = {
  tabId: number;
  wasMuted: boolean;
  didMuteTab: boolean;
};

type StreamTargetIdentity = {
  tabId: number;
  videoId: string;
  frameId: number | null;
  generation: number | null;
  requestToken: number;
};

const frameStateByTab = new Map<number, Map<string, FrameState>>();
const backgroundedTabIds = new Set<number>();
const activeTabIdByWindow = new Map<number, number>();
const autoStartTransitions = new FloatProtocolAutoStartTransitionLatch();
let lastMediaCommandToken = Math.floor(Date.now()) * 1000;
let socket: WebSocket | null = null;
let authenticationSession: InstanceType<
  typeof FloatSecurity.CompanionAuthenticationSession
> | null = null;
let authenticationSessionReady: Promise<void> | null = null;
let pairingStatus: "disconnected" | "unpaired" | "authenticating" | "connected" =
  "disconnected";
let reconnectTimer: number | null = null;
let activeStreamTarget: StreamTargetIdentity & {
  autoStartToken: number | null;
} | null = null;
let mutedTabState: MutedTabState | null = null;
let desiredMutedTabId: number | null = null;
let autoStartBackgroundEnabled = false;
let autoStopForegroundEnabled = true;
const MAX_PENDING_SOCKET_MESSAGES = 256;
const MAX_PENDING_SOCKET_BYTES = 512 * 1024;
const pendingSocketMessages = new FloatSecurity.BoundedProtocolMessageQueue(
  MAX_PENDING_SOCKET_MESSAGES,
  MAX_PENDING_SOCKET_BYTES,
  FloatProtocol.version,
);
const MAX_TITLE_BYTES = 512;
const MAX_URL_BYTES = 8 * 1024;
const MAX_VIDEO_ID_BYTES = 256;
const MAX_TABS = 256;
const MAX_VIDEOS_PER_TAB = 64;
const MAX_FRAMES_PER_TAB = 64;
const MAX_SDP_BYTES = 256 * 1024;
const MAX_ICE_BYTES = 8 * 1024;
const MAX_DIAGNOSTIC_BYTES = 16 * 1024;
const AUTO_START_CAPTURE_TIMEOUT_MS = 500;
let stateSendTimer: number | null = null;

function utf8ByteLength(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

function truncateUTF8(value: unknown, maximumBytes: number, fallback: string): string {
  if (typeof value !== "string") {
    return fallback;
  }
  if (utf8ByteLength(value) <= maximumBytes) {
    return value;
  }
  let result = "";
  for (const character of value) {
    if (utf8ByteLength(result + character) > maximumBytes) {
      break;
    }
    result += character;
  }
  return result;
}

function sanitizeVideoCandidate(value: unknown): WorkerVideoCandidate | null {
  if (!value || typeof value !== "object") {
    return null;
  }
  const candidate = value as Record<string, unknown>;
  if (
    typeof candidate.videoId !== "string" ||
    candidate.videoId.length === 0 ||
    utf8ByteLength(candidate.videoId) > MAX_VIDEO_ID_BYTES
  ) {
    return null;
  }
  const currentTime =
    typeof candidate.currentTime === "number" &&
    Number.isFinite(candidate.currentTime) &&
    candidate.currentTime >= 0
      ? candidate.currentTime
      : null;
  const duration =
    typeof candidate.duration === "number" &&
    Number.isFinite(candidate.duration) &&
    candidate.duration > 0
      ? candidate.duration
      : null;
  return {
    videoId: candidate.videoId,
    playing: candidate.playing === true,
    muted: candidate.muted === true,
    resolution: truncateUTF8(candidate.resolution, 64, ""),
    currentTime,
    duration,
  };
}

function setPairingStatus(
  status: "disconnected" | "unpaired" | "authenticating" | "connected",
): void {
  pairingStatus = status;
  try {
    const maybePromise = serviceWorkerExt.runtime.sendMessage({
      type: "float:pairing:status",
      status,
    });
    if (maybePromise && typeof maybePromise.catch === "function") {
      maybePromise.catch(() => undefined);
    }
  } catch {
    // The popup is normally closed; status remains available on request.
  }
}

function log(message: string, payload?: unknown): void {
  if (!debugLogEnabled) {
    return;
  }

  if (typeof payload === "undefined") {
    console.log(`[Float SW] ${message}`);
  } else {
    console.log(`[Float SW] ${message}`, payload);
  }
}

function isMissingReceiverError(reason: string): boolean {
  const normalized = reason.toLowerCase();
  return (
    normalized.includes("receiving end does not exist") ||
    normalized.includes("message manager disconnected") ||
    normalized.includes("could not establish connection")
  );
}

function sendMessageToTab(
  tabId: number,
  message: unknown,
  options?: { frameId?: number },
  onError?: (reason: string) => void,
): void {
  const handleError = (reason: string) => {
    log("tabs.sendMessage failed", { tabId, message, reason, options: options ?? null });
    onError?.(reason);
  };

  try {
    if (isFirefoxExtension) {
      const maybePromise = options
        ? serviceWorkerExt.tabs.sendMessage(tabId, message, options)
        : serviceWorkerExt.tabs.sendMessage(tabId, message);
      if (maybePromise && typeof maybePromise.then === "function") {
        maybePromise.catch((error: unknown) => {
          const reason = error instanceof Error ? error.message : String(error);
          handleError(reason);
        });
      }
      return;
    }

    const callback = () => {
      const reason = serviceWorkerExt.runtime.lastError?.message;
      if (typeof reason === "string" && reason.length > 0) {
        if (FloatProtocolIsBenignOneWayMessageError(reason)) {
          return;
        }
        handleError(reason);
      }
    };
    if (options) {
      serviceWorkerExt.tabs.sendMessage(tabId, message, options, callback);
    } else {
      serviceWorkerExt.tabs.sendMessage(tabId, message, callback);
    }
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    handleError(reason);
  }
}

function queryTabs(
  queryInfo: Record<string, unknown>,
  onTabs: (tabs: any[]) => void,
  onError?: (reason: string) => void,
): void {
  FloatProtocolQueryTabsCompat(
    isFirefoxExtension,
    serviceWorkerExt.tabs,
    serviceWorkerExt.runtime,
    queryInfo,
    onTabs,
    onError,
  );
}

function sendSignalMessageToActiveTarget(
  tabId: number,
  videoId: string,
  message: unknown,
  retryAttempt = 0,
  expectedTarget: StreamTargetIdentity | null = null,
): void {
  const generation =
    message && typeof message === "object"
      ? (message as Record<string, unknown>).generation
      : undefined;
  const currentTarget = activeStreamTarget;
  if (
    !currentTarget ||
    currentTarget.tabId !== tabId ||
    currentTarget.videoId !== videoId ||
    (typeof generation === "number" &&
      currentTarget.generation !== generation)
  ) {
    return;
  }
  const targetIdentity =
    expectedTarget ?? {
      tabId: currentTarget.tabId,
      videoId: currentTarget.videoId,
      frameId: currentTarget.frameId,
      generation: currentTarget.generation,
      requestToken: currentTarget.requestToken,
    };
  if (!FloatProtocolStreamTargetMatches(currentTarget, targetIdentity)) {
    return;
  }
  const frameId = targetIdentity.frameId;
  const options = typeof frameId === "number" ? { frameId } : undefined;
  sendMessageToTab(tabId, message, options, (reason) => {
    if (!isMissingReceiverError(reason)) {
      return;
    }
    if (retryAttempt >= 5) {
      return;
    }
    self.setTimeout(() => {
      sendSignalMessageToActiveTarget(
        tabId,
        videoId,
        message,
        retryAttempt + 1,
        targetIdentity,
      );
    }, 120 * (retryAttempt + 1));
  });
}

function connectToCompanion(): void {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) {
    return;
  }

  log(`Connecting to ${companionUrl}`);
  const nextSocket = new WebSocket(companionUrl, [
    FloatSecurity.randomHandshakeSubprotocol(),
  ]);
  socket = nextSocket;

  nextSocket.addEventListener("open", () => {
    authenticationSessionReady = pairingCredentialRepository
      .load()
      .then((secret) => {
        if (socket !== nextSocket || nextSocket.readyState !== WebSocket.OPEN) {
          return;
        }
        authenticationSession =
          new FloatSecurity.CompanionAuthenticationSession(
            extensionOrigin,
            secret,
          );
        setPairingStatus(secret ? "authenticating" : "unpaired");
      })
      .catch(() => {
        if (socket !== nextSocket) {
          return;
        }
        setPairingStatus("unpaired");
        nextSocket.close(4001, "Pairing credential unavailable");
      });
  });

  nextSocket.addEventListener("message", (event) => {
    if (socket !== nextSocket) {
      return;
    }
    void handleCompanionMessage(event.data, nextSocket);
  });

  nextSocket.addEventListener("close", () => {
    if (socket !== nextSocket) {
      return;
    }
    log("Companion socket closed");
    stopStreamingAfterCompanionDisconnect();
    authenticationSession = null;
    authenticationSessionReady = null;
    socket = null;
    pendingSocketMessages.clear();
    if (stateSendTimer !== null) {
      clearTimeout(stateSendTimer);
      stateSendTimer = null;
    }
    if (pairingStatus !== "unpaired") {
      setPairingStatus("disconnected");
      scheduleReconnect();
    }
  });

  nextSocket.addEventListener("error", () => {
    log("Companion socket error");
    nextSocket.close();
  });
}

function stopStreamingAfterCompanionDisconnect(): void {
  autoStartTransitions.cancelAll();
  if (!activeStreamTarget && !mutedTabState) {
    return;
  }

  activeStreamTarget = null;
  desiredMutedTabId = null;
  restoreMutedTabIfNeeded();
  const commandToken = nextMediaCommandToken();

  queryTabs(
    {},
    (tabs) => {
      tabs.forEach((tab) => {
        if (typeof tab.id === "number") {
          sendMessageToTab(tab.id, {
            type: "float:stop",
            commandToken,
          });
        }
      });
    },
    (reason) => {
      log("Failed to enumerate tabs after companion disconnect", reason);
    },
  );
}

function scheduleReconnect(): void {
  if (reconnectTimer !== null) {
    return;
  }

  reconnectTimer = self.setTimeout(() => {
    reconnectTimer = null;
    connectToCompanion();
  }, reconnectBackoff.nextDelayMilliseconds());
}

function sendSocketMessage(payload: unknown): void {
  if (
    !socket ||
    socket.readyState !== WebSocket.OPEN ||
    !authenticationSession?.isAuthenticated
  ) {
    queueSocketMessage(payload);
    connectToCompanion();
    return;
  }

  const versionedPayload =
    payload && typeof payload === "object"
      ? { ...(payload as Record<string, unknown>), version: FloatProtocol.version }
      : payload;
  socket.send(JSON.stringify(versionedPayload));
  log("-> companion", payload);
}

function flushPendingSocketMessages(): void {
  if (
    !socket ||
    socket.readyState !== WebSocket.OPEN ||
    !authenticationSession?.isAuthenticated
  ) {
    return;
  }

  for (const payload of pendingSocketMessages.drain()) {
    const versionedPayload =
      payload && typeof payload === "object"
        ? { ...(payload as Record<string, unknown>), version: FloatProtocol.version }
        : payload;
    socket.send(JSON.stringify(versionedPayload));
    log("-> companion (flushed)", payload);
  }
}

function queueSocketMessage(payload: unknown): void {
  if (!pendingSocketMessages.enqueue(payload)) {
    log("Dropped pending companion message due to queue policy", {
      type: FloatProtocolReadTypeField(payload),
      queuedMessages: pendingSocketMessages.count,
      queuedBytes: pendingSocketMessages.byteCount,
    });
  }
}

function sendProtocolError(reason: string): void {
  sendSocketMessage(FloatProtocolError(reason));
}

function findReportedFrameIdForVideo(tabId: number, videoId: string): number | null {
  const frameMap = frameStateByTab.get(tabId);
  if (!frameMap) {
    return null;
  }
  return FloatProtocolFrameIdForVideo(
    Array.from(frameMap.values(), (frame) => ({
      frameId: frame.frameId,
      videoIds: frame.videos.map((video) => video.videoId),
    })),
    videoId,
  );
}

function removeReportedFrame(tabId: number, frameId: number): void {
  const frameMap = frameStateByTab.get(tabId);
  if (!frameMap) {
    return;
  }
  for (const [key, frame] of frameMap.entries()) {
    if (frame.frameId === frameId) {
      frameMap.delete(key);
    }
  }
  if (frameMap.size === 0) {
    frameStateByTab.delete(tabId);
  }
}

function nextMediaCommandToken(): number {
  const clockToken = Math.floor(Date.now()) * 1000;
  lastMediaCommandToken = Math.max(lastMediaCommandToken + 1, clockToken);
  if (!Number.isSafeInteger(lastMediaCommandToken)) {
    throw new Error("Media command token exceeded the safe integer range");
  }
  return lastMediaCommandToken;
}

function sendStartToTab(
  tabId: number,
  videoId: string,
  targetFrameId?: number,
  autoStartToken: number | null = null,
): void {
  const frameId =
    typeof targetFrameId === "number"
      ? targetFrameId
      : findReportedFrameIdForVideo(tabId, videoId);
  const previousTarget = activeStreamTarget;
  if (previousTarget) {
    desiredMutedTabId = null;
    restoreMutedTabIfNeeded(previousTarget.tabId);
    sendMessageToTab(
      previousTarget.tabId,
      {
        type: "float:stop",
        commandToken: nextMediaCommandToken(),
      },
      typeof previousTarget.frameId === "number"
        ? { frameId: previousTarget.frameId }
        : undefined,
    );
  }
  const requestToken = nextMediaCommandToken();
  activeStreamTarget = {
    tabId,
    videoId,
    frameId,
    generation: null,
    requestToken,
    autoStartToken,
  };
  desiredMutedTabId = shouldMuteSourceTabDuringStreaming ? tabId : null;

  const startMessage: Record<string, unknown> = {
    type: "float:start",
    videoId,
    requestToken,
  };
  if (autoStartToken !== null) {
    startMessage.requirePlaying = true;
    startMessage.autoStartToken = autoStartToken;
  }

  sendMessageToTab(
    tabId,
    startMessage,
    typeof frameId === "number" ? { frameId } : undefined,
    (reason) => {
      log("Failed to send start message", reason);
      if (
        !FloatProtocolMediaRequestMatches(activeStreamTarget, {
          tabId,
          requestToken,
        })
      ) {
        return;
      }
      if (typeof frameId === "number") {
        removeReportedFrame(tabId, frameId);
      }
      activeStreamTarget = null;
      if (desiredMutedTabId === tabId) {
        desiredMutedTabId = null;
      }
      restoreMutedTabIfNeeded(tabId);
    },
  );
}

function cancelPendingAutoStart(tabId: number): void {
  autoStartTransitions.cancel(tabId);
}

function beginAutoStartForTabActivation(tabId: number): void {
  cancelPendingAutoStart(tabId);
  if (!autoStartBackgroundEnabled || activeStreamTarget) {
    return;
  }

  const token = autoStartTransitions.begin(tabId);
  sendMessageToTab(
    tabId,
    {
      type: "float:autoStart:capture",
      token,
    },
    undefined,
    (reason) => {
      if (autoStartTransitions.consume(tabId, token)) {
        log("Failed to capture auto-start candidates", reason);
      }
    },
  );

  self.setTimeout(() => {
    autoStartTransitions.consume(tabId, token);
  }, AUTO_START_CAPTURE_TIMEOUT_MS);
}

function onAutoStartCandidate(message: any, sender: any): void {
  const tabId = sender?.tab?.id;
  const token = message?.token;
  if (
    !Number.isSafeInteger(tabId) ||
    tabId < 0 ||
    !Number.isSafeInteger(token) ||
    token <= 0 ||
    !autoStartTransitions.matches(tabId, token)
  ) {
    return;
  }

  if (
    !backgroundedTabIds.has(tabId) ||
    !autoStartBackgroundEnabled ||
    activeStreamTarget
  ) {
    autoStartTransitions.cancel(tabId);
    return;
  }

  const videoId = message?.videoId;
  if (
    typeof videoId !== "string" ||
    videoId.length === 0 ||
    utf8ByteLength(videoId) > MAX_VIDEO_ID_BYTES
  ) {
    // Other frames may still report a playing video for this transition.
    return;
  }

  if (!autoStartTransitions.consume(tabId, token)) {
    return;
  }

  const frameId =
    Number.isSafeInteger(sender?.frameId) && sender.frameId >= 0
      ? sender.frameId
      : undefined;
  sendStartToTab(tabId, videoId, frameId, token);
}

function onAutoStartRejected(message: any, sender: any): void {
  const tabId = sender?.tab?.id;
  if (
    !Number.isSafeInteger(tabId) ||
    tabId < 0 ||
    !Number.isSafeInteger(message?.token) ||
    message.token <= 0 ||
    !Number.isSafeInteger(message?.requestToken) ||
    message.requestToken <= 0 ||
    typeof message?.videoId !== "string"
  ) {
    return;
  }

  const target = activeStreamTarget;
  if (
    !target ||
    target.tabId !== tabId ||
    target.videoId !== message.videoId ||
    target.generation !== null ||
    target.requestToken !== message.requestToken ||
    target.autoStartToken !== message.token
  ) {
    return;
  }

  activeStreamTarget = null;
  desiredMutedTabId = null;
  restoreMutedTabIfNeeded(tabId);
}

function stopStreamForForegroundTab(tabId: number): void {
  if (!activeStreamTarget || activeStreamTarget.tabId !== tabId) {
    return;
  }

  const sourceTabId = activeStreamTarget.tabId;
  activeStreamTarget = null;
  desiredMutedTabId = null;
  restoreMutedTabIfNeeded(sourceTabId);
  sendSocketMessage({ type: FloatProtocol.messageType.stop });

  sendMessageToTab(
    sourceTabId,
    {
      type: "float:stop",
      commandToken: nextMediaCommandToken(),
    },
    undefined,
    (reason) => {
      log("Failed to send stop message for foreground tab", reason);
    },
  );
}

function stopActiveStreamForTabLifecycle(tabId: number, tabWasRemoved: boolean): void {
  if (!activeStreamTarget || activeStreamTarget.tabId !== tabId) {
    if (tabWasRemoved && mutedTabState?.tabId === tabId) {
      mutedTabState = null;
      desiredMutedTabId = null;
    }
    return;
  }

  activeStreamTarget = null;
  desiredMutedTabId = null;
  if (tabWasRemoved) {
    if (mutedTabState?.tabId === tabId) {
      mutedTabState = null;
    }
  } else {
    restoreMutedTabIfNeeded(tabId);
  }
  sendSocketMessage({ type: FloatProtocol.messageType.stop });
}

function unmuteTabIfNeeded(tabId: number): void {
  serviceWorkerExt.tabs.get(tabId, (tab: any) => {
    if (serviceWorkerExt.runtime.lastError) {
      return;
    }

    const mutedInfo = tab?.mutedInfo;
    const currentlyMuted = Boolean(mutedInfo?.muted);
    if (!currentlyMuted || mutedInfo?.reason === "user") {
      return;
    }

    serviceWorkerExt.tabs.update(tabId, { muted: false }, () => {
      if (serviceWorkerExt.runtime.lastError) {
        log("Failed to restore tab mute state", serviceWorkerExt.runtime.lastError.message);
      }
    });
  });
}

function muteTabForStreaming(tabId: number): void {
  if (!shouldMuteSourceTabDuringStreaming) {
    return;
  }

  desiredMutedTabId = tabId;

  if (mutedTabState && mutedTabState.tabId === tabId) {
    return;
  }
  if (mutedTabState && mutedTabState.tabId !== tabId) {
    restoreMutedTabIfNeeded(mutedTabState.tabId);
  }

  serviceWorkerExt.tabs.get(tabId, (tab: any) => {
    if (desiredMutedTabId !== tabId) {
      return;
    }

    if (serviceWorkerExt.runtime.lastError) {
      log("Failed to inspect tab mute state", serviceWorkerExt.runtime.lastError.message);
      return;
    }

    const wasMuted = Boolean(tab?.mutedInfo?.muted);
    mutedTabState = { tabId, wasMuted, didMuteTab: false };
    if (wasMuted) {
      return;
    }

    serviceWorkerExt.tabs.update(tabId, { muted: true }, () => {
      if (serviceWorkerExt.runtime.lastError) {
        log("Failed to mute tab", serviceWorkerExt.runtime.lastError.message);
        if (mutedTabState?.tabId === tabId) {
          mutedTabState = null;
        }
        return;
      }
      if (mutedTabState?.tabId === tabId) {
        mutedTabState.didMuteTab = true;
        if (desiredMutedTabId !== tabId) {
          restoreMutedTabIfNeeded(tabId);
        }
        return;
      }
      if (desiredMutedTabId !== tabId) {
        unmuteTabIfNeeded(tabId);
      }
    });
  });
}

function restoreMutedTabIfNeeded(tabId?: number): void {
  if (!shouldMuteSourceTabDuringStreaming) {
    return;
  }

  if (!mutedTabState) {
    return;
  }
  if (typeof tabId === "number" && mutedTabState.tabId !== tabId) {
    return;
  }
  if (desiredMutedTabId === mutedTabState.tabId) {
    return;
  }

  const state = mutedTabState;
  if (state.wasMuted) {
    mutedTabState = null;
    return;
  }
  if (!state.didMuteTab) {
    return;
  }

  mutedTabState = null;
  unmuteTabIfNeeded(state.tabId);
}

function flattenTabState(tabId: number): TabState | null {
  const frameMap = frameStateByTab.get(tabId);
  if (!frameMap || frameMap.size === 0) {
    return null;
  }

  const allFrames = Array.from(frameMap.values());
  const preferred = allFrames[0];
  const deduped = new Map<string, WorkerVideoCandidate>();

  for (const frame of allFrames) {
    for (const video of frame.videos) {
      if (!deduped.has(video.videoId)) {
        deduped.set(video.videoId, video);
        if (deduped.size >= MAX_VIDEOS_PER_TAB) {
          break;
        }
      }
    }
    if (deduped.size >= MAX_VIDEOS_PER_TAB) {
      break;
    }
  }

  return {
    tabId,
    title: preferred.title,
    url: preferred.url,
    videos: Array.from(deduped.values()),
  };
}

function buildStatePayload(): { type: "state"; tabs: TabState[] } {
  const tabs: TabState[] = [];

  for (const tabId of frameStateByTab.keys()) {
    if (tabs.length >= MAX_TABS) {
      break;
    }
    const tab = flattenTabState(tabId);
    if (tab) {
      tabs.push(tab);
    }
  }

  return {
    type: FloatProtocol.messageType.state,
    tabs,
  };
}

function sendState(): void {
  if (stateSendTimer !== null) {
    return;
  }
  stateSendTimer = self.setTimeout(() => {
    stateSendTimer = null;
    sendSocketMessage(buildStatePayload());
  }, 100);
}

function onOfferFromContent(message: any, sender: any): void {
  const tabId = sender?.tab?.id;
  if (
    typeof tabId !== "number" ||
    !Number.isSafeInteger(tabId) ||
    tabId < 0 ||
    typeof message.videoId !== "string" ||
    message.videoId.length === 0 ||
    utf8ByteLength(message.videoId) > MAX_VIDEO_ID_BYTES ||
    !Number.isSafeInteger(message.requestToken) ||
    message.requestToken <= 0 ||
    !Number.isSafeInteger(message.generation) ||
    message.generation <= 0 ||
    typeof message.sdp !== "string" ||
    message.sdp.length === 0 ||
    utf8ByteLength(message.sdp) > MAX_SDP_BYTES
  ) {
    sendProtocolError("Invalid offer message from content script");
    return;
  }

  const requestedTarget = activeStreamTarget;
  const senderFrameId =
    Number.isSafeInteger(sender?.frameId) && sender.frameId >= 0
      ? sender.frameId
      : null;
  if (
    !requestedTarget ||
    requestedTarget.generation !== null ||
    (requestedTarget.frameId !== null &&
      requestedTarget.frameId !== senderFrameId) ||
    !FloatProtocolOfferMatchesStartRequest(
      {
        tabId: requestedTarget.tabId,
        videoId: requestedTarget.videoId,
        requestToken: requestedTarget.requestToken,
        requireExactVideo: requestedTarget.autoStartToken !== null,
      },
      {
        tabId,
        videoId: message.videoId,
        requestToken: message.requestToken,
      },
    )
  ) {
    return;
  }

  muteTabForStreaming(tabId);
  activeStreamTarget = {
    ...requestedTarget,
    videoId: message.videoId,
    frameId: senderFrameId,
    generation: message.generation,
  };
  desiredMutedTabId = shouldMuteSourceTabDuringStreaming ? tabId : null;

  sendSocketMessage({
    type: FloatProtocol.messageType.offer,
    tabId,
    videoId: message.videoId,
    generation: message.generation,
    sdp: message.sdp,
  });
}

function onIceFromContent(message: any, sender: any): void {
  const tabId = sender?.tab?.id;
  if (
    typeof tabId !== "number" ||
    !Number.isSafeInteger(tabId) ||
    tabId < 0 ||
    typeof message.videoId !== "string" ||
    message.videoId.length === 0 ||
    utf8ByteLength(message.videoId) > MAX_VIDEO_ID_BYTES ||
    !Number.isSafeInteger(message.requestToken) ||
    message.requestToken <= 0 ||
    !Number.isSafeInteger(message.generation) ||
    message.generation <= 0 ||
    typeof message.candidate !== "string" ||
    message.candidate.length === 0 ||
    utf8ByteLength(message.candidate) > MAX_ICE_BYTES
  ) {
    sendProtocolError("Invalid ICE message from content script");
    return;
  }
  if (
    !activeStreamTarget ||
    activeStreamTarget.tabId !== tabId ||
    activeStreamTarget.videoId !== message.videoId ||
    activeStreamTarget.requestToken !== message.requestToken ||
    activeStreamTarget.generation !== message.generation
  ) {
    return;
  }

  sendSocketMessage({
    type: FloatProtocol.messageType.ice,
    tabId,
    videoId: message.videoId,
    generation: message.generation,
    candidate: message.candidate,
    sdpMid: typeof message.sdpMid === "string" ? message.sdpMid : null,
    sdpMLineIndex: typeof message.sdpMLineIndex === "number" ? message.sdpMLineIndex : null,
  });
}

function onErrorFromContent(message: any, sender: any): void {
  const tabId = sender?.tab?.id;
  const senderFrameId =
    Number.isSafeInteger(sender?.frameId) && sender.frameId >= 0
      ? sender.frameId
      : null;
  const target = activeStreamTarget;
  const matchesCurrentRequest =
    FloatProtocolMediaRequestMatches(target, {
      tabId:
        typeof tabId === "number" && Number.isSafeInteger(tabId) && tabId >= 0
          ? tabId
          : -1,
      requestToken: message.requestToken,
    }) &&
    target !== null &&
    (target.frameId === null || target.frameId === senderFrameId) &&
    (typeof message.videoId !== "string" ||
      (target.generation === null && target.autoStartToken === null) ||
      message.videoId === target.videoId) &&
    (target.generation === null ||
      typeof message.generation !== "number" ||
      message.generation === target.generation);
  if (!matchesCurrentRequest || target === null) {
    return;
  }

  const reason = truncateUTF8(
    message.reason,
    MAX_DIAGNOSTIC_BYTES,
    "unknown content script error",
  );
  const videoId =
    typeof message.videoId === "string" &&
    message.videoId.length > 0 &&
    utf8ByteLength(message.videoId) <= MAX_VIDEO_ID_BYTES
      ? message.videoId
      : null;
  sendSocketMessage({
    type: FloatProtocol.messageType.error,
    tabId:
      typeof tabId === "number" && Number.isSafeInteger(tabId) && tabId >= 0
        ? tabId
        : null,
    videoId,
    generation:
      Number.isSafeInteger(message.generation) && message.generation > 0
        ? message.generation
        : null,
    reason,
  });

  if (message.terminal !== true) {
    return;
  }

  const terminalVideoId =
    typeof message.videoId === "string" &&
    message.videoId.length > 0 &&
    utf8ByteLength(message.videoId) <= MAX_VIDEO_ID_BYTES
      ? message.videoId
      : target.videoId;
  const terminalGeneration =
    Number.isSafeInteger(message.generation) && message.generation > 0
      ? message.generation
      : target.generation;
  if (terminalGeneration !== null) {
    sendMessageToTab(
      target.tabId,
      {
        type: "float:stop",
        commandToken: nextMediaCommandToken(),
        videoId: terminalVideoId,
        generation: terminalGeneration,
        requestToken: target.requestToken,
      },
      typeof target.frameId === "number" ? { frameId: target.frameId } : undefined,
      (stopReason) => {
        log("Failed to stop terminal content stream", stopReason);
      },
    );
  }

  activeStreamTarget = null;
  desiredMutedTabId = null;
  restoreMutedTabIfNeeded(tabId);
}

function onDebugFromContent(message: any, sender: any): void {
  if (!debugLogEnabled) {
    return;
  }
  const tabId = sender?.tab?.id;
  const source = typeof message.source === "string" ? message.source : "content-script";
  const event = typeof message.event === "string" ? message.event : "unknown-event";
  const payload = message.payload ?? null;
  const url = typeof message.url === "string" ? message.url : sender?.url ?? null;

  sendSocketMessage({
    type: FloatProtocol.messageType.debug,
    source,
    event,
    tabId: typeof tabId === "number" ? tabId : -1,
    frameId: typeof sender?.frameId === "number" ? sender.frameId : null,
    url,
    payload,
  });

  console.log(`[Float SW][${source}] ${event}`, {
    tabId: typeof tabId === "number" ? tabId : null,
    frameId: typeof sender?.frameId === "number" ? sender.frameId : null,
    url,
    payload,
  });
}

function frameKey(sender: any): string {
  const frameId = sender && typeof sender.frameId === "number" ? sender.frameId : 0;
  return String(frameId);
}

function isTrustedExtensionPage(sender: any): boolean {
  return FloatSecurity.isTrustedExtensionPageSender(
    sender,
    serviceWorkerExt.runtime.id,
    pairingPopupUrl,
  );
}

function reconnectAfterPairingChange(): void {
  reconnectBackoff.reset();
  if (reconnectTimer !== null) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  authenticationSession = null;
  authenticationSessionReady = null;
  setPairingStatus("disconnected");
  if (socket) {
    const currentSocket = socket;
    socket = null;
    currentSocket.close(4000, "Pairing credential changed");
  }
  self.setTimeout(connectToCompanion, 50);
}

function onVideosUpdate(message: any, sender: any): void {
  const tabId = sender?.tab?.id;
  if (typeof tabId !== "number") {
    return;
  }
  if (!frameStateByTab.has(tabId) && frameStateByTab.size >= MAX_TABS) {
    return;
  }

  const key = frameKey(sender);
  const frameMap = frameStateByTab.get(tabId) ?? new Map<string, FrameState>();
  if (!frameMap.has(key) && frameMap.size >= MAX_FRAMES_PER_TAB) {
    return;
  }
  const videos = Array.isArray(message.videos)
    ? message.videos
        .slice(0, MAX_VIDEOS_PER_TAB)
        .map(sanitizeVideoCandidate)
        .filter((value: WorkerVideoCandidate | null): value is WorkerVideoCandidate => value !== null)
    : [];
  frameMap.set(key, {
    frameId: typeof sender?.frameId === "number" ? sender.frameId : 0,
    title: truncateUTF8(
      message.page?.title ?? sender?.tab?.title,
      MAX_TITLE_BYTES,
      "Untitled tab",
    ),
    url: truncateUTF8(
      message.page?.url ?? sender?.tab?.url,
      MAX_URL_BYTES,
      "",
    ),
    videos,
  });
  frameStateByTab.set(tabId, frameMap);

  sendState();
}

function onVideosClear(sender: any): void {
  const tabId = sender?.tab?.id;
  if (typeof tabId !== "number") {
    return;
  }

  const key = frameKey(sender);
  const frameMap = frameStateByTab.get(tabId);
  if (!frameMap) {
    return;
  }

  frameMap.delete(key);
  if (frameMap.size === 0) {
    frameStateByTab.delete(tabId);
  }

  sendState();
}

async function handleCompanionMessage(
  raw: unknown,
  sourceSocket: WebSocket,
): Promise<void> {
  if (socket !== sourceSocket) {
    return;
  }
  if (typeof raw !== "string") {
    sourceSocket.close(1003, "Companion message was not text");
    return;
  }
  if (new TextEncoder().encode(raw).byteLength > 512 * 1024) {
    sourceSocket.close(1009, "Companion message was too large");
    return;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    sourceSocket.close(1008, "Invalid JSON from companion");
    return;
  }

  log("<- companion", parsed);

  if (!authenticationSession?.isAuthenticated) {
    if (!authenticationSession && authenticationSessionReady) {
      await authenticationSessionReady;
    }
    if (socket !== sourceSocket) {
      return;
    }
    if (!authenticationSession) {
      sourceSocket.close(1008, "Authentication session unavailable");
      return;
    }
    const action = await authenticationSession.handle(parsed);
    setPairingStatus(action.status);
    if (action.send && sourceSocket.readyState === WebSocket.OPEN) {
      sourceSocket.send(JSON.stringify(action.send));
    }
    if (action.closeCode) {
      sourceSocket.close(action.closeCode, "Authentication failed");
      return;
    }
    if (action.authenticated) {
      reconnectBackoff.reset();
      sendSocketMessage({
        type: FloatProtocol.messageType.hello,
        source: "extension",
      });
      sendState();
      flushPendingSocketMessages();
    }
    return;
  }

  if (
    !parsed ||
    typeof parsed !== "object" ||
    (parsed as Record<string, unknown>).version !== FloatProtocol.version
  ) {
    sourceSocket.close(1008, "Unsupported protocol version");
    return;
  }

  const parsedType = FloatProtocolReadTypeField(parsed);
  if (parsedType === FloatProtocol.messageType.hello) {
    return;
  }

  if (FloatProtocolIsStartMessage(parsed)) {
    autoStartTransitions.cancelAll();
    sendStartToTab(parsed.tabId, parsed.videoId);
    return;
  }

  if (FloatProtocolIsStopMessage(parsed)) {
    const pauseSource = parsed.pauseSource === true;
    if (pauseSource) {
      const sourceTabId =
        typeof parsed.tabId === "number" ? parsed.tabId : null;
      const sourceVideoId =
        typeof parsed.videoId === "string" ? parsed.videoId : null;
      const sourceGeneration =
        typeof parsed.generation === "number" ? parsed.generation : null;
      if (
        sourceTabId === null ||
        sourceVideoId === null ||
        sourceGeneration === null
      ) {
        return;
      }
      if (!activeStreamTarget && autoStartTransitions.has(sourceTabId)) {
        return;
      }
      if (
        activeStreamTarget &&
        (activeStreamTarget.tabId !== sourceTabId ||
          activeStreamTarget.videoId !== sourceVideoId ||
          activeStreamTarget.generation !== sourceGeneration)
      ) {
        return;
      }

      activeStreamTarget = null;
      desiredMutedTabId = null;
      // Consume this tab transition so only a fresh activation can auto-start
      // the source again after the native PiP window is dismissed.
      backgroundedTabIds.delete(sourceTabId);
      cancelPendingAutoStart(sourceTabId);
      restoreMutedTabIfNeeded(sourceTabId);

      // Broadcast within the source tab. Only the frame that owns the active
      // or in-flight video accepts the generation-bound command.
      sendMessageToTab(
        sourceTabId,
        {
          type: "float:pauseAndStop",
          videoId: sourceVideoId,
          generation: sourceGeneration,
        },
        undefined,
        (reason) => {
          log("Failed to pause source while stopping PiP", reason);
        },
      );
      return;
    }

    autoStartTransitions.cancelAll();
    activeStreamTarget = null;
    desiredMutedTabId = null;
    restoreMutedTabIfNeeded();
    const commandToken = nextMediaCommandToken();
    queryTabs(
      {},
      (tabs) => {
        tabs.forEach((tab) => {
          if (typeof tab.id === "number") {
            sendMessageToTab(tab.id, {
              type: "float:stop",
              commandToken,
            });
          }
        });
      },
      (reason) => {
        log("Failed to enumerate tabs for stop", reason);
      },
    );
    return;
  }

  if (FloatProtocolIsAutoStartBackgroundMessage(parsed)) {
    autoStartBackgroundEnabled = parsed.enabled;
    if (!parsed.enabled) {
      autoStartTransitions.cancelAll();
    }
    return;
  }

  if (FloatProtocolIsAutoStopForegroundMessage(parsed)) {
    autoStopForegroundEnabled = parsed.enabled;
    return;
  }

  if (FloatProtocolIsPlaybackMessage(parsed)) {
    sendSignalMessageToActiveTarget(parsed.tabId, parsed.videoId, {
      type: "float:playback",
      videoId: parsed.videoId,
      playing: parsed.playing,
    });
    return;
  }

  if (FloatProtocolIsSeekMessage(parsed)) {
    sendSignalMessageToActiveTarget(parsed.tabId, parsed.videoId, {
      type: "float:seek",
      videoId: parsed.videoId,
      intervalSeconds: parsed.intervalSeconds,
    });
    return;
  }

  if (FloatProtocolIsQualityHintMessage(parsed)) {
    sendSignalMessageToActiveTarget(parsed.tabId, parsed.videoId, {
      type: "float:qualityHint",
      videoId: parsed.videoId,
      profile: parsed.profile,
      pipWidth: parsed.pipWidth,
      pipHeight: parsed.pipHeight,
    });
    return;
  }

  if (FloatProtocolIsAnswerMessage(parsed)) {
    if (
      parsed.sdp.length === 0 ||
      utf8ByteLength(parsed.sdp) > MAX_SDP_BYTES ||
      utf8ByteLength(parsed.videoId) > MAX_VIDEO_ID_BYTES
    ) {
      sourceSocket.close(1009, "Answer exceeded protocol limits");
      return;
    }
    sendSignalMessageToActiveTarget(parsed.tabId, parsed.videoId, {
      type: "float:signal:answer",
      videoId: parsed.videoId,
      generation: parsed.generation,
      sdp: parsed.sdp,
    });
    return;
  }

  if (FloatProtocolIsIceMessage(parsed)) {
    if (
      parsed.candidate.length === 0 ||
      utf8ByteLength(parsed.candidate) > MAX_ICE_BYTES ||
      utf8ByteLength(parsed.videoId) > MAX_VIDEO_ID_BYTES
    ) {
      sourceSocket.close(1009, "ICE candidate exceeded protocol limits");
      return;
    }
    sendSignalMessageToActiveTarget(parsed.tabId, parsed.videoId, {
      type: "float:signal:ice",
      videoId: parsed.videoId,
      generation: parsed.generation,
      candidate: parsed.candidate,
      sdpMid: parsed.sdpMid,
      sdpMLineIndex: parsed.sdpMLineIndex,
    });
    return;
  }

  if (FloatProtocolIsErrorMessage(parsed)) {
    const target = activeStreamTarget;
    if (
      target &&
      (typeof parsed.tabId === "undefined" || parsed.tabId === target.tabId) &&
      (typeof parsed.videoId === "undefined" || parsed.videoId === target.videoId) &&
      (typeof parsed.generation === "undefined" ||
        parsed.generation === target.generation)
    ) {
      const stopMessage: Record<string, unknown> = {
        type: "float:stop",
        commandToken: nextMediaCommandToken(),
      };
      if (target.generation !== null) {
        stopMessage.videoId = target.videoId;
        stopMessage.generation = target.generation;
        stopMessage.requestToken = target.requestToken;
      }
      activeStreamTarget = null;
      desiredMutedTabId = null;
      restoreMutedTabIfNeeded(target.tabId);
      sendMessageToTab(
        target.tabId,
        stopMessage,
        typeof target.frameId === "number" ? { frameId: target.frameId } : undefined,
      );
    }
    return;
  }

  sourceSocket.close(
    1008,
    `Unsupported companion message type: ${parsedType ?? "unknown"}`,
  );
}

serviceWorkerExt.runtime.onInstalled.addListener(() => {
  connectToCompanion();
});

serviceWorkerExt.runtime.onStartup.addListener(() => {
  connectToCompanion();
});

// Firefox background scripts can load without firing onStartup/onInstalled immediately.
// Connect eagerly so float:videos:update state can be forwarded right away.

serviceWorkerExt.runtime.onMessage.addListener(
  (message: any, sender: any, sendResponse: (response: unknown) => void) => {
  if (
    message?.type === "float:pairing:status:get" &&
    isTrustedExtensionPage(sender)
  ) {
    void pairingCredentialRepository
      .load()
      .then((secret) => sendResponse({ status: pairingStatus, paired: Boolean(secret) }))
      .catch(() => sendResponse({ status: "unpaired", paired: false }));
    return true;
  }

  if (
    message?.type === "float:pairing:save" &&
    isTrustedExtensionPage(sender)
  ) {
    if (
      typeof message.secret !== "string" ||
      !FloatSecurity.validatePairingSecret(message.secret)
    ) {
      sendResponse({ ok: false, error: "invalid pairing secret" });
      return false;
    }
    void pairingCredentialRepository
      .save(message.secret)
      .then(() => {
        reconnectAfterPairingChange();
        sendResponse({ ok: true });
      })
      .catch(() => sendResponse({ ok: false, error: "credential save failed" }));
    return true;
  }

  if (
    message?.type === "float:pairing:remove" &&
    isTrustedExtensionPage(sender)
  ) {
    void pairingCredentialRepository
      .remove()
      .then(() => {
        reconnectAfterPairingChange();
        setPairingStatus("unpaired");
        sendResponse({ ok: true });
      })
      .catch(() => sendResponse({ ok: false, error: "credential removal failed" }));
    return true;
  }

  connectToCompanion();

  if (!message || typeof message.type !== "string") {
    return;
  }

  if (message.type === "float:videos:update") {
    onVideosUpdate(message, sender);
    return;
  }

  if (message.type === "float:videos:clear") {
    onVideosClear(sender);
    return;
  }

  if (message.type === "float:autoStart:candidate") {
    onAutoStartCandidate(message, sender);
    return;
  }

  if (message.type === "float:autoStart:rejected") {
    onAutoStartRejected(message, sender);
    return;
  }

  if (message.type === "float:webrtc:offer") {
    onOfferFromContent(message, sender);
    return;
  }

  if (message.type === "float:webrtc:ice") {
    onIceFromContent(message, sender);
    return;
  }

  if (message.type === "float:webrtc:error") {
    onErrorFromContent(message, sender);
    return;
  }

  if (message.type === "float:webrtc:stopped") {
    const stoppedActiveTarget =
      activeStreamTarget &&
      sender?.tab?.id === activeStreamTarget.tabId &&
      message.videoId === activeStreamTarget.videoId &&
      message.requestToken === activeStreamTarget.requestToken &&
      message.generation === activeStreamTarget.generation;
    if (!stoppedActiveTarget) {
      return;
    }

    activeStreamTarget = null;
    if (sender?.tab?.id === mutedTabState?.tabId) {
      desiredMutedTabId = null;
      restoreMutedTabIfNeeded(sender.tab.id);
    }
    sendSocketMessage({
      type: FloatProtocol.messageType.stop,
    });
    return;
  }

  if (message.type === "float:debug") {
    onDebugFromContent(message, sender);
  }
  return false;
});

function rememberSeededActiveTabs(tabs: any[]): void {
  for (const tab of tabs) {
    if (
      Number.isSafeInteger(tab?.id) &&
      tab.id >= 0 &&
      Number.isSafeInteger(tab?.windowId) &&
      tab.windowId >= 0 &&
      !activeTabIdByWindow.has(tab.windowId)
    ) {
      activeTabIdByWindow.set(tab.windowId, tab.id);
    }
  }
}

function seedActiveTabTracking(): void {
  queryTabs(
    { active: true },
    rememberSeededActiveTabs,
    () => {
      // A cold worker safely misses one transition rather than guessing a source tab.
    },
  );
}

serviceWorkerExt.tabs.onActivated.addListener(
  (activeInfo: {
    tabId: number;
    windowId: number;
    previousTabId?: number;
  }) => {
    if (
      !Number.isSafeInteger(activeInfo.tabId) ||
      activeInfo.tabId < 0 ||
      !Number.isSafeInteger(activeInfo.windowId) ||
      activeInfo.windowId < 0
    ) {
      return;
    }

    const previousTabId = FloatProtocolPreviousTabForActivation(
      activeTabIdByWindow,
      activeInfo,
    );
    activeTabIdByWindow.set(activeInfo.windowId, activeInfo.tabId);

    cancelPendingAutoStart(activeInfo.tabId);
    backgroundedTabIds.delete(activeInfo.tabId);
    if (autoStopForegroundEnabled) {
      stopStreamForForegroundTab(activeInfo.tabId);
    }

    if (previousTabId === null) {
      return;
    }

    backgroundedTabIds.add(previousTabId);
    beginAutoStartForTabActivation(previousTabId);
  },
);

seedActiveTabTracking();

serviceWorkerExt.tabs.onRemoved.addListener((tabId: number) => {
  frameStateByTab.delete(tabId);
  backgroundedTabIds.delete(tabId);
  cancelPendingAutoStart(tabId);
  for (const [windowId, activeTabId] of activeTabIdByWindow.entries()) {
    if (activeTabId === tabId) {
      activeTabIdByWindow.delete(windowId);
    }
  }
  stopActiveStreamForTabLifecycle(tabId, true);
  sendState();
});

serviceWorkerExt.tabs.onUpdated.addListener(
  (tabId: number, changeInfo: { status?: string; url?: string }) => {
    if (changeInfo.status !== "loading" && typeof changeInfo.url !== "string") {
      return;
    }
    frameStateByTab.delete(tabId);
    backgroundedTabIds.delete(tabId);
    cancelPendingAutoStart(tabId);
    stopActiveStreamForTabLifecycle(tabId, false);
    sendState();
  },
);

connectToCompanion();
