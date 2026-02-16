type ContentVideoCandidate = {
  videoId: string;
  playing: boolean;
  muted: boolean;
  resolution: string;
  currentTime: number | null;
  duration: number | null;
};

type VideoMeta = {
  videoId: string;
  createdAt: number;
};

type VideoQualityProfileId = "high" | "balanced" | "performance";

type VideoQualityProfile = {
  maxWidth: number;
  maxHeight: number;
};

type VideoQualityHint = {
  profile: VideoQualityProfileId;
  pipWidth: number | null;
  pipHeight: number | null;
};

type VideoRenderTarget = {
  width: number;
  height: number;
  source: "pip" | "profile";
};

type AppliedVideoSenderSettings = {
  target: VideoRenderTarget;
  baseScaleDownBy: number;
  scaleDownBy: number;
  maxBitrateBps: number;
};

type VideoAdaptationCounters = {
  framesEncoded: number;
  totalEncodeTime: number;
  framesSent: number;
  framesDropped: number;
};

type VideoAdaptationState = {
  sender: RTCRtpSender;
  selectedVideoId: string;
  qualityHint: VideoQualityHint;
  target: VideoRenderTarget;
  baseScaleDownBy: number;
  scaleDownBy: number;
  pressureScaleMultiplier: number;
  maxBitrateBps: number;
  lastCounters: VideoAdaptationCounters | null;
  lowPressureSamples: number;
  updateInFlight: boolean;
};

const videoMeta = new WeakMap<HTMLVideoElement, VideoMeta>();
let videoCounter = 0;
let scheduled = false;
let activePeer: RTCPeerConnection | null = null;
let activeStream: MediaStream | null = null;
let activeVideoId: string | null = null;
let activeSourceVideo: HTMLVideoElement | null = null;
let senderStatsTimerId: number | null = null;
let activeVideoAdaptationState: VideoAdaptationState | null = null;
let requestedVideoQualityHint: VideoQualityHint = {
  profile: "high",
  pipWidth: null,
  pipHeight: null,
};
const qualityHintByVideoId = new Map<string, VideoQualityHint>();
let didNotifyBackgroundSinceForeground = false;
const FLOAT_MAX_VIDEO_FPS = 60;
const FLOAT_AUDIO_MAX_BITRATE_BPS = 320_000;
const FLOAT_VIDEO_ADAPTIVE_STATS_INTERVAL_MS = 2000;
const FLOAT_VIDEO_MAX_SCALE_DOWN_BY = 8;
const FLOAT_VIDEO_SCALE_CHANGE_EPSILON = 0.02;
const FLOAT_VIDEO_PRESSURE_MULTIPLIER_HIGH = 1.24;
const FLOAT_VIDEO_PRESSURE_MULTIPLIER_MEDIUM = 1.1;
const FLOAT_VIDEO_PRESSURE_RECOVERY_MULTIPLIER = 0.9;
const FLOAT_VIDEO_PRESSURE_RECOVERY_SAMPLE_THRESHOLD = 3;
const FLOAT_VIDEO_MIN_BITRATE_BPS = 4_000_000;
const FLOAT_VIDEO_MAX_BITRATE_BPS = 36_000_000;
const FLOAT_VIDEO_TARGET_BITS_PER_PIXEL = 0.11;
const FLOAT_VIDEO_DROP_RATIO_HIGH = 0.08;
const FLOAT_VIDEO_DROP_RATIO_MEDIUM = 0.03;
const FLOAT_VIDEO_ENCODE_MS_PER_FRAME_HIGH = 16;
const FLOAT_VIDEO_ENCODE_MS_PER_FRAME_MEDIUM = 12;
const FLOAT_ENABLE_EXPENSIVE_DEBUG_PROBES = (() => {
  try {
    return window.localStorage.getItem("float:debug:probes") === "1";
  } catch {
    return false;
  }
})();
const FLOAT_VIDEO_CODEC_PRIORITY = ["video/H264", "video/VP8", "video/VP9", "video/AV1"] as const;
const FLOAT_AUDIO_CODEC_PRIORITY = ["audio/opus", "audio/ISAC", "audio/G722", "audio/PCMU", "audio/PCMA"] as const;
const isTopFrame = (() => {
  try {
    return window.top === window;
  } catch {
    return false;
  }
})();

function debugLog(event: string, payload?: Record<string, unknown>): void {
  if (typeof payload === "undefined") {
    console.log(`[Float CS] ${event}`);
  } else {
    console.log(`[Float CS] ${event}`, payload);
  }

  chrome.runtime.sendMessage({
    type: "float:debug",
    source: "content-script",
    event,
    payload: payload ?? null,
    url: location.href,
  });
}

function getVideoQualityProfile(profileId: VideoQualityProfileId): VideoQualityProfile {
  switch (profileId) {
    case "high":
      return {
        maxWidth: 1920,
        maxHeight: 1080,
      };
    case "balanced":
      return {
        maxWidth: 1600,
        maxHeight: 900,
      };
    case "performance":
      return {
        maxWidth: 1280,
        maxHeight: 720,
      };
  }
}

function isVideoQualityProfileId(value: unknown): value is VideoQualityProfileId {
  return value === "high" || value === "balanced" || value === "performance";
}

function defaultVideoQualityHint(): VideoQualityHint {
  return {
    profile: "high",
    pipWidth: null,
    pipHeight: null,
  };
}

function sanitizePiPDimension(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    return null;
  }
  return Math.max(1, Math.round(value));
}

function normalizeVideoQualityHint(
  profile: VideoQualityProfileId,
  pipWidth: unknown,
  pipHeight: unknown,
): VideoQualityHint {
  const sanitizedPiPWidth = sanitizePiPDimension(pipWidth);
  const sanitizedPiPHeight = sanitizePiPDimension(pipHeight);
  if (sanitizedPiPWidth === null || sanitizedPiPHeight === null) {
    return {
      profile,
      pipWidth: null,
      pipHeight: null,
    };
  }
  return {
    profile,
    pipWidth: sanitizedPiPWidth,
    pipHeight: sanitizedPiPHeight,
  };
}

function areVideoQualityHintsEqual(left: VideoQualityHint, right: VideoQualityHint): boolean {
  return (
    left.profile === right.profile &&
    left.pipWidth === right.pipWidth &&
    left.pipHeight === right.pipHeight
  );
}

function resolveVideoRenderTarget(hint: VideoQualityHint): VideoRenderTarget {
  if (hint.pipWidth !== null && hint.pipHeight !== null) {
    return {
      width: hint.pipWidth,
      height: hint.pipHeight,
      source: "pip",
    };
  }

  const profile = getVideoQualityProfile(hint.profile);
  return {
    width: profile.maxWidth,
    height: profile.maxHeight,
    source: "profile",
  };
}

function roundScaleDownBy(value: number): number {
  return Math.round(value * 1000) / 1000;
}

function clampScaleDownBy(value: number): number {
  if (!Number.isFinite(value) || value <= 1) {
    return 1;
  }
  return Math.min(FLOAT_VIDEO_MAX_SCALE_DOWN_BY, roundScaleDownBy(value));
}

function readFiniteNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  return null;
}

function generateVideoId(element: HTMLVideoElement): string {
  const existing = videoMeta.get(element);
  if (existing) {
    return existing.videoId;
  }

  const creationStamp = Date.now();
  videoCounter += 1;
  const seed = `${location.href}|${window.frameElement ? "child" : "top"}|${creationStamp}|${videoCounter}`;
  const encoded = btoa(unescape(encodeURIComponent(seed))).replace(/=+$/g, "");
  const videoId = `vid_${encoded.slice(0, 24)}`;

  videoMeta.set(element, {
    videoId,
    createdAt: creationStamp,
  });

  return videoId;
}

function isEligible(video: HTMLVideoElement): boolean {
  const hasData = video.readyState >= 2;
  const hasTimeOrPlays = video.currentTime > 0 || !video.paused;
  const hasResolution = video.videoWidth > 0 && video.videoHeight > 0;
  return hasData && hasTimeOrPlays && hasResolution;
}

function collectCandidates(): ContentVideoCandidate[] {
  const candidates: ContentVideoCandidate[] = [];
  const videos = document.querySelectorAll("video");

  videos.forEach((video) => {
    if (!(video instanceof HTMLVideoElement)) {
      return;
    }

    const shouldInclude = isEligible(video) || (activeSourceVideo !== null && video === activeSourceVideo);
    if (!shouldInclude) {
      return;
    }

    const videoId = generateVideoId(video);
    const resolution = `${video.videoWidth}x${video.videoHeight}`;

    candidates.push({
      videoId,
      playing: !video.paused,
      muted: video.muted || video.volume === 0,
      resolution,
      currentTime: Number.isFinite(video.currentTime) ? video.currentTime : null,
      duration: Number.isFinite(video.duration) && video.duration > 0 ? video.duration : null,
    });
  });

  return candidates;
}

function emitState(): void {
  const payload = {
    type: "float:videos:update",
    frameId: window.frameElement ? "child" : "top",
    page: {
      title: document.title,
      url: location.href,
    },
    videos: collectCandidates(),
  };

  chrome.runtime.sendMessage(payload);
}

function notifyTabBackgrounded(trigger: string): void {
  if (!isTopFrame || didNotifyBackgroundSinceForeground) {
    return;
  }

  didNotifyBackgroundSinceForeground = true;
  chrome.runtime.sendMessage({
    type: "float:tab:background",
    trigger,
    page: {
      title: document.title,
      url: location.href,
    },
    visibilityState: document.visibilityState,
    hasFocus: document.hasFocus(),
  });
}

function notifyTabForegrounded(trigger: string): void {
  if (!isTopFrame || !didNotifyBackgroundSinceForeground) {
    return;
  }

  didNotifyBackgroundSinceForeground = false;
  chrome.runtime.sendMessage({
    type: "float:tab:foreground",
    trigger,
    page: {
      title: document.title,
      url: location.href,
    },
    visibilityState: document.visibilityState,
    hasFocus: document.hasFocus(),
  });
}

function markTabForegrounded(): void {
  didNotifyBackgroundSinceForeground = false;
}

function scheduleEmit(): void {
  if (scheduled) {
    return;
  }

  scheduled = true;
  window.setTimeout(() => {
    scheduled = false;
    emitState();
  }, 100);
}

function watchVideo(video: HTMLVideoElement): void {
  const events = [
    "play",
    "pause",
    "volumechange",
    "timeupdate",
    "loadedmetadata",
    "resize",
    "emptied",
    "seeking",
    "seeked",
  ];

  events.forEach((eventName) => {
    video.addEventListener(eventName, scheduleEmit, { passive: true });
  });
}

function refreshVideoWatchers(): void {
  document.querySelectorAll("video").forEach((node) => {
    if (node instanceof HTMLVideoElement) {
      watchVideo(node);
      generateVideoId(node);
    }
  });
}

const observer = new MutationObserver(() => {
  refreshVideoWatchers();
  scheduleEmit();
});

observer.observe(document.documentElement, {
  childList: true,
  subtree: true,
  attributes: true,
  attributeFilter: ["src", "style", "class"],
});

refreshVideoWatchers();
scheduleEmit();
window.setInterval(scheduleEmit, 2000);
if (isTopFrame) {
  window.addEventListener(
    "blur",
    () => {
      notifyTabBackgrounded("window.blur");
    },
    { passive: true },
  );

  window.addEventListener(
    "focus",
    () => {
      notifyTabForegrounded("window.focus");
    },
    { passive: true },
  );

  document.addEventListener(
    "visibilitychange",
    () => {
      if (document.visibilityState === "hidden") {
        notifyTabBackgrounded("document.visibilitychange.hidden");
        return;
      }
      notifyTabForegrounded("document.visibilitychange.visible");
    },
    { passive: true },
  );
}
window.addEventListener("beforeunload", () => {
  stopStreaming();
  chrome.runtime.sendMessage({
    type: "float:videos:clear",
  });
});

function findVideoById(targetVideoId: string): HTMLVideoElement | null {
  const videos = document.querySelectorAll("video");
  for (let index = 0; index < videos.length; index += 1) {
    const node = videos[index];
    if (node instanceof HTMLVideoElement && generateVideoId(node) === targetVideoId) {
      return node;
    }
  }
  return null;
}

function findBestAvailableVideo(): HTMLVideoElement | null {
  const videos = Array.from(document.querySelectorAll("video")).filter(
    (node): node is HTMLVideoElement => node instanceof HTMLVideoElement,
  );
  const eligible = videos.filter((video) => isEligible(video));
  if (eligible.length === 0) {
    return null;
  }

  eligible.sort((a, b) => {
    const aPlaying = a.paused ? 0 : 1;
    const bPlaying = b.paused ? 0 : 1;
    if (aPlaying !== bPlaying) {
      return bPlaying - aPlaying;
    }
    const aArea = Math.max(1, a.videoWidth) * Math.max(1, a.videoHeight);
    const bArea = Math.max(1, b.videoWidth) * Math.max(1, b.videoHeight);
    return bArea - aArea;
  });

  return eligible[0] ?? null;
}

function notifyWebRTCError(reason: string): void {
  chrome.runtime.sendMessage({
    type: "float:webrtc:error",
    reason,
    videoId: activeVideoId,
  });
}

function codecPriorityIndex(mimeType: string, preferredCodecs: readonly string[]): number {
  const normalizedMimeType = mimeType.toLowerCase();
  const index = preferredCodecs.findIndex((codec) => codec.toLowerCase() === normalizedMimeType);
  return index === -1 ? preferredCodecs.length : index;
}

function computeScaleResolutionDownBy(
  width: number | undefined,
  height: number | undefined,
  maxWidth: number,
  maxHeight: number,
): number {
  const safeWidth = typeof width === "number" && Number.isFinite(width) && width > 0 ? width : 0;
  const safeHeight = typeof height === "number" && Number.isFinite(height) && height > 0 ? height : 0;
  if (safeWidth <= 0 || safeHeight <= 0) {
    return 1;
  }

  const widthScale = safeWidth / maxWidth;
  const heightScale = safeHeight / maxHeight;
  const requiredScale = Math.max(1, widthScale, heightScale);
  if (!Number.isFinite(requiredScale) || requiredScale <= 1) {
    return 1;
  }

  // Keep a stable, bounded precision for browser encoder parameters.
  return Math.round(requiredScale * 1000) / 1000;
}

function computeVideoMaxBitrateBps(
  sourceWidth: number | undefined,
  sourceHeight: number | undefined,
  scaleDownBy: number,
  fallbackTarget: VideoRenderTarget,
): number {
  const safeScale = clampScaleDownBy(scaleDownBy);
  const safeSourceWidth =
    typeof sourceWidth === "number" && Number.isFinite(sourceWidth) && sourceWidth > 0
      ? sourceWidth
      : fallbackTarget.width;
  const safeSourceHeight =
    typeof sourceHeight === "number" && Number.isFinite(sourceHeight) && sourceHeight > 0
      ? sourceHeight
      : fallbackTarget.height;
  const encodedPixelArea = Math.max(1, (safeSourceWidth / safeScale) * (safeSourceHeight / safeScale));
  const estimatedBitrate = encodedPixelArea * FLOAT_MAX_VIDEO_FPS * FLOAT_VIDEO_TARGET_BITS_PER_PIXEL;
  return Math.round(Math.min(FLOAT_VIDEO_MAX_BITRATE_BPS, Math.max(FLOAT_VIDEO_MIN_BITRATE_BPS, estimatedBitrate)));
}

function computeVideoSenderSettings(
  sender: RTCRtpSender,
  hint: VideoQualityHint,
  requestedScaleDownBy: number | null = null,
): AppliedVideoSenderSettings {
  const target = resolveVideoRenderTarget(hint);
  const videoSettings = sender.track?.getSettings();
  const sourceWidth = videoSettings?.width;
  const sourceHeight = videoSettings?.height;
  const baseScaleDownBy = computeScaleResolutionDownBy(sourceWidth, sourceHeight, target.width, target.height);
  const desiredScaleDownBy = clampScaleDownBy(
    requestedScaleDownBy !== null ? Math.max(baseScaleDownBy, requestedScaleDownBy) : baseScaleDownBy,
  );
  return {
    target,
    baseScaleDownBy,
    scaleDownBy: desiredScaleDownBy,
    maxBitrateBps: computeVideoMaxBitrateBps(sourceWidth, sourceHeight, desiredScaleDownBy, target),
  };
}

function appendSdpFmtpParameter(line: string, key: string, value: string): string {
  const prefixEnd = line.indexOf(" ");
  if (prefixEnd < 0) {
    return line;
  }
  const prefix = line.slice(0, prefixEnd + 1);
  const rawValue = line.slice(prefixEnd + 1);
  const segments = rawValue
    .split(";")
    .map((segment) => segment.trim())
    .filter((segment) => segment.length > 0);
  const target = `${key}=${value}`;
  const keyPrefix = `${key}=`;
  const existingIndex = segments.findIndex((segment) => segment.toLowerCase().startsWith(keyPrefix.toLowerCase()));
  if (existingIndex >= 0) {
    segments[existingIndex] = target;
  } else {
    segments.push(target);
  }
  return `${prefix}${segments.join(";")}`;
}

function enforceStereoOpusInOfferSdp(offerSdp: string, selectedVideoId: string): string {
  const lines = offerSdp.split("\r\n");
  const opusPayloadTypes = new Set<string>();

  lines.forEach((line) => {
    const match = /^a=rtpmap:(\d+)\s+opus\/48000\/2$/i.exec(line);
    if (match?.[1]) {
      opusPayloadTypes.add(match[1]);
    }
  });

  if (opusPayloadTypes.size === 0) {
    return offerSdp;
  }

  let updated = false;
  const transformed = lines.map((line) => {
    const match = /^a=fmtp:(\d+)\s+/i.exec(line);
    if (!match?.[1] || !opusPayloadTypes.has(match[1])) {
      return line;
    }
    updated = true;
    let next = appendSdpFmtpParameter(line, "stereo", "1");
    next = appendSdpFmtpParameter(next, "sprop-stereo", "1");
    return next;
  });

  if (!updated) {
    const mutable = [...transformed];
    const opusPayloadType = Array.from(opusPayloadTypes)[0];
    for (let index = 0; index < mutable.length; index += 1) {
      const line = mutable[index];
      if (new RegExp(`^a=rtpmap:${opusPayloadType}\\s+opus/48000/2$`, "i").test(line)) {
        mutable.splice(index + 1, 0, `a=fmtp:${opusPayloadType} stereo=1;sprop-stereo=1`);
        updated = true;
        break;
      }
    }
    if (updated) {
      debugLog("sender.opusStereo.sdpUpdated", {
        selectedVideoId,
        mode: "inserted-fmtp",
      });
      return mutable.join("\r\n");
    }
  }

  if (updated) {
    debugLog("sender.opusStereo.sdpUpdated", {
      selectedVideoId,
      mode: "updated-fmtp",
    });
  }

  return transformed.join("\r\n");
}

function extractOpusFmtpLinesFromSdp(sdp: string): string[] {
  const lines = sdp.split("\r\n");
  const opusPayloadTypes = new Set<string>();
  lines.forEach((line) => {
    const match = /^a=rtpmap:(\d+)\s+opus\/48000\/2$/i.exec(line);
    if (match?.[1]) {
      opusPayloadTypes.add(match[1]);
    }
  });

  const opusFmtpLines: string[] = [];
  lines.forEach((line) => {
    const match = /^a=fmtp:(\d+)\s+/i.exec(line);
    if (!match?.[1] || !opusPayloadTypes.has(match[1])) {
      return;
    }
    opusFmtpLines.push(line);
  });

  return opusFmtpLines;
}

function logAudioTrackDiagnostics(selectedVideoId: string, audioTracks: MediaStreamTrack[]): void {
  const primaryAudioTrack = audioTracks[0];
  if (!primaryAudioTrack) {
    debugLog("source.track.audio.missing", { selectedVideoId });
    return;
  }

  let capabilities: MediaTrackCapabilities | null = null;
  try {
    capabilities = primaryAudioTrack.getCapabilities();
  } catch (error) {
    const reason = error instanceof Error ? error.message : "getCapabilities failed";
    debugLog("source.track.audioCapabilities.failed", {
      selectedVideoId,
      reason,
    });
  }

  debugLog("source.track.audio", {
    selectedVideoId,
    trackId: primaryAudioTrack.id,
    label: primaryAudioTrack.label,
    enabled: primaryAudioTrack.enabled,
    muted: primaryAudioTrack.muted,
    readyState: primaryAudioTrack.readyState,
    settings: primaryAudioTrack.getSettings(),
    constraints: primaryAudioTrack.getConstraints(),
    capabilities,
  });
}

function extractOutboundVideoStats(stats: RTCStatsReport): (RTCStats & Record<string, unknown>) | null {
  let outboundVideo: (RTCStats & Record<string, unknown>) | null = null;
  stats.forEach((item) => {
    const candidate = item as RTCStats & Record<string, unknown>;
    if (candidate.type !== "outbound-rtp") {
      return;
    }
    if (candidate.isRemote === true) {
      return;
    }
    const kind = (candidate.kind ?? candidate.mediaType) as string | undefined;
    if (kind !== "video") {
      return;
    }
    outboundVideo = candidate;
  });
  return outboundVideo;
}

function maybeLogAudioSenderStats(stats: RTCStatsReport, selectedVideoId: string): void {
  if (!FLOAT_ENABLE_EXPENSIVE_DEBUG_PROBES) {
    return;
  }

  const codecById = new Map<string, RTCStats>();
  const sourceById = new Map<string, RTCStats>();

  stats.forEach((item) => {
    if (item.type === "codec") {
      codecById.set(item.id, item);
      return;
    }
    if (item.type === "media-source" || item.type === "track") {
      sourceById.set(item.id, item);
    }
  });

  const reports: Record<string, unknown>[] = [];
  stats.forEach((item) => {
    const outbound = item as RTCStats & Record<string, unknown>;
    if (outbound.type !== "outbound-rtp") {
      return;
    }
    if (outbound.isRemote === true) {
      return;
    }
    const kind = (outbound.kind ?? outbound.mediaType) as string | undefined;
    if (kind !== "audio") {
      return;
    }

    const codecId = typeof outbound.codecId === "string" ? outbound.codecId : null;
    const codec = codecId ? (codecById.get(codecId) as Record<string, unknown> | undefined) : undefined;
    const mediaSourceId =
      typeof outbound.mediaSourceId === "string" ? (outbound.mediaSourceId as string) : null;
    const mediaSource = mediaSourceId ? (sourceById.get(mediaSourceId) as Record<string, unknown> | undefined) : undefined;

    reports.push({
      id: outbound.id,
      timestamp: outbound.timestamp,
      bytesSent: outbound.bytesSent ?? null,
      packetsSent: outbound.packetsSent ?? null,
      headerBytesSent: outbound.headerBytesSent ?? null,
      retransmittedPacketsSent: outbound.retransmittedPacketsSent ?? null,
      codecMimeType: codec?.mimeType ?? null,
      codecClockRate: codec?.clockRate ?? null,
      codecChannels: codec?.channels ?? null,
      codecSdpFmtpLine: codec?.sdpFmtpLine ?? null,
      mediaSourceAudioLevel: mediaSource?.audioLevel ?? null,
      mediaSourceTotalAudioEnergy: mediaSource?.totalAudioEnergy ?? null,
      mediaSourceTotalSamplesDuration: mediaSource?.totalSamplesDuration ?? null,
    });
  });

  if (reports.length > 0) {
    debugLog("sender.stats.audio", {
      selectedVideoId,
      reports,
    });
  }
}

function applyVideoScaleChange(
  state: VideoAdaptationState,
  requestedScaleDownBy: number,
  reasonPayload: Record<string, unknown>,
): void {
  if (state.updateInFlight) {
    return;
  }

  const requestedSettings = computeVideoSenderSettings(state.sender, state.qualityHint, requestedScaleDownBy);
  const scaleDelta = Math.abs(requestedSettings.scaleDownBy - state.scaleDownBy);
  const bitrateDelta = Math.abs(requestedSettings.maxBitrateBps - state.maxBitrateBps);
  const targetChanged =
    requestedSettings.target.width !== state.target.width ||
    requestedSettings.target.height !== state.target.height ||
    requestedSettings.target.source !== state.target.source;

  if (!targetChanged && scaleDelta < FLOAT_VIDEO_SCALE_CHANGE_EPSILON && bitrateDelta < 250_000) {
    return;
  }

  const previousScaleDownBy = state.scaleDownBy;
  const previousMaxBitrateBps = state.maxBitrateBps;
  state.updateInFlight = true;
  void applySenderQualitySettings(
    state.sender,
    state.selectedVideoId,
    state.qualityHint,
    requestedSettings.scaleDownBy,
  )
    .then((appliedSettings) => {
      if (activeVideoAdaptationState !== state || !appliedSettings) {
        return;
      }
      state.target = appliedSettings.target;
      state.baseScaleDownBy = appliedSettings.baseScaleDownBy;
      state.scaleDownBy = appliedSettings.scaleDownBy;
      state.maxBitrateBps = appliedSettings.maxBitrateBps;
      state.pressureScaleMultiplier = Math.max(1, state.scaleDownBy / Math.max(1, state.baseScaleDownBy));

      debugLog("sender.parameters.video.scaleChanged", {
        selectedVideoId: state.selectedVideoId,
        fromScaleDownBy: previousScaleDownBy,
        toScaleDownBy: state.scaleDownBy,
        fromMaxBitrateBps: previousMaxBitrateBps,
        toMaxBitrateBps: state.maxBitrateBps,
        targetWidth: state.target.width,
        targetHeight: state.target.height,
        targetSource: state.target.source,
        pressureScaleMultiplier: Number(state.pressureScaleMultiplier.toFixed(3)),
        ...reasonPayload,
      });
    })
    .finally(() => {
      if (activeVideoAdaptationState === state) {
        state.updateInFlight = false;
      }
    });
}

function applyVideoQualityHint(videoId: string, hint: VideoQualityHint): void {
  const previousHint = qualityHintByVideoId.get(videoId);
  if (!previousHint || !areVideoQualityHintsEqual(previousHint, hint)) {
    qualityHintByVideoId.set(videoId, hint);
  }

  if (activeVideoId !== videoId) {
    return;
  }

  requestedVideoQualityHint = hint;
  const state = activeVideoAdaptationState;
  if (!state || state.selectedVideoId !== videoId) {
    return;
  }

  state.qualityHint = { ...hint };
  state.lowPressureSamples = 0;
  const refreshedSettings = computeVideoSenderSettings(state.sender, state.qualityHint);
  state.target = refreshedSettings.target;
  state.baseScaleDownBy = refreshedSettings.baseScaleDownBy;
  const requestedScaleDownBy = clampScaleDownBy(state.baseScaleDownBy * state.pressureScaleMultiplier);
  applyVideoScaleChange(state, requestedScaleDownBy, {
    source: "pip-quality-hint",
    profile: hint.profile,
    pipWidth: hint.pipWidth,
    pipHeight: hint.pipHeight,
  });
}

function updateAdaptiveVideoQualityFromStats(stats: RTCStatsReport, state: VideoAdaptationState): void {
  const outbound = extractOutboundVideoStats(stats);
  if (!outbound) {
    return;
  }

  const framesEncoded = readFiniteNumber(outbound.framesEncoded);
  const totalEncodeTime = readFiniteNumber(outbound.totalEncodeTime);
  const framesSent = readFiniteNumber(outbound.framesSent);
  const framesDropped = readFiniteNumber(outbound.framesDropped) ?? 0;

  const counters =
    framesEncoded !== null && totalEncodeTime !== null && framesSent !== null
      ? {
          framesEncoded,
          totalEncodeTime,
          framesSent,
          framesDropped,
        }
      : null;

  let encodeMsPerFrame: number | null = null;
  let frameDropRatio: number | null = null;
  if (counters && state.lastCounters) {
    const deltaFramesEncoded = counters.framesEncoded - state.lastCounters.framesEncoded;
    const deltaTotalEncodeTime = counters.totalEncodeTime - state.lastCounters.totalEncodeTime;
    if (deltaFramesEncoded > 0 && deltaTotalEncodeTime >= 0) {
      encodeMsPerFrame = (deltaTotalEncodeTime * 1000) / deltaFramesEncoded;
    }

    const deltaFramesSent = counters.framesSent - state.lastCounters.framesSent;
    const deltaFramesDropped = counters.framesDropped - state.lastCounters.framesDropped;
    const deltaTotalFrames = deltaFramesSent + deltaFramesDropped;
    if (deltaFramesSent >= 0 && deltaFramesDropped >= 0 && deltaTotalFrames > 0) {
      frameDropRatio = deltaFramesDropped / deltaTotalFrames;
    }
  }

  if (counters) {
    state.lastCounters = counters;
  }

  const qualityLimitationReason =
    typeof outbound.qualityLimitationReason === "string" ? outbound.qualityLimitationReason : null;
  const highPressure =
    qualityLimitationReason === "cpu" ||
    (encodeMsPerFrame !== null && encodeMsPerFrame >= FLOAT_VIDEO_ENCODE_MS_PER_FRAME_HIGH) ||
    (frameDropRatio !== null && frameDropRatio >= FLOAT_VIDEO_DROP_RATIO_HIGH);
  const mediumPressure =
    qualityLimitationReason === "cpu" ||
    (encodeMsPerFrame !== null && encodeMsPerFrame >= FLOAT_VIDEO_ENCODE_MS_PER_FRAME_MEDIUM) ||
    (frameDropRatio !== null && frameDropRatio >= FLOAT_VIDEO_DROP_RATIO_MEDIUM);

  const refreshedSettings = computeVideoSenderSettings(state.sender, state.qualityHint);
  state.target = refreshedSettings.target;
  state.baseScaleDownBy = refreshedSettings.baseScaleDownBy;

  if (highPressure) {
    state.lowPressureSamples = 0;
    state.pressureScaleMultiplier = Math.min(
      FLOAT_VIDEO_MAX_SCALE_DOWN_BY,
      roundScaleDownBy(state.pressureScaleMultiplier * FLOAT_VIDEO_PRESSURE_MULTIPLIER_HIGH),
    );
  } else if (mediumPressure) {
    state.lowPressureSamples = 0;
    state.pressureScaleMultiplier = Math.min(
      FLOAT_VIDEO_MAX_SCALE_DOWN_BY,
      roundScaleDownBy(state.pressureScaleMultiplier * FLOAT_VIDEO_PRESSURE_MULTIPLIER_MEDIUM),
    );
  } else {
    state.lowPressureSamples += 1;
    if (state.lowPressureSamples >= FLOAT_VIDEO_PRESSURE_RECOVERY_SAMPLE_THRESHOLD) {
      state.pressureScaleMultiplier = Math.max(
        1,
        roundScaleDownBy(state.pressureScaleMultiplier * FLOAT_VIDEO_PRESSURE_RECOVERY_MULTIPLIER),
      );
      state.lowPressureSamples = 0;
    }
  }

  const requestedScaleDownBy = clampScaleDownBy(state.baseScaleDownBy * state.pressureScaleMultiplier);
  applyVideoScaleChange(state, requestedScaleDownBy, {
    source: "adaptive-stats",
    qualityLimitationReason,
    targetWidth: state.target.width,
    targetHeight: state.target.height,
    targetSource: state.target.source,
    pressureScaleMultiplier: Number(state.pressureScaleMultiplier.toFixed(3)),
    encodeMsPerFrame: encodeMsPerFrame !== null ? Number(encodeMsPerFrame.toFixed(2)) : null,
    frameDropRatio: frameDropRatio !== null ? Number(frameDropRatio.toFixed(4)) : null,
  });
}

function startSenderStatsProbe(
  peer: RTCPeerConnection,
  selectedVideoId: string,
  videoSender: RTCRtpSender | null,
  initialVideoSettings: AppliedVideoSenderSettings | null,
): void {
  if (senderStatsTimerId !== null) {
    window.clearInterval(senderStatsTimerId);
    senderStatsTimerId = null;
  }

  activeVideoAdaptationState = videoSender
    ? (() => {
        const qualityHint = { ...requestedVideoQualityHint };
        const appliedSettings = initialVideoSettings ?? computeVideoSenderSettings(videoSender, qualityHint);
        return {
          sender: videoSender,
          selectedVideoId,
          qualityHint,
          target: appliedSettings.target,
          baseScaleDownBy: appliedSettings.baseScaleDownBy,
          scaleDownBy: appliedSettings.scaleDownBy,
          pressureScaleMultiplier: Math.max(1, appliedSettings.scaleDownBy / Math.max(1, appliedSettings.baseScaleDownBy)),
          maxBitrateBps: appliedSettings.maxBitrateBps,
          lastCounters: null,
          lowPressureSamples: 0,
          updateInFlight: false,
        };
      })()
    : null;

  if (!activeVideoAdaptationState && !FLOAT_ENABLE_EXPENSIVE_DEBUG_PROBES) {
    return;
  }

  let inFlight = false;
  senderStatsTimerId = window.setInterval(() => {
    if (inFlight) {
      return;
    }
    inFlight = true;

    void peer
      .getStats()
      .then((stats) => {
        const state = activeVideoAdaptationState;
        if (state && state.selectedVideoId === selectedVideoId && state.sender.track?.readyState === "live") {
          updateAdaptiveVideoQualityFromStats(stats, state);
        }
        maybeLogAudioSenderStats(stats, selectedVideoId);
      })
      .catch((error) => {
        const reason = error instanceof Error ? error.message : "getStats failed";
        debugLog("sender.stats.failed", {
          selectedVideoId,
          reason,
        });
      })
      .finally(() => {
        inFlight = false;
      });
  }, FLOAT_VIDEO_ADAPTIVE_STATS_INTERVAL_MS);
}

function stopSenderStatsProbe(): void {
  if (senderStatsTimerId !== null) {
    window.clearInterval(senderStatsTimerId);
    senderStatsTimerId = null;
  }
  activeVideoAdaptationState = null;
}

function applyCodecPreferences(
  peer: RTCPeerConnection,
  sender: RTCRtpSender,
  selectedVideoId: string,
): void {
  const kind = sender.track?.kind;
  if (kind !== "audio" && kind !== "video") {
    return;
  }

  const transceiver = peer.getTransceivers().find((candidate) => candidate.sender === sender);
  if (!transceiver || typeof transceiver.setCodecPreferences !== "function") {
    return;
  }

  const capabilities = RTCRtpSender.getCapabilities?.(kind);
  const codecs = capabilities?.codecs;
  if (!codecs || codecs.length === 0) {
    return;
  }

  const preferredCodecs = kind === "video" ? FLOAT_VIDEO_CODEC_PRIORITY : FLOAT_AUDIO_CODEC_PRIORITY;
  const sortedCodecs = [...codecs].sort((left, right) => {
    return codecPriorityIndex(left.mimeType, preferredCodecs) - codecPriorityIndex(right.mimeType, preferredCodecs);
  });

  try {
    transceiver.setCodecPreferences(sortedCodecs);
  } catch (error) {
    const reason = error instanceof Error ? error.message : "setCodecPreferences failed";
    debugLog("sender.codecPreferences.failed", {
      selectedVideoId,
      kind,
      reason,
    });
  }
}

async function applyTrackQualitySettings(
  selectedVideoId: string,
  videoTrack: MediaStreamTrack,
  audioTracks: MediaStreamTrack[],
): Promise<void> {
  try {
    videoTrack.contentHint = "motion";
  } catch {
    // Ignore unsupported contentHint.
  }

  try {
    await videoTrack.applyConstraints({
      frameRate: { ideal: FLOAT_MAX_VIDEO_FPS, max: FLOAT_MAX_VIDEO_FPS },
    });
  } catch (error) {
    const reason = error instanceof Error ? error.message : "video applyConstraints failed";
    debugLog("source.track.videoConstraints.failed", {
      selectedVideoId,
      reason,
    });
  }

  const primaryAudioTrack = audioTracks[0];
  if (!primaryAudioTrack) {
    return;
  }

  try {
    primaryAudioTrack.contentHint = "music";
  } catch {
    // Ignore unsupported contentHint.
  }

  try {
    await primaryAudioTrack.applyConstraints({
      autoGainControl: false,
      echoCancellation: false,
      noiseSuppression: false,
      channelCount: { ideal: 2 },
      sampleRate: { ideal: 48000 },
    });
  } catch (error) {
    const reason = error instanceof Error ? error.message : "audio applyConstraints failed";
    debugLog("source.track.audioConstraints.failed", {
      selectedVideoId,
      reason,
    });
  }

  logAudioTrackDiagnostics(selectedVideoId, audioTracks);
}

async function applySenderQualitySettings(
  sender: RTCRtpSender,
  selectedVideoId: string,
  videoQualityHint: VideoQualityHint = defaultVideoQualityHint(),
  requestedScaleDownBy: number | null = null,
): Promise<AppliedVideoSenderSettings | null> {
  const kind = sender.track?.kind;
  if (kind !== "audio" && kind !== "video") {
    return null;
  }

  const parameters = sender.getParameters();
  const encodings =
    Array.isArray(parameters.encodings) && parameters.encodings.length > 0
      ? parameters.encodings.map((encoding) => ({ ...encoding }))
      : [{}];
  const primaryEncoding = { ...encodings[0] };

  primaryEncoding.priority = "high";
  let appliedVideoSettings: AppliedVideoSenderSettings | null = null;

  if (kind === "video") {
    appliedVideoSettings = computeVideoSenderSettings(sender, videoQualityHint, requestedScaleDownBy);
    primaryEncoding.maxBitrate = appliedVideoSettings.maxBitrateBps;
    primaryEncoding.maxFramerate = FLOAT_MAX_VIDEO_FPS;
    primaryEncoding.scaleResolutionDownBy = appliedVideoSettings.scaleDownBy;
    parameters.degradationPreference = "maintain-framerate";
  } else {
    primaryEncoding.maxBitrate = FLOAT_AUDIO_MAX_BITRATE_BPS;
  }

  encodings[0] = primaryEncoding;
  parameters.encodings = encodings;

  try {
    await sender.setParameters(parameters);
    if (kind === "audio") {
      const applied = sender.getParameters();
      debugLog("sender.parameters.audio.applied", {
        selectedVideoId,
        encodings: applied.encodings,
      });
    }
    return appliedVideoSettings;
  } catch (error) {
    const reason = error instanceof Error ? error.message : "setParameters failed";
    debugLog("sender.parameters.failed", {
      selectedVideoId,
      kind,
      reason,
    });
    return null;
  }
}

function stopStreaming(): void {
  stopSenderStatsProbe();
  requestedVideoQualityHint = defaultVideoQualityHint();

  if (activePeer) {
    activePeer.onicecandidate = null;
    activePeer.onconnectionstatechange = null;
    activePeer.close();
    activePeer = null;
  }

  if (activeStream) {
    activeStream.getTracks().forEach((track) => track.stop());
    activeStream = null;
  }

  if (activeVideoId) {
    qualityHintByVideoId.delete(activeVideoId);
    chrome.runtime.sendMessage({
      type: "float:webrtc:stopped",
      videoId: activeVideoId,
    });
  }
  activeSourceVideo = null;
  activeVideoId = null;
}

async function startStreaming(videoId: string): Promise<void> {
  stopStreaming();
  requestedVideoQualityHint = defaultVideoQualityHint();

  let selectedVideoId = videoId;
  let video = findVideoById(videoId);
  if (!video) {
    video = findBestAvailableVideo();
    if (!video) {
      notifyWebRTCError(`Video ${videoId} is no longer available`);
      return;
    }
    selectedVideoId = generateVideoId(video);
    scheduleEmit();
  }

  if (!video) {
    notifyWebRTCError(`Video ${videoId} is no longer available`);
    return;
  }

  debugLog("source.selected", {
    requestedVideoId: videoId,
    selectedVideoId,
    videoWidth: video.videoWidth,
    videoHeight: video.videoHeight,
    readyState: video.readyState,
    paused: video.paused,
  });
  requestedVideoQualityHint = {
    ...(qualityHintByVideoId.get(selectedVideoId) ?? defaultVideoQualityHint()),
  };

  let stream: MediaStream;
  try {
    stream = video.captureStream();
  } catch (error) {
    const reason = error instanceof Error ? error.message : "captureStream failed";
    notifyWebRTCError(reason);
    return;
  }

  const videoTracks = stream.getVideoTracks();
  const audioTracks = stream.getAudioTracks();

  if (videoTracks.length === 0) {
    notifyWebRTCError("captureStream returned no video track");
    stream.getTracks().forEach((track) => track.stop());
    return;
  }

  const primaryVideoTrack = videoTracks[0];
  await applyTrackQualitySettings(selectedVideoId, primaryVideoTrack, audioTracks);

  const trackSettings = primaryVideoTrack.getSettings();
  debugLog("source.track", {
    selectedVideoId,
    streamTrackCount: stream.getTracks().length,
    videoTrackCount: videoTracks.length,
    audioTrackCount: audioTracks.length,
    trackId: primaryVideoTrack.id,
    width: trackSettings.width ?? null,
    height: trackSettings.height ?? null,
    frameRate: trackSettings.frameRate ?? null,
  });

  const peer = new RTCPeerConnection({
    iceServers: [],
  });

  const senders: RTCRtpSender[] = [];
  stream.getTracks().forEach((track) => {
    track.enabled = true;
    const sender = peer.addTrack(track, stream);
    senders.push(sender);
  });

  senders.forEach((sender) => {
    applyCodecPreferences(peer, sender, selectedVideoId);
  });
  let initialVideoSettings: AppliedVideoSenderSettings | null = null;
  await Promise.all(
    senders.map(async (sender) => {
      if (sender.track?.kind === "video") {
        initialVideoSettings = await applySenderQualitySettings(sender, selectedVideoId, requestedVideoQualityHint);
        return;
      }
      await applySenderQualitySettings(sender, selectedVideoId);
    }),
  );
  const primaryVideoSender = senders.find((sender) => sender.track?.kind === "video") ?? null;

  peer.onicecandidate = (event) => {
    if (!event.candidate) {
      return;
    }

    chrome.runtime.sendMessage({
      type: "float:webrtc:ice",
      videoId: selectedVideoId,
      candidate: event.candidate.candidate,
      sdpMid: event.candidate.sdpMid,
      sdpMLineIndex: event.candidate.sdpMLineIndex,
    });
  };

  peer.onconnectionstatechange = () => {
    if (peer.connectionState === "disconnected") {
      stopStreaming();
      return;
    }
    if (peer.connectionState === "failed" || peer.connectionState === "closed") {
      notifyWebRTCError(`Peer state changed to ${peer.connectionState}`);
    }
  };

  try {
    const offer = await peer.createOffer();
    const rawOfferSdp = offer.sdp;
    if (typeof rawOfferSdp !== "string" || rawOfferSdp.length === 0) {
      throw new Error("offer SDP is missing");
    }
    const offerOpusFmtpBefore = extractOpusFmtpLinesFromSdp(rawOfferSdp);
    const stereoOfferSdp = enforceStereoOpusInOfferSdp(rawOfferSdp, selectedVideoId);
    const offerOpusFmtpAfter = extractOpusFmtpLinesFromSdp(stereoOfferSdp);
    debugLog("sender.offer.audioSdp", {
      selectedVideoId,
      before: offerOpusFmtpBefore,
      after: offerOpusFmtpAfter,
    });
    await peer.setLocalDescription({
      type: "offer",
      sdp: stereoOfferSdp,
    });

    const localOfferSdp = peer.localDescription?.sdp ?? stereoOfferSdp;
    debugLog("sender.offer.audioSdp.localDescription", {
      selectedVideoId,
      opusFmtp: extractOpusFmtpLinesFromSdp(localOfferSdp),
    });
    activePeer = peer;
    activeStream = stream;
    activeVideoId = selectedVideoId;
    activeSourceVideo = video;
    startSenderStatsProbe(peer, selectedVideoId, primaryVideoSender, initialVideoSettings);

    chrome.runtime.sendMessage({
      type: "float:webrtc:offer",
      videoId: selectedVideoId,
      sdp: localOfferSdp,
    });
  } catch (error) {
    const reason = error instanceof Error ? error.message : "offer creation failed";
    notifyWebRTCError(reason);
    peer.close();
    stream.getTracks().forEach((track) => track.stop());
    activeSourceVideo = null;
  }
}

async function applyPlaybackControl(videoId: string, playing: boolean): Promise<void> {
  if (activeVideoId !== videoId) {
    return;
  }

  const target = activeSourceVideo ?? findVideoById(videoId);
  if (!target) {
    notifyWebRTCError(`Playback control target not found for ${videoId}`);
    return;
  }

  activeSourceVideo = target;

  try {
    if (playing) {
      await target.play();
    } else {
      target.pause();
    }
    scheduleEmit();
  } catch (error) {
    const reason = error instanceof Error ? error.message : "failed to apply playback control";
    notifyWebRTCError(reason);
  }
}

function applySeekControl(videoId: string, intervalSeconds: number): void {
  if (activeVideoId !== videoId) {
    return;
  }
  if (!Number.isFinite(intervalSeconds)) {
    return;
  }

  const target = activeSourceVideo ?? findVideoById(videoId);
  if (!target) {
    notifyWebRTCError(`Seek target not found for ${videoId}`);
    return;
  }

  activeSourceVideo = target;

  const current = Number.isFinite(target.currentTime) ? target.currentTime : 0;
  const duration = Number.isFinite(target.duration) && target.duration > 0 ? target.duration : null;
  let nextTime = current + intervalSeconds;

  if (duration !== null) {
    nextTime = Math.min(duration, Math.max(0, nextTime));
  } else {
    nextTime = Math.max(0, nextTime);
  }

  try {
    target.currentTime = nextTime;
    scheduleEmit();
  } catch (error) {
    const reason = error instanceof Error ? error.message : "failed to apply seek control";
    notifyWebRTCError(reason);
  }
}

async function applyAnswer(videoId: string, sdp: string): Promise<void> {
  if (!activePeer || activeVideoId !== videoId) {
    return;
  }

  const answerOpusFmtpBefore = extractOpusFmtpLinesFromSdp(sdp);
  const stereoAnswerSdp = enforceStereoOpusInOfferSdp(sdp, videoId);
  const answerOpusFmtpAfter = extractOpusFmtpLinesFromSdp(stereoAnswerSdp);

  debugLog("sender.answer.audioSdp", {
    videoId,
    before: answerOpusFmtpBefore,
    after: answerOpusFmtpAfter,
  });

  await activePeer.setRemoteDescription({
    type: "answer",
    sdp: stereoAnswerSdp,
  });
}

async function addIceCandidate(
  videoId: string,
  candidate: string,
  sdpMid: string | null,
  sdpMLineIndex: number | null,
): Promise<void> {
  if (!activePeer || activeVideoId !== videoId) {
    return;
  }

  await activePeer.addIceCandidate(
    new RTCIceCandidate({
      candidate,
      sdpMid,
      sdpMLineIndex,
    }),
  );
}

chrome.runtime.onMessage.addListener((message: any) => {
  if (!message || typeof message.type !== "string") {
    return;
  }

  if (message.type === "float:start" && typeof message.videoId === "string") {
    void startStreaming(message.videoId);
    return;
  }

  if (message.type === "float:stop") {
    stopStreaming();
    return;
  }

  if (
    message.type === "float:playback" &&
    typeof message.videoId === "string" &&
    typeof message.playing === "boolean"
  ) {
    void applyPlaybackControl(message.videoId, message.playing);
    return;
  }

  if (
    message.type === "float:seek" &&
    typeof message.videoId === "string" &&
    typeof message.intervalSeconds === "number"
  ) {
    applySeekControl(message.videoId, message.intervalSeconds);
    return;
  }

  if (
    message.type === "float:qualityHint" &&
    typeof message.videoId === "string" &&
    isVideoQualityProfileId(message.profile)
  ) {
    applyVideoQualityHint(
      message.videoId,
      normalizeVideoQualityHint(message.profile, message.pipWidth, message.pipHeight),
    );
    return;
  }

  if (message.type === "float:signal:answer" && typeof message.videoId === "string" && typeof message.sdp === "string") {
    void applyAnswer(message.videoId, message.sdp).catch((error) => {
      const reason = error instanceof Error ? error.message : "failed to apply answer";
      notifyWebRTCError(reason);
    });
    return;
  }

  if (
    message.type === "float:signal:ice" &&
    typeof message.videoId === "string" &&
    typeof message.candidate === "string"
  ) {
    void addIceCandidate(
      message.videoId,
      message.candidate,
      message.sdpMid ?? null,
      typeof message.sdpMLineIndex === "number" ? message.sdpMLineIndex : null,
    ).catch((error) => {
      const reason = error instanceof Error ? error.message : "failed to apply ICE candidate";
      notifyWebRTCError(reason);
    });
  }
});
