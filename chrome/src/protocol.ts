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
globalScope.FloatProtocolIsAnswerMessage = isAnswerMessage;
globalScope.FloatProtocolIsIceMessage = isIceMessage;
globalScope.FloatProtocolError = asErrorMessage;
