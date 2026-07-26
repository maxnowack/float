declare const chrome: any;
declare const browser: any;

type FloatProtocolShape = {
  version: number;
  messageType: {
    authChallenge: "authChallenge";
    authResponse: "authResponse";
    authResult: "authResult";
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
declare var FloatSecurity: {
  encodeBase64URL(data: Uint8Array): string;
  decodeBase64URL(value: string): Uint8Array | null;
  canonicalAuthenticationInput(origin: string, nonce: string): Uint8Array;
  authenticationProof(secret: string, origin: string, nonce: string): Promise<string>;
  validatePairingSecret(value: string): boolean;
  randomHandshakeSubprotocol(): string;
  isTrustedExtensionPageSender(
    sender: unknown,
    expectedExtensionId: string,
    expectedPageUrl: string,
  ): boolean;
  PairingCredentialRepository: new (storage: any) => {
    load(): Promise<string | null>;
    save(value: string): Promise<void>;
    remove(): Promise<void>;
  };
  IndexedDBPairingCredentialStore: new (databaseFactory: IDBFactory) => {
    load(): Promise<unknown>;
    save(value: string): Promise<void>;
    remove(): Promise<void>;
  };
  BoundedProtocolMessageQueue: new (
    maximumCount: number,
    maximumBytes: number,
    protocolVersion: number,
  ) => {
    readonly count: number;
    readonly byteCount: number;
    enqueue(payload: unknown): boolean;
    drain(): unknown[];
    clear(): void;
  };
  CompanionAuthenticationSession: new (
    origin: string,
    secret: string | null,
  ) => {
    handle(message: unknown): Promise<{
      send?: Record<string, unknown>;
      closeCode?: number;
      status: "disconnected" | "unpaired" | "authenticating" | "connected";
      authenticated?: boolean;
    }>;
    readonly isAuthenticated: boolean;
  };
  ReconnectBackoff: new () => {
    nextDelayMilliseconds(): number;
    reset(): void;
  };
};
declare var FloatProtocolReadTypeField: (message: unknown) => string | null;
declare var FloatProtocolIsStartMessage: (
  message: unknown,
) => message is { type: "start"; tabId: number; videoId: string };
declare var FloatProtocolIsStopMessage: (
  message: unknown,
) => message is {
  type: "stop";
  pauseSource?: boolean;
  tabId?: number;
  videoId?: string;
  generation?: number;
};
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
) => message is {
  type: "answer";
  tabId: number;
  videoId: string;
  generation: number;
  sdp: string;
};
declare var FloatProtocolIsIceMessage: (
  message: unknown,
) => message is {
  type: "ice";
  tabId: number;
  videoId: string;
  generation: number;
  candidate: string;
  sdpMid: string | null;
  sdpMLineIndex: number | null;
};
declare var FloatProtocolIsErrorMessage: (
  message: unknown,
) => message is {
  type: "error";
  reason?: string;
  tabId?: number;
  videoId?: string;
  generation?: number;
};
declare var FloatProtocolError: (reason: string) => { type: "error"; reason: string };
declare var FloatProtocolVideoID: (randomBytes: Uint8Array, sequence: number) => string;
declare var FloatProtocolIsFirefoxExtensionOrigin: (origin: string) => boolean;
declare var FloatProtocolFrameIdForVideo: (
  frames: ReadonlyArray<{ frameId: number; videoIds: readonly string[] }>,
  videoId: string,
) => number | null;
declare var FloatProtocolPreviousTabForActivation: (
  activeTabIdByWindow: ReadonlyMap<number, number>,
  activeInfo: {
    tabId: number;
    windowId: number;
    previousTabId?: number;
  },
) => number | null;
declare var FloatProtocolAutoStartVideoId: (
  videos: ReadonlyArray<{ videoId: string; playing: boolean }>,
) => string | null;
declare var FloatProtocolOfferMatchesStartRequest: (
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
) => boolean;
declare var FloatProtocolMediaRequestMatches: (
  target: { tabId: number; requestToken: number } | null,
  request: { tabId: number; requestToken: number },
) => boolean;
declare var FloatProtocolStreamTargetMatches: (
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
) => boolean;
declare var FloatProtocolMediaSessionMatches: (
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
) => boolean;
declare var FloatProtocolShouldDeactivateContentScript: (
  runtimeId: unknown,
  error?: unknown,
) => boolean;
declare var FloatProtocolIsBenignOneWayMessageError: (
  error: unknown,
) => boolean;
declare var FloatProtocolIsNewerMediaCommandToken: (
  latestToken: number,
  candidateToken: unknown,
) => candidateToken is number;
declare var FloatProtocolIsFreshAutoStartSnapshot: (
  snapshot: {
    capturedAtMilliseconds: number;
    videoId: string | null;
  } | null,
  visibilityState: string,
  nowMilliseconds: number,
  maximumAgeMilliseconds: number,
) => boolean;
declare var FloatProtocolFreshAutoStartSnapshotVideoId: (
  snapshot: {
    capturedAtMilliseconds: number;
    videoId: string | null;
  } | null,
  visibilityState: string,
  nowMilliseconds: number,
  maximumAgeMilliseconds: number,
) => string | null;
declare var FloatProtocolAutoStartCaptureCoordinator: new () => {
  begin(token: number): void;
  cancel(token: number): void;
  cancelAll(): void;
  resolve(
    snapshot: {
      capturedAtMilliseconds: number;
      videoId: string | null;
    } | null,
    visibilityState: string,
    nowMilliseconds: number,
    maximumAgeMilliseconds: number,
  ): Array<{ token: number; videoId: string | null }>;
};
declare var FloatProtocolAutoStartTransitionLatch: new () => {
  begin(tabId: number): number;
  matches(tabId: number, token: number): boolean;
  has(tabId: number): boolean;
  consume(tabId: number, token: number): boolean;
  cancel(tabId: number): void;
  cancelAll(): void;
};
declare var FloatProtocolQueryTabsCompat: (
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
) => void;
declare var FloatProtocolNextMediaGeneration: (current: number) => number;

interface HTMLMediaElement {
  captureStream(): MediaStream;
  mozCaptureStream?(): MediaStream;
}
