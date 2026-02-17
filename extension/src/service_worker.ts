declare function importScripts(...urls: string[]): void;

const maybeImportScripts = (globalThis as any).importScripts as
  | ((...urls: string[]) => void)
  | undefined;
if (typeof maybeImportScripts === "function") {
  maybeImportScripts("./protocol.js");
}

const companionPort = 17891;
const companionUrl = `ws://127.0.0.1:${companionPort}`;
const debugLogEnabled = false;
const serviceWorkerExt: any = (globalThis as any).chrome ?? (globalThis as any).browser;
const isFirefoxExtension = serviceWorkerExt === (globalThis as any).browser;
const shouldMuteSourceTabDuringStreaming = !isFirefoxExtension;

function ensureProtocolGlobals(): void {
  const scope = globalThis as any;
  if (scope.FloatProtocol) {
    return;
  }

  scope.FloatProtocol = {
    version: 1,
    messageType: {
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
  scope.FloatProtocolIsStopMessage = (message: unknown): boolean =>
    isRecord(message) && message.type === scope.FloatProtocol.messageType.stop;
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
      typeof message.candidate === "string" &&
      (typeof mid === "string" || mid === null) &&
      (typeof mLine === "number" || mLine === null)
    );
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

const frameStateByTab = new Map<number, Map<string, FrameState>>();
let socket: WebSocket | null = null;
let reconnectTimer: number | null = null;
let activeStreamTarget: { tabId: number; videoId: string; frameId: number | null } | null = null;
let mutedTabState: MutedTabState | null = null;
let desiredMutedTabId: number | null = null;
let autoStartBackgroundEnabled = false;
let autoStopForegroundEnabled = true;
const pendingSocketMessages: unknown[] = [];
const MAX_PENDING_SOCKET_MESSAGES = 256;

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

function activeTargetFrameId(tabId: number, videoId: string): number | null {
  if (!activeStreamTarget) {
    return null;
  }
  if (activeStreamTarget.tabId !== tabId || activeStreamTarget.videoId !== videoId) {
    return null;
  }
  return typeof activeStreamTarget.frameId === "number" ? activeStreamTarget.frameId : null;
}

function sendSignalMessageToActiveTarget(
  tabId: number,
  videoId: string,
  message: unknown,
  retryAttempt = 0,
): void {
  const frameId = activeTargetFrameId(tabId, videoId);
  const options = typeof frameId === "number" ? { frameId } : undefined;
  sendMessageToTab(tabId, message, options, (reason) => {
    if (!isMissingReceiverError(reason)) {
      return;
    }
    if (retryAttempt >= 5) {
      return;
    }
    self.setTimeout(() => {
      sendSignalMessageToActiveTarget(tabId, videoId, message, retryAttempt + 1);
    }, 120 * (retryAttempt + 1));
  });
}

function connectToCompanion(): void {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) {
    return;
  }

  log(`Connecting to ${companionUrl}`);
  socket = new WebSocket(companionUrl);

  socket.addEventListener("open", () => {
    const hello = {
      type: FloatProtocol.messageType.hello,
      version: FloatProtocol.version,
      source: "extension",
    };
    sendSocketMessage(hello);
    sendState();
    flushPendingSocketMessages();
  });

  socket.addEventListener("message", (event) => {
    handleCompanionMessage(event.data);
  });

  socket.addEventListener("close", () => {
    log("Companion socket closed");
    stopStreamingAfterCompanionDisconnect();
    socket = null;
    scheduleReconnect();
  });

  socket.addEventListener("error", () => {
    log("Companion socket error");
    socket?.close();
  });
}

function stopStreamingAfterCompanionDisconnect(): void {
  if (!activeStreamTarget && !mutedTabState) {
    return;
  }

  activeStreamTarget = null;
  desiredMutedTabId = null;
  restoreMutedTabIfNeeded();

  serviceWorkerExt.tabs.query({}, (tabs: any[]) => {
    tabs.forEach((tab) => {
      if (typeof tab.id === "number") {
        sendMessageToTab(tab.id, { type: "float:stop" });
      }
    });
  });
}

function scheduleReconnect(): void {
  if (reconnectTimer !== null) {
    return;
  }

  reconnectTimer = self.setTimeout(() => {
    reconnectTimer = null;
    connectToCompanion();
  }, 1000);
}

function sendSocketMessage(payload: unknown): void {
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    queueSocketMessage(payload);
    connectToCompanion();
    return;
  }

  socket.send(JSON.stringify(payload));
  log("-> companion", payload);
}

function flushPendingSocketMessages(): void {
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    return;
  }

  while (pendingSocketMessages.length > 0) {
    const payload = pendingSocketMessages.shift();
    if (typeof payload === "undefined") {
      continue;
    }
    socket.send(JSON.stringify(payload));
    log("-> companion (flushed)", payload);
  }
}

function queueSocketMessage(payload: unknown): void {
  const payloadType = FloatProtocolReadTypeField(payload);
  if (payloadType === FloatProtocol.messageType.debug) {
    return;
  }

  if (payloadType === FloatProtocol.messageType.state) {
    for (let i = pendingSocketMessages.length - 1; i >= 0; i -= 1) {
      if (FloatProtocolReadTypeField(pendingSocketMessages[i]) === FloatProtocol.messageType.state) {
        pendingSocketMessages.splice(i, 1);
      }
    }
  }

  pendingSocketMessages.push(payload);
  if (pendingSocketMessages.length > MAX_PENDING_SOCKET_MESSAGES) {
    pendingSocketMessages.splice(0, pendingSocketMessages.length - MAX_PENDING_SOCKET_MESSAGES);
  }
}

function sendProtocolError(reason: string): void {
  sendSocketMessage(FloatProtocolError(reason));
}

function chooseAutoStartVideo(videos: WorkerVideoCandidate[]): WorkerVideoCandidate | null {
  if (videos.length === 0) {
    return null;
  }
  const playingVideo = videos.find((video) => video.playing);
  return playingVideo ?? videos[0] ?? null;
}

function sendStartToTab(tabId: number, videoId: string): void {
  activeStreamTarget = { tabId, videoId, frameId: null };
  desiredMutedTabId = shouldMuteSourceTabDuringStreaming ? tabId : null;

  sendMessageToTab(
    tabId,
    {
      type: "float:start",
      videoId,
    },
    undefined,
    (reason) => {
      log("Failed to send start message", reason);
      if (activeStreamTarget?.tabId === tabId && activeStreamTarget.videoId === videoId) {
        activeStreamTarget = null;
      }
      if (desiredMutedTabId === tabId) {
        desiredMutedTabId = null;
      }
      restoreMutedTabIfNeeded(tabId);
    },
  );
}

function maybeAutoStartBackgroundTab(tabId: number): void {
  if (!autoStartBackgroundEnabled || activeStreamTarget) {
    return;
  }

  const tabState = flattenTabState(tabId);
  if (!tabState) {
    return;
  }

  const candidate = chooseAutoStartVideo(tabState.videos);
  if (!candidate) {
    return;
  }

  sendStartToTab(tabId, candidate.videoId);
}

function stopStreamForForegroundTab(tabId: number): void {
  if (!activeStreamTarget || activeStreamTarget.tabId !== tabId) {
    return;
  }

  const sourceTabId = activeStreamTarget.tabId;
  activeStreamTarget = null;
  desiredMutedTabId = null;
  restoreMutedTabIfNeeded(sourceTabId);

  sendMessageToTab(sourceTabId, { type: "float:stop" }, undefined, (reason) => {
    log("Failed to send stop message for foreground tab", reason);
    sendSocketMessage({ type: FloatProtocol.messageType.stop });
  });
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
      }
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
  const payload = buildStatePayload();
  sendSocketMessage(payload);
}

function onOfferFromContent(message: any, sender: any): void {
  const tabId = sender?.tab?.id;
  if (typeof tabId !== "number" || typeof message.videoId !== "string" || typeof message.sdp !== "string") {
    sendProtocolError("Invalid offer message from content script");
    return;
  }

  muteTabForStreaming(tabId);
  activeStreamTarget = {
    tabId,
    videoId: message.videoId,
    frameId: typeof sender?.frameId === "number" ? sender.frameId : null,
  };
  desiredMutedTabId = shouldMuteSourceTabDuringStreaming ? tabId : null;

  sendSocketMessage({
    type: FloatProtocol.messageType.offer,
    tabId,
    videoId: message.videoId,
    sdp: message.sdp,
  });
}

function onIceFromContent(message: any, sender: any): void {
  const tabId = sender?.tab?.id;
  if (typeof tabId !== "number" || typeof message.videoId !== "string" || typeof message.candidate !== "string") {
    sendProtocolError("Invalid ICE message from content script");
    return;
  }

  sendSocketMessage({
    type: FloatProtocol.messageType.ice,
    tabId,
    videoId: message.videoId,
    candidate: message.candidate,
    sdpMid: typeof message.sdpMid === "string" ? message.sdpMid : null,
    sdpMLineIndex: typeof message.sdpMLineIndex === "number" ? message.sdpMLineIndex : null,
  });
}

function onErrorFromContent(message: any, sender: any): void {
  const tabId = sender?.tab?.id;
  const reason = typeof message.reason === "string" ? message.reason : "unknown content script error";
  sendSocketMessage({
    type: FloatProtocol.messageType.error,
    tabId: typeof tabId === "number" ? tabId : -1,
    videoId: typeof message.videoId === "string" ? message.videoId : null,
    reason,
  });

  if (
    activeStreamTarget &&
    tabId === activeStreamTarget.tabId &&
    (typeof message.videoId !== "string" || message.videoId === activeStreamTarget.videoId)
  ) {
    activeStreamTarget = null;
    desiredMutedTabId = null;
    restoreMutedTabIfNeeded(tabId);
  }
}

function onDebugFromContent(message: any, sender: any): void {
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

function onVideosUpdate(message: any, sender: any): void {
  const tabId = sender?.tab?.id;
  if (typeof tabId !== "number") {
    return;
  }

  const key = frameKey(sender);
  const frameMap = frameStateByTab.get(tabId) ?? new Map<string, FrameState>();
  frameMap.set(key, {
    title: message.page?.title ?? sender?.tab?.title ?? "Untitled tab",
    url: message.page?.url ?? sender?.tab?.url ?? "",
    videos: Array.isArray(message.videos) ? message.videos : [],
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

function handleCompanionMessage(raw: unknown): void {
  if (typeof raw !== "string") {
    sendProtocolError("Companion message was not text");
    return;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    const reason = error instanceof Error ? error.message : "unknown parse error";
    sendProtocolError(`Invalid JSON from companion: ${reason}`);
    return;
  }

  log("<- companion", parsed);

  const parsedType = FloatProtocolReadTypeField(parsed);
  if (parsedType === FloatProtocol.messageType.hello || parsedType === "hello") {
    return;
  }

  if (FloatProtocolIsStartMessage(parsed)) {
    sendStartToTab(parsed.tabId, parsed.videoId);
    return;
  }

  if (FloatProtocolIsStopMessage(parsed)) {
    activeStreamTarget = null;
    desiredMutedTabId = null;
    restoreMutedTabIfNeeded();
    serviceWorkerExt.tabs.query({}, (tabs: any[]) => {
      tabs.forEach((tab) => {
        if (typeof tab.id === "number") {
          sendMessageToTab(tab.id, { type: "float:stop" });
        }
      });
    });
    return;
  }

  if (FloatProtocolIsAutoStartBackgroundMessage(parsed)) {
    autoStartBackgroundEnabled = parsed.enabled;
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
    sendSignalMessageToActiveTarget(parsed.tabId, parsed.videoId, {
      type: "float:signal:answer",
      videoId: parsed.videoId,
      sdp: parsed.sdp,
    });
    return;
  }

  if (FloatProtocolIsIceMessage(parsed)) {
    sendSignalMessageToActiveTarget(parsed.tabId, parsed.videoId, {
      type: "float:signal:ice",
      videoId: parsed.videoId,
      candidate: parsed.candidate,
      sdpMid: parsed.sdpMid,
      sdpMLineIndex: parsed.sdpMLineIndex,
    });
    return;
  }

  sendProtocolError(`Unsupported companion message type: ${parsedType ?? "unknown"}`);
}

serviceWorkerExt.runtime.onInstalled.addListener(() => {
  connectToCompanion();
});

serviceWorkerExt.runtime.onStartup.addListener(() => {
  connectToCompanion();
});

// Firefox background scripts can load without firing onStartup/onInstalled immediately.
// Connect eagerly so float:videos:update state can be forwarded right away.
connectToCompanion();

serviceWorkerExt.runtime.onMessage.addListener((message: any, sender: any) => {
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

  if (message.type === "float:tab:background") {
    if (sender?.frameId === 0 && typeof sender?.tab?.id === "number") {
      maybeAutoStartBackgroundTab(sender.tab.id);
    }
    return;
  }

  if (message.type === "float:tab:foreground") {
    if (autoStopForegroundEnabled && sender?.frameId === 0 && typeof sender?.tab?.id === "number") {
      stopStreamForForegroundTab(sender.tab.id);
    }
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
    if (
      activeStreamTarget &&
      sender?.tab?.id === activeStreamTarget.tabId &&
      message.videoId === activeStreamTarget.videoId
    ) {
      activeStreamTarget = null;
    }
    if (sender?.tab?.id === mutedTabState?.tabId) {
      desiredMutedTabId = activeStreamTarget?.tabId ?? null;
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
});

serviceWorkerExt.tabs.onRemoved.addListener((tabId: number) => {
  frameStateByTab.delete(tabId);
  if (mutedTabState?.tabId === tabId) {
    mutedTabState = null;
    desiredMutedTabId = null;
  }
  sendState();
});

connectToCompanion();
