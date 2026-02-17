declare const chrome: any;
declare const browser: any;

type FloatProtocolShape = {
  version: number;
  messageType: {
    hello: "hello";
    state: "state";
    start: "start";
    offer: "offer";
    answer: "answer";
    ice: "ice";
    stop: "stop";
    playback: "playback";
    seek: "seek";
    qualityHint: "qualityHint";
    autoStartBackground: "autoStartBackground";
    autoStopForeground: "autoStopForeground";
    error: "error";
    debug: "debug";
  };
};

declare var FloatProtocol: FloatProtocolShape;
declare var FloatProtocolReadTypeField: (message: unknown) => string | null;
declare var FloatProtocolIsStartMessage: (
  message: unknown,
) => message is { type: "start"; tabId: number; videoId: string };
declare var FloatProtocolIsStopMessage: (message: unknown) => message is { type: "stop" };
declare var FloatProtocolIsAutoStartBackgroundMessage: (
  message: unknown,
) => message is { type: "autoStartBackground"; enabled: boolean };
declare var FloatProtocolIsAutoStopForegroundMessage: (
  message: unknown,
) => message is { type: "autoStopForeground"; enabled: boolean };
declare var FloatProtocolIsPlaybackMessage: (
  message: unknown,
) => message is { type: "playback"; tabId: number; videoId: string; playing: boolean };
declare var FloatProtocolIsSeekMessage: (
  message: unknown,
) => message is { type: "seek"; tabId: number; videoId: string; intervalSeconds: number };
declare var FloatProtocolIsQualityHintMessage: (
  message: unknown,
) => message is {
  type: "qualityHint";
  tabId: number;
  videoId: string;
  profile: "high" | "balanced" | "performance";
  pipWidth?: number;
  pipHeight?: number;
};
declare var FloatProtocolIsAnswerMessage: (
  message: unknown,
) => message is { type: "answer"; tabId: number; videoId: string; sdp: string };
declare var FloatProtocolIsIceMessage: (
  message: unknown,
) => message is {
  type: "ice";
  tabId: number;
  videoId: string;
  candidate: string;
  sdpMid: string | null;
  sdpMLineIndex: number | null;
};
declare var FloatProtocolError: (reason: string) => { type: "error"; reason: string };

interface HTMLMediaElement {
  captureStream(): MediaStream;
  mozCaptureStream?(): MediaStream;
}
