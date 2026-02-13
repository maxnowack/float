declare function importScripts(...urls: string[]): void;

importScripts("./protocol.js");

const companionPort = 17891;
const companionUrl = `ws://127.0.0.1:${companionPort}`;
const debugLogEnabled = false;

type WorkerVideoCandidate = {
  videoId: string;
  playing: boolean;
  muted: boolean;
  resolution: string;
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

const frameStateByTab = new Map<number, Map<string, FrameState>>();
let socket: WebSocket | null = null;
let reconnectTimer: number | null = null;
let activeStreamTarget: { tabId: number; videoId: string } | null = null;

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
  });

  socket.addEventListener("message", (event) => {
    handleCompanionMessage(event.data);
  });

  socket.addEventListener("close", () => {
    log("Companion socket closed");
    socket = null;
    scheduleReconnect();
  });

  socket.addEventListener("error", () => {
    log("Companion socket error");
    socket?.close();
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
    return;
  }

  socket.send(JSON.stringify(payload));
  log("-> companion", payload);
}

function sendProtocolError(reason: string): void {
  sendSocketMessage(FloatProtocolError(reason));
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
    activeStreamTarget = { tabId: parsed.tabId, videoId: parsed.videoId };
    chrome.tabs.sendMessage(parsed.tabId, {
      type: "float:start",
      videoId: parsed.videoId,
    });
    return;
  }

  if (FloatProtocolIsStopMessage(parsed)) {
    activeStreamTarget = null;
    chrome.tabs.query({}, (tabs: any[]) => {
      tabs.forEach((tab) => {
        if (typeof tab.id === "number") {
          chrome.tabs.sendMessage(tab.id, { type: "float:stop" });
        }
      });
    });
    return;
  }

  if (FloatProtocolIsAnswerMessage(parsed)) {
    chrome.tabs.sendMessage(parsed.tabId, {
      type: "float:signal:answer",
      videoId: parsed.videoId,
      sdp: parsed.sdp,
    });
    return;
  }

  if (FloatProtocolIsIceMessage(parsed)) {
    chrome.tabs.sendMessage(parsed.tabId, {
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

chrome.runtime.onInstalled.addListener(() => {
  connectToCompanion();
});

chrome.runtime.onStartup.addListener(() => {
  connectToCompanion();
});

chrome.runtime.onMessage.addListener((message: any, sender: any) => {
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
    sendSocketMessage({
      type: FloatProtocol.messageType.stop,
    });
    return;
  }

  if (message.type === "float:debug") {
    onDebugFromContent(message, sender);
  }
});

chrome.tabs.onRemoved.addListener((tabId: number) => {
  frameStateByTab.delete(tabId);
  sendState();
});

connectToCompanion();
