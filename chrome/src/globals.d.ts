declare const chrome: any;

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
declare var FloatProtocolIsPlaybackMessage: (
  message: unknown,
) => message is { type: "playback"; tabId: number; videoId: string; playing: boolean };
declare var FloatProtocolIsSeekMessage: (
  message: unknown,
) => message is { type: "seek"; tabId: number; videoId: string; intervalSeconds: number };
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
}
