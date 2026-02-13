type ContentVideoCandidate = {
  videoId: string;
  playing: boolean;
  muted: boolean;
  resolution: string;
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
    if (!(video instanceof HTMLVideoElement) || !isEligible(video)) {
      return;
    }

    const videoId = generateVideoId(video);
    const resolution = `${video.videoWidth}x${video.videoHeight}`;

    candidates.push({
      videoId,
      playing: !video.paused,
      muted: video.muted || video.volume === 0,
      resolution,
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

function notifyWebRTCError(reason: string): void {
  chrome.runtime.sendMessage({
    type: "float:webrtc:error",
    reason,
    videoId: activeVideoId,
  });
}

function stopStreaming(): void {
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
  activeVideoId = null;
}

async function startStreaming(videoId: string): Promise<void> {
  stopStreaming();

  const video = findVideoById(videoId);
  if (!video) {
    notifyWebRTCError(`Video ${videoId} is no longer available`);
    return;
  }

  let stream: MediaStream;
  try {
    stream = video.captureStream();
  } catch (error) {
    const reason = error instanceof Error ? error.message : "captureStream failed";
    notifyWebRTCError(reason);
    return;
  }

  if (stream.getVideoTracks().length === 0) {
    notifyWebRTCError("captureStream returned no video track");
    stream.getTracks().forEach((track) => track.stop());
    return;
  }

  const peer = new RTCPeerConnection({
    iceServers: [],
  });

  stream.getTracks().forEach((track) => {
    peer.addTrack(track, stream);
  });

  peer.onicecandidate = (event) => {
    if (!event.candidate) {
      return;
    }

    chrome.runtime.sendMessage({
      type: "float:webrtc:ice",
      videoId,
      candidate: event.candidate.candidate,
      sdpMid: event.candidate.sdpMid,
      sdpMLineIndex: event.candidate.sdpMLineIndex,
    });
  };

  peer.onconnectionstatechange = () => {
    if (peer.connectionState === "failed" || peer.connectionState === "closed") {
      notifyWebRTCError(`Peer state changed to ${peer.connectionState}`);
    }
  };

  try {
    const offer = await peer.createOffer();
    await peer.setLocalDescription(offer);
    activePeer = peer;
    activeStream = stream;
    activeVideoId = videoId;

    chrome.runtime.sendMessage({
      type: "float:webrtc:offer",
      videoId,
      sdp: offer.sdp,
    });
  } catch (error) {
    const reason = error instanceof Error ? error.message : "offer creation failed";
    notifyWebRTCError(reason);
    peer.close();
    stream.getTracks().forEach((track) => track.stop());
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
