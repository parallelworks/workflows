// The flipbook: render.json lists the frames the render wrote; the page preloads them
// and plays them back at the frame rate the render recorded, with a slider to scrub.
"use strict";

const ICONS = {
  info: "M8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12ZM8 7.5v3.5M8 5h.01",
  error: "M8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12ZM8 4.75v3.75M8 11h.01",
  running: "M14 8a6 6 0 1 1-6-6",
};

function icon(name, cls = "") {
  return `<svg class="${cls}" viewBox="0 0 16 16" width="1em" height="1em" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${ICONS[name]}"/></svg>`;
}

const el = (id) => document.getElementById(id);

const state = { frames: [], index: 0, playing: true, fps: 24, timer: null };

function show(index) {
  if (!state.frames.length) return;
  state.index = (index + state.frames.length) % state.frames.length;
  el("frame").src = state.frames[state.index];
  el("scrub").value = String(state.index);
  el("counter").textContent = `${state.index + 1} / ${state.frames.length}`;
}

function setPlaying(playing) {
  state.playing = playing;
  el("play-label").textContent = playing ? "Pause" : "Play";
  el("play-icon").hidden = playing;
  el("pause-icon").hidden = !playing;
  clearInterval(state.timer);
  if (playing && state.frames.length > 1) {
    state.timer = setInterval(() => show(state.index + 1), 1000 / state.fps);
  }
}

function message(kind, text) {
  const box = el("message");
  box.dataset.kind = kind;
  box.innerHTML = `${icon(kind === "error" ? "error" : "info")}<div>${text}</div>`;
  box.hidden = false;
}

function describe(render) {
  const rows = [
    ["Scene", render.scene],
    ["Frames", `${render.frame_count} at ${render.width} × ${render.height}, played at ${render.fps} fps`],
    ["Renderer", render.renderer],
    ["GPU", render.gpu],
    ["Render time", render.seconds != null ? `${render.seconds} s (${render.seconds_per_frame} s per frame after the first)` : ""],
    ["Software", `${render.software} in ${render.image}`],
    ["Host", render.host],
    ["Finished", render.finished],
  ];
  el("meta").innerHTML = rows
    .filter(([, value]) => value)
    .map(([label, value]) => `<div><dt>${label}</dt><dd>${value}</dd></div>`)
    .join("");
}

async function load() {
  let render;
  try {
    const response = await fetch("render.json", { cache: "no-store" });
    if (!response.ok) throw new Error(`render.json answered ${response.status}`);
    render = await response.json();
  } catch (error) {
    message("error", `The render's manifest could not be read: ${error.message}`);
    return;
  }
  describe(render);
  if (!render.frames || !render.frames.length) {
    message("error", "The render wrote no frames; the run's log says why.");
    return;
  }
  state.fps = render.fps || 24;
  state.frames = render.frames;
  // Preload so playback never waits on the network; the first frame shows at once
  render.frames.forEach((src) => { const img = new Image(); img.src = src; });
  el("scrub").max = String(render.frames.length - 1);
  el("frame").alt = `Frame of ${render.scene}`;
  show(0);
  setPlaying(true);
  el("play").disabled = false;
  el("scrub").disabled = false;
}

// The color mode the platform's way: the device's, or pinned light or dark
function cycleTheme() {
  const root = document.documentElement;
  const next = { undefined: "light", light: "dark", dark: undefined }[root.dataset.theme];
  if (next) root.dataset.theme = next; else delete root.dataset.theme;
  try {
    if (next) window.localStorage.setItem("omniverse-theme", next);
    else window.localStorage.removeItem("omniverse-theme");
  } catch (e) { /* no storage: the choice lasts for the page */ }
}

el("play").addEventListener("click", () => setPlaying(!state.playing));
el("scrub").addEventListener("input", (event) => { setPlaying(false); show(Number(event.target.value)); });
el("theme").addEventListener("click", cycleTheme);
el("frame").addEventListener("click", () => setPlaying(!state.playing));
document.addEventListener("keydown", (event) => {
  if (event.target.tagName === "INPUT") return;
  if (event.key === " ") { event.preventDefault(); setPlaying(!state.playing); }
  if (event.key === "ArrowRight") { setPlaying(false); show(state.index + 1); }
  if (event.key === "ArrowLeft") { setPlaying(false); show(state.index - 1); }
});
load();
