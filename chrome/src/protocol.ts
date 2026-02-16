const globalScope = globalThis as typeof globalThis & Record<string, unknown>;

if (!globalScope.FloatProtocol) {
  globalScope.FloatProtocol = {
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

function isStopMessage(message: unknown): message is { type: "stop" } {
  return isUnknownRecord(message) && message.type === FloatProtocol.messageType.stop;
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
): message is { type: "answer"; tabId: number; videoId: string; sdp: string } {
  if (!isUnknownRecord(message)) {
    return false;
  }

  return (
    message.type === FloatProtocol.messageType.answer &&
    typeof message.tabId === "number" &&
    typeof message.videoId === "string" &&
    typeof message.sdp === "string"
  );
}

function isIceMessage(
  message: unknown,
): message is {
  type: "ice";
  tabId: number;
  videoId: string;
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
    typeof message.candidate === "string" &&
    (typeof mid === "string" || mid === null) &&
    (typeof mLine === "number" || mLine === null)
  );
}

function asErrorMessage(reason: string): { type: "error"; reason: string } {
  return {
    type: FloatProtocol.messageType.error,
    reason,
  };
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
globalScope.FloatProtocolError = asErrorMessage;
