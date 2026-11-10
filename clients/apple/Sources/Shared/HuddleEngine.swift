// The huddle client that runs inside the hidden web view: apps/web/src/lib/huddle.ts ported to plain
// JavaScript, since macOS has WebRTC only in WebKit. It keeps the huddle socket and both peer
// connections (one sending this person's microphone to Cloudflare's SFU, one receiving everyone
// else's), and reports its state to Swift through `window.webkit.messageHandlers.huddle`.
//
// Keep it in step with huddle.ts and packages/protocol/src/huddles.ts.
let huddleEngineHTML = #"""
<!doctype html>
<html><head><meta charset="utf-8"></head><body>
<script>
"use strict";
const post = (message) => window.webkit.messageHandlers.huddle.postMessage(message);
const CONNECTION = { iceServers: [{ urls: "stun:stun.cloudflare.com:3478" }], bundlePolicy: "max-bundle" };
const ANSWER_TIMEOUT_MS = 45000;
const LISTEN_AGAIN_MS = [500, 8000];
const PUBLISH_AGAIN_MS = [1000, 15000];
const ENDINGS = {
  4005: "That huddle is full. A huddle takes 50 people.",
  4006: "Huddles have been turned off.",
  4007: "You joined the huddle somewhere else, so it left this window.",
  4004: "You left the huddle, since its room is no longer there for you.",
  4003: null,
};

function growingWait([least, most]) {
  let next = least;
  return { take() { const wait = next; next = Math.min(most, next * 2); return wait; }, startOver() { next = least; } };
}

/** A socket that reconnects with backoff until told to stop, or until a close code says not to. */
function reconnectingSocket({ url, onMessage, onConnecting, onClose }) {
  let socket = null, stopped = false, held = false, attempt = 0, pinger, timer;
  function open() {
    if (stopped) return;
    held = false;
    const ws = (socket = new WebSocket(url()));
    ws.onmessage = (event) => onMessage(event.data);
    ws.onclose = (event) => {
      if (socket !== ws) return;
      clearInterval(pinger);
      socket = null;
      if (stopped || held) return;
      if (!onClose(event.code)) { stopped = true; return; }
      onConnecting("reconnecting");
      timer = setTimeout(open, Math.min(30000, 500 * 2 ** attempt++));
    };
    clearInterval(pinger);
    pinger = setInterval(() => send({ type: "ping" }), 25000);
  }
  function send(frame) {
    if (!socket || socket.readyState !== WebSocket.OPEN) return false;
    socket.send(JSON.stringify(frame));
    return true;
  }
  open();
  return {
    send,
    connected() { attempt = 0; },
    hold() { held = true; clearTimeout(timer); const ws = socket; socket = null; ws?.close(); onConnecting("reconnecting"); },
    retry() { clearTimeout(timer); open(); },
    close() { stopped = true; clearTimeout(timer); clearInterval(pinger); socket?.close(); socket = null; },
  };
}

function voices() {
  const playing = new Map();
  const stop = (userId) => { const audio = playing.get(userId); if (!audio) return; audio.srcObject = null; audio.remove(); playing.delete(userId); };
  return {
    play(userId, track) {
      const audio = playing.get(userId) ?? document.createElement("audio");
      audio.autoplay = true;
      audio.srcObject = new MediaStream([track]);
      playing.set(userId, audio);
      document.body.append(audio);
      audio.play().catch(() => {});
    },
    stop,
    stopAll() { for (const userId of [...playing.keys()]) stop(userId); },
  };
}

let current = null;

window.leaveHuddle = () => { current?.leave(); current = null; };
window.setHuddleMuted = (muted) => current?.setMuted(muted);

window.joinHuddle = async (socketBase, roomId, muted) => {
  window.leaveHuddle();
  post({ type: "log", message: "joining" });
  let microphone = null;
  // A permission prompt that never answers (macOS can't show one for an unbundled process) shouldn't
  // hold the huddle: after a while, join listening only.
  const gaveUp = new Promise((resolve) => setTimeout(() => resolve(null), 8000));
  try {
    microphone = await Promise.race([navigator.mediaDevices.getUserMedia({ audio: true }), gaveUp]);
    if (!microphone) post({ type: "microphone", error: "No answer about the microphone" });
  } catch (error) { post({ type: "microphone", error: String(error) }); }
  post({ type: "log", message: microphone ? "microphone on" : "no microphone" });
  current = start({ socketBase, roomId, muted, microphone });
};

function start({ socketBase, roomId, muted, microphone }) {
  const track = microphone?.getAudioTracks()[0] ?? null;
  let huddle = { roomId, connected: false, you: null, people: [], muted: muted || !track, microphone: track !== null };
  let over = false;
  if (track) track.enabled = !huddle.muted;
  let sending = null, unanswered = false, publishTimer;
  const publishWait = growingWait(PUBLISH_AGAIN_MS);
  let receiving = null;
  const heard = new Set();
  let round = null, listenTimer;
  const listenWait = growingWait(LISTEN_AGAIN_MS);
  const voice = voices();

  const socket = reconnectingSocket({
    url: () => `${socketBase}/api/rooms/${encodeURIComponent(roomId)}/huddle${huddle.muted ? "?muted=1" : ""}`,
    onMessage: (data) => { let frame; try { frame = JSON.parse(data); } catch { return; } if (frame && !over) hear(frame); },
    onConnecting: (status) => { if (status === "reconnecting") roomLost(); },
    onClose: (code) => {
      const ending = ENDINGS[code];
      if (ending === undefined) return true;
      stop();
      post({ type: "ended", message: ending });
      return false;
    },
  });

  function show(changes) {
    if (over) return;
    const next = { ...huddle, ...changes };
    const people = next.people.map((p) => (p.user.id === next.you?.id && p.muted !== next.muted ? { ...p, muted: next.muted } : p));
    huddle = { ...next, people };
    post({ type: "state", huddle });
  }
  const microphoneGone = () => { socket.send({ type: "huddle.mute", muted: true }); show({ muted: true, microphone: false }); };
  track?.addEventListener("ended", microphoneGone);

  function stop() {
    over = true;
    socket.close();
    hangUp();
    voice.stopAll();
    track?.removeEventListener("ended", microphoneGone);
    for (const each of microphone?.getTracks() ?? []) each.stop();
  }
  function roomLost() { hangUp(); if (huddle.connected) show({ connected: false }); }
  function rejoin() { socket.hold(); socket.retry(); }
  function hangUp() { hangUpSending(); hangUpReceiving(); endRound(); }

  async function publish() {
    hangUpSending();
    if (!track || track.readyState === "ended") return;
    const connection = (sending = new RTCPeerConnection(CONNECTION));
    const transceiver = connection.addTransceiver(track, { direction: "sendonly" });
    connection.onconnectionstatechange = () => {
      if (sending !== connection) return;
      if (connection.connectionState === "failed") return publishLater();
      if (connection.connectionState !== "connected") return;
      publishWait.startOver();
      socket.send({ type: "huddle.connected" });
    };
    let offer;
    try { await connection.setLocalDescription(await connection.createOffer()); offer = connection.localDescription?.sdp; } catch {}
    if (sending !== connection) return;
    if (!offer || transceiver.mid === null) return publishLater();
    if (!socket.send({ type: "huddle.publish", sdp: offer, tracks: [{ mid: transceiver.mid, kind: "audio" }] })) return;
    unanswered = true;
    publishTimer = setTimeout(rejoin, ANSWER_TIMEOUT_MS);
  }
  function publishLater() { hangUpSending(); if (!over) publishTimer = setTimeout(() => void publish(), publishWait.take()); }
  async function published(sdp) {
    const connection = sending;
    if (!connection || !unanswered) return;
    unanswered = false;
    clearTimeout(publishTimer);
    try { await connection.setRemoteDescription({ type: "answer", sdp }); } catch { if (sending === connection) publishLater(); }
  }
  function hangUpSending() { clearTimeout(publishTimer); unanswered = false; sending?.close(); sending = null; }

  const isUnheard = ({ user, audio }) => audio && user.id !== huddle.you?.id && !heard.has(user.id);
  const canListenTo = (userId) => huddle.people.some(({ user, audio }) => audio && user.id === userId);
  function listen(anyone = false) {
    if (over || round) return;
    clearTimeout(listenTimer);
    if (!anyone && !huddle.people.some(isUnheard)) return;
    if (!socket.send(receiving ? { type: "huddle.listen" } : { type: "huddle.listen", fresh: true })) return;
    round = { offered: false, givenUp: false };
    listenTimer = setTimeout(rejoin, ANSWER_TIMEOUT_MS);
  }
  function listenLater() { listenTimer = setTimeout(() => listen(), listenWait.take()); }
  function endRound() { clearTimeout(listenTimer); round = null; }
  async function offered(sdp, tracks) {
    const asked = round;
    if (!asked) return;
    asked.offered = true;
    const answer = asked.givenUp ? undefined : await answerTo(sdp, tracks);
    if (round !== asked) return;
    if (answer !== undefined && !asked.givenUp) return void socket.send({ type: "huddle.answer", sdp: answer });
    endRound();
    hangUpReceiving();
    listenLater();
  }
  async function answerTo(sdp, tracks) {
    const connection = (receiving ??= receivingConnection());
    for (const { userId } of tracks) if (canListenTo(userId)) heard.add(userId);
    try {
      await connection.setRemoteDescription({ type: "offer", sdp });
      if (receiving !== connection) return undefined;
      for (const t of tracks) play(connection, t);
      await connection.setLocalDescription(await connection.createAnswer());
      return connection.localDescription?.sdp;
    } catch { return undefined; }
  }
  function receivingConnection() {
    const connection = new RTCPeerConnection(CONNECTION);
    connection.onconnectionstatechange = () => { if (receiving === connection && connection.connectionState === "failed") listenAfresh(); };
    return connection;
  }
  function play(connection, { mid, userId }) {
    const theirs = connection.getTransceivers().find((t) => t.mid === mid)?.receiver.track;
    if (theirs && heard.has(userId)) voice.play(userId, theirs);
  }
  function listening() {
    if (!round) return;
    const { offered: wasOffered, givenUp } = round;
    endRound();
    if (wasOffered && !givenUp) { listenWait.startOver(); return listen(true); }
    if (givenUp || huddle.people.some(isUnheard)) listenLater();
  }
  function listenAfresh() { hangUpReceiving(); if (round) round.givenUp = true; else listenLater(); }
  function forget(userId) { heard.delete(userId); voice.stop(userId); }
  function hangUpReceiving() { receiving?.close(); receiving = null; for (const userId of [...heard]) forget(userId); }

  function hear(frame) {
    switch (frame.type) {
      case "huddle.welcome": {
        socket.connected();
        publishWait.startOver();
        listenWait.startOver();
        const mine = frame.people.find(({ user }) => user.id === frame.you.id);
        if (mine && mine.muted !== huddle.muted) socket.send({ type: "huddle.mute", muted: huddle.muted });
        show({ connected: true, you: frame.you, people: frame.people });
        void publish();
        return listen();
      }
      case "huddle.joined":
      case "huddle.changed": {
        const { person } = frame;
        if (!person.audio) forget(person.user.id);
        const known = huddle.people.some(({ user }) => user.id === person.user.id);
        show({ people: known ? huddle.people.map((o) => (o.user.id === person.user.id ? person : o)) : [...huddle.people, person] });
        return listen();
      }
      case "huddle.left":
        forget(frame.userId);
        return show({ people: huddle.people.filter(({ user }) => user.id !== frame.userId) });
      case "huddle.published": return void published(frame.sdp);
      case "huddle.unpublished": if (!unanswered) void publish(); return;
      case "huddle.offer": return void offered(frame.sdp, frame.tracks);
      case "huddle.listening": return listening();
      case "error":
        post({ type: "error", message: frame.message });
        if (frame.failed === "huddle.publish" && unanswered) publishLater();
        if ((frame.failed === "huddle.listen" || frame.failed === "huddle.answer") && round) { endRound(); listenAfresh(); }
        return;
    }
  }

  show({});
  return {
    leave() { stop(); post({ type: "ended", message: null }); },
    setMuted(to) {
      if (!track || !huddle.microphone || to === huddle.muted) return;
      track.enabled = !to;
      socket.send({ type: "huddle.mute", muted: to });
      show({ muted: to });
    },
  };
}
post({ type: "ready" });
</script>
</body></html>
"""#
