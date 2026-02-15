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

const videoMeta = new WeakMap<HTMLVideoElement, VideoMeta>();
let videoCounter = 0;
let scheduled = false;
let activePeer: RTCPeerConnection | null = null;
let activeStream: MediaStream | null = null;
let activeVideoId: string | null = null;
let activeSourceVideo: HTMLVideoElement | null = null;
let sourceProbeTimerId: number | null = null;
const FLOAT_TARGET_WIDTH = 1280;
const FLOAT_TARGET_HEIGHT = 720;
const FLOAT_TARGET_FPS = 30;

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

function stopSourceProbe(): void {
  if (sourceProbeTimerId !== null) {
    window.clearInterval(sourceProbeTimerId);
    sourceProbeTimerId = null;
  }
}

function sampleVideoLuma(video: HTMLVideoElement): { tl: number; center: number; br: number } | null {
  if (video.videoWidth <= 0 || video.videoHeight <= 0) {
    return null;
  }
  const canvas = document.createElement("canvas");
  canvas.width = 64;
  canvas.height = 36;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx) {
    return null;
  }

  try {
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    const data = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
    const sampleAt = (x: number, y: number): number => {
      const clampedX = Math.max(0, Math.min(canvas.width - 1, x));
      const clampedY = Math.max(0, Math.min(canvas.height - 1, y));
      const idx = (clampedY * canvas.width + clampedX) * 4;
      const r = data[idx] ?? 0;
      const g = data[idx + 1] ?? 0;
      const b = data[idx + 2] ?? 0;
      return Math.round((r * 77 + g * 150 + b * 29) / 256);
    };

    return {
      tl: sampleAt(4, 4),
      center: sampleAt(Math.floor(canvas.width / 2), Math.floor(canvas.height / 2)),
      br: sampleAt(canvas.width - 5, canvas.height - 5),
    };
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    debugLog("source.probe.failed", { reason });
    return null;
  }
}

function startSourceProbe(video: HTMLVideoElement, selectedVideoId: string): void {
  stopSourceProbe();

  const style = window.getComputedStyle(video);
  const rect = video.getBoundingClientRect();
  debugLog("source.element", {
    selectedVideoId,
    clientWidth: video.clientWidth,
    clientHeight: video.clientHeight,
    videoWidth: video.videoWidth,
    videoHeight: video.videoHeight,
    objectFit: style.objectFit,
    objectPosition: style.objectPosition,
    transform: style.transform,
    rectWidth: Math.round(rect.width),
    rectHeight: Math.round(rect.height),
    rectLeft: Math.round(rect.left),
    rectTop: Math.round(rect.top),
  });

  sourceProbeTimerId = window.setInterval(() => {
    const probe = sampleVideoLuma(video);
    if (!probe) {
      return;
    }
    debugLog("source.probe", {
      selectedVideoId,
      tl: probe.tl,
      center: probe.center,
      br: probe.br,
      paused: video.paused,
      readyState: video.readyState,
      currentTime: Number(video.currentTime.toFixed(2)),
    });
  }, 2000);
}

function stopStreaming(): void {
  stopSourceProbe();

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
  startSourceProbe(video, selectedVideoId);

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
  try {
    await primaryVideoTrack.applyConstraints({
      frameRate: { ideal: FLOAT_TARGET_FPS, max: FLOAT_TARGET_FPS },
    });
  } catch (error) {
    const reason = error instanceof Error ? error.message : "applyConstraints failed";
    debugLog("source.track.applyConstraints.failed", {
      selectedVideoId,
      reason,
    });
  }
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

  stream.getTracks().forEach((track) => {
    track.enabled = true;
    peer.addTrack(track, stream);
  });

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
    await peer.setLocalDescription(offer);
    activePeer = peer;
    activeStream = stream;
    activeVideoId = selectedVideoId;
    activeSourceVideo = video;

    chrome.runtime.sendMessage({
      type: "float:webrtc:offer",
      videoId: selectedVideoId,
      sdp: offer.sdp,
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

  await activePeer.setRemoteDescription({
    type: "answer",
    sdp,
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
