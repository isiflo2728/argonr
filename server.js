// Argon Playtest Lab server.
// Drives any web game in a real Chrome window with a frozen, steppable clock, lets Argon play it from
// screenshots, records runs, and has Argon fix the source (local games) or write bug reports (URLs).
//   node server.js            (reads .env if present)
// Env: ARGON_API_KEY (or GEMINI_API_KEY), ARGON_MODEL, ARGON_BASE_URL, PORT, CHROME_PATH

const http = require("http");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const crypto = require("crypto");
const { execFile } = require("child_process");
const puppeteer = require("puppeteer-core");

const ROOT = __dirname;
const GAMES = path.join(ROOT, "games");
const VROOT = path.join(ROOT, "versions");
const RROOT = path.join(ROOT, "recordings");
const REPORTS = path.join(ROOT, "reports");
const PLANTED = path.join(ROOT, "demo", "planted-bugs.json");

loadDotEnv(path.join(ROOT, ".env"));
const API_KEY = process.env.ARGON_API_KEY || process.env.GEMINI_API_KEY || "";
const MODEL = process.env.ARGON_MODEL || "";
const BASE_URL = (process.env.ARGON_BASE_URL || "https://generativelanguage.googleapis.com/v1beta").replace(/\/$/, "");
const PORT = Number(process.env.PORT) || 5173;
const CHROME = process.env.CHROME_PATH || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const ARGON_READY = Boolean(API_KEY && MODEL);
const VIEW = { width: Number(process.env.PLAYTEST_WIDTH) || 1280, height: Number(process.env.PLAYTEST_HEIGHT) || 800 };
const WINDOW_POS = (process.env.PLAYTEST_WINDOW || "0,0").split(",").map((n) => Number(n) || 0); // where the game window opens
const SHOT_SCALE = Math.min(1, 768 / VIEW.width); // screenshots Argon sees are at most 768 wide

function loadDotEnv(file) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !(m[1] in process.env)) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const readJson = (f, d) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { return d; } };
const writeJson = (f, v) => { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, JSON.stringify(v, null, 2)); };

// ---------- Virtual clock, injected before any page script ----------
// Replaces requestAnimationFrame, timers, performance.now and Date.now so the lab can freeze the game
// while Argon thinks and then run it for exactly the time Argon asked for.
const CLOCK_JS = `(() => {
  if (window.__pt) return;
  const realRAF = window.requestAnimationFrame.bind(window);
  const realNow = performance.now.bind(performance);
  const realST = window.setTimeout.bind(window);
  const FRAME = 1000 / 60;
  let vnow = realNow(), lastReal = vnow, controlled = false, budget = 0, speed = 1, done = null, idleSpeed = 0;
  const dateBase = Date.now() - vnow;
  let rafQ = new Map(), rafId = 0, tid = 0;
  const timers = new Map();
  const raise = (e) => realST(() => { throw e; }, 0);
  window.requestAnimationFrame = (cb) => { rafQ.set(++rafId, cb); return rafId; };
  window.cancelAnimationFrame = (id) => { rafQ.delete(id); };
  performance.now = () => vnow;
  Date.now = () => Math.round(dateBase + vnow);
  const addTimer = (fn, d, args, repeat) => { const id = ++tid; d = Math.max(0, +d || 0); timers.set(id, { fn, due: vnow + d, delay: Math.max(1, d), args, repeat }); return id; };
  window.setTimeout = (fn, d, ...a) => addTimer(fn, d, a, false);
  window.setInterval = (fn, d, ...a) => addTimer(fn, d, a, true);
  window.clearTimeout = window.clearInterval = (id) => { timers.delete(id); };
  function runTimers() {
    for (let guard = 0; guard < 2000; guard++) {
      let next = null, nid = 0;
      for (const [id, t] of timers) if (t.due <= vnow && (!next || t.due < next.due)) { next = t; nid = id; }
      if (!next) return;
      if (next.repeat) next.due += next.delay; else timers.delete(nid);
      try { typeof next.fn === "function" ? next.fn(...next.args) : (0, eval)(String(next.fn)); } catch (e) { raise(e); }
    }
  }
  function tick(dt) {
    vnow += dt;
    runTimers();
    const q = rafQ; rafQ = new Map();
    for (const cb of q.values()) { try { cb(vnow); } catch (e) { raise(e); } }
  }
  function pump(t) {
    const real = t - lastReal; lastReal = t;
    if (real <= 0) return;
    if (!controlled) tick(Math.min(real, 100));
    else if (budget > 0) {
      for (let i = 0; i < speed && budget > 0; i++) { const d = Math.min(FRAME, budget); budget -= d; tick(d); }
      if (budget <= 0 && done) { const r = done; done = null; r(); }
    } else if (idleSpeed > 0) tick(Math.min(real, 100) * idleSpeed); // slow motion while Argon thinks
  }
  (function loop(t) { pump(t); realRAF(loop); })(realNow());
  // Chrome stops animation frames when the window is covered or hidden; keep the clock moving from a real timer.
  const realSI = window.setInterval.bind(window);
  realSI(() => { const t = realNow(); if (t - lastReal > 50) pump(t); }, 16);
  window.__pt = {
    control(on) { controlled = !!on; if (!on && done) { const r = done; done = null; budget = 0; r(); } },
    idle(s) { idleSpeed = Math.max(0, Math.min(1, +s || 0)); },
    advance(ms, s) {
      speed = Math.max(1, Math.round(s || 1)); budget = Math.max(FRAME, +ms || FRAME);
      return new Promise((r) => {
        done = r;
        // Failsafe on the real clock: if frames stop (hidden tab, stalled renderer), don't hang the lab.
        realST(() => { if (done === r) { done = null; budget = 0; r(); } }, budget * 3 + 3000);
      });
    },
    get now() { return vnow; },
  };
})();`;

// ---------- Targets & versions ----------
// A local game is copied to versions/<id>/v1 and every fix makes a new folder, so the original is never touched.
const TEXT_EXT = new Set([".html", ".htm", ".js", ".mjs", ".css", ".json", ".txt", ".glsl", ".frag", ".vert", ".svg"]);
const MIME = { ".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".mp3": "audio/mpeg", ".ogg": "audio/ogg", ".wav": "audio/wav", ".mp4": "video/mp4", ".webm": "video/webm", ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf", ".wasm": "application/wasm", ".glb": "model/gltf-binary", ".gltf": "model/gltf+json" };

function slug(s) { return String(s).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40) || "game"; }

function resolveTarget(t) {
  if (t.kind === "url") {
    const u = new URL(t.url);
    if (!/^https?:$/.test(u.protocol)) throw new Error("Only http and https URLs can be playtested");
    return { kind: "url", id: `${slug(u.hostname + u.pathname)}-${crypto.createHash("sha1").update(u.href).digest("hex").slice(0, 6)}`, url: u.href, title: u.hostname, editable: false };
  }
  let p = path.resolve(ROOT, t.path || "");
  if (!fs.existsSync(p)) throw new Error(`No file or folder at ${p}`);
  let dir = p, entry = "index.html";
  if (fs.statSync(p).isFile()) { dir = path.dirname(p); entry = path.basename(p); }
  if (!fs.existsSync(path.join(dir, entry))) throw new Error(`No ${entry} in ${dir}`);
  const inGames = path.dirname(dir) === GAMES;
  const id = inGames ? slug(path.basename(dir)) : `${slug(path.basename(dir))}-${crypto.createHash("sha1").update(dir).digest("hex").slice(0, 6)}`;
  return { kind: "local", id, dir, entry, title: path.basename(dir), editable: true };
}

const vdir = (id, v) => path.join(VROOT, id, `v${v}`);
const logFile = (id) => path.join(VROOT, id, "log.json");
const readLog = (id) => readJson(logFile(id), []);
const latestGood = (id) => { const g = readLog(id).filter((e) => !e.rejected); return g.length ? g[g.length - 1].version : 1; };

function copyGame(src, dst) {
  fs.cpSync(src, dst, {
    recursive: true,
    filter: (s) => {
      const b = path.basename(s);
      if (s !== src && (b.startsWith(".") || b === "node_modules")) return false;
      try { return fs.statSync(s).isDirectory() || fs.statSync(s).size < 30e6; } catch (e) { return false; }
    },
  });
}

function initVersions(game, fresh) {
  const base = path.join(VROOT, game.id);
  if (fresh && fs.existsSync(base)) fs.rmSync(base, { recursive: true, force: true });
  if (!fs.existsSync(logFile(game.id))) {
    copyGame(game.dir, vdir(game.id, 1));
    writeJson(logFile(game.id), [{ version: 1, parent: null, iteration: 0, summary: "Original build", bugs: [], edits: [], createdAt: new Date().toISOString() }]);
  }
}

function listFiles(dir, rel = "") {
  const out = [];
  for (const e of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
    const r = path.join(rel, e.name);
    if (e.isDirectory()) out.push(...listFiles(dir, r)); else out.push(r);
  }
  return out;
}

function readSources(dir, entry, budget = 400000) {
  const files = listFiles(dir).filter((f) => TEXT_EXT.has(path.extname(f).toLowerCase()));
  files.sort((a, b) => (a === entry ? -1 : b === entry ? 1 : a.localeCompare(b)));
  const out = [], skipped = [];
  let used = 0;
  for (const f of files) {
    const text = fs.readFileSync(path.join(dir, f), "utf8");
    if (used + text.length > budget || /\.min\.js$/.test(f)) { skipped.push(f); continue; }
    out.push({ file: f, text }); used += text.length;
  }
  return { files: out, skipped };
}

// ---------- Build checks ----------
function compileProblems(file, text) {
  const problems = [];
  const check = (code, where) => {
    if (/^\s*(import|export)\s/m.test(code)) return; // ES modules can't be compiled as classic scripts
    try { new vm.Script(code); } catch (e) { problems.push(`${where}: ${e.message}`); }
  };
  const ext = path.extname(file).toLowerCase();
  if (ext === ".js") check(text, file);
  if (ext === ".html" || ext === ".htm") {
    const re = /<script(?![^>]*\bsrc=)(?![^>]*type=["']?(?:module|importmap|application\/json|text\/template))[^>]*>([\s\S]*?)<\/script>/gi;
    let m;
    while ((m = re.exec(text))) check(m[1], `${file} inline script`);
  }
  return problems;
}

// Difficulty lock for Skyhop. Fingerprints come back "missing" for other games, so the lock is a no-op there.
function difficulty(text) {
  const one = (re) => { const m = text.match(re); return m ? m.slice(1).join(",") : "missing"; };
  const lines = (re) => (text.match(re) || []).map((s) => s.trim().replace(/\s+/g, " ")).join(" | ") || "missing";
  return {
    physics: one(/const G = ([\d.]+), JUMP = ([\d.]+), SPRING = ([\d.]+), SPEED = ([\d.]+)/),
    acceleration: one(/p\.ground \? ([\d.]+) : ([\d.]+)\) \* dt/),
    shortJump: lines(/if \(!keys\.jumpHeld[^\n]*/g),
    landingTolerance: lines(/\.r \+ [\d.]+/g),
    landingMomentum: lines(/p\.vx \*= [^\n]*/g),
    crumbleDelay: one(/crumbleT > ([\d.]+)\)/),
    fallLimit: one(/p\.y < maxY - ([\d.]+)/),
    platformGen: lines(/[^\n]*(?:const r = Math\.max|up = rand|gen\.ang \+=|gen\.ang = Math\.atan2|pl\.amp = |pSpring = |Math\.hypot\(nx, nz\) >)[^\n]*/g),
    harnessBranches: String((text.match(/HARNESS/g) || []).length),
  };
}
const diffKeys = (a, b) => Object.keys(a).filter((k) => a[k] !== b[k]);

// Planted demo bugs: hidden from Argon, checked against each build's source.
function plantedStatus(id) {
  const all = readJson(PLANTED, {});
  const bugs = all[id];
  if (!bugs) return null;
  const versions = readLog(id).filter((e) => fs.existsSync(vdir(id, e.version))).map((e) => {
    const text = listFiles(vdir(id, e.version)).filter((f) => TEXT_EXT.has(path.extname(f))).map((f) => fs.readFileSync(path.join(vdir(id, e.version), f), "utf8")).join("\n");
    // A bug counts as fixed when its planted marker is gone, or when the code matches a known-good fix pattern.
    const isFixed = (b) => !text.includes(b.signature) || (b.fixedIf && new RegExp(b.fixedIf).test(text));
    return { version: e.version, rejected: !!e.rejected, fixed: bugs.filter(isFixed).map((b) => b.id) };
  });
  return { bugs: bugs.map(({ id, title, seen }) => ({ id, title, seen })), versions };
}

// ---------- Argon ----------
async function argon(parts, temperature, attempt = 0) {
  let res;
  try {
    res = await fetch(`${BASE_URL}/models/${encodeURIComponent(MODEL)}:generateContent`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": API_KEY },
      body: JSON.stringify({ contents: [{ role: "user", parts }], generationConfig: { responseMimeType: "application/json", temperature } }),
      signal: AbortSignal.timeout(attempt ? 120000 : 60000), // a hung call must not stall the run
    });
  } catch (e) {
    if (attempt < 1) { console.log(`[argon] call failed (${e.name}); retrying once`); return argon(parts, temperature, attempt + 1); }
    throw new Error(`Argon did not answer: ${e.message}`);
  }
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Argon returned ${res.status}: ${body.error?.message || JSON.stringify(body).slice(0, 300)}`);
  const text = (body.candidates?.[0]?.content?.parts || []).filter((p) => !p.thought).map((p) => p.text || "").join("");
  try { return JSON.parse(text.replace(/^```(?:json)?\s*|\s*```$/g, "")); }
  catch (e) { throw new Error(`Argon's reply was not valid JSON: ${text.slice(0, 200)}`); }
}

async function uploadVideo(file, mime) {
  const data = fs.readFileSync(file);
  const uploadBase = BASE_URL.replace(/\/(v1\w*)$/, "/upload/$1");
  const start = await fetch(`${uploadBase}/files`, {
    method: "POST",
    headers: {
      "x-goog-api-key": API_KEY, "content-type": "application/json",
      "X-Goog-Upload-Protocol": "resumable", "X-Goog-Upload-Command": "start",
      "X-Goog-Upload-Header-Content-Length": String(data.length), "X-Goog-Upload-Header-Content-Type": mime,
    },
    body: JSON.stringify({ file: { display_name: path.basename(file) } }),
  });
  const uploadUrl = start.headers.get("x-goog-upload-url");
  if (!uploadUrl) throw new Error(`Video upload did not start (${start.status})`);
  const up = await fetch(uploadUrl, { method: "POST", headers: { "X-Goog-Upload-Offset": "0", "X-Goog-Upload-Command": "upload, finalize" }, body: data });
  let info = (await up.json()).file;
  for (let i = 0; info && info.state === "PROCESSING" && i < 60; i++) {
    await sleep(3000);
    info = await (await fetch(`${BASE_URL}/${info.name}`, { headers: { "x-goog-api-key": API_KEY } })).json();
  }
  if (!info || info.state !== "ACTIVE") throw new Error(`Video was not ready (${info && info.state})`);
  return info;
}

const KEY_NAMES = "KeyA..KeyZ, Digit0..Digit9, ArrowUp, ArrowDown, ArrowLeft, ArrowRight, Space, Enter, Escape, ShiftLeft, ControlLeft, Tab, Backspace";
function normKey(k) {
  k = String(k || "").trim();
  if (!k) return null;
  const alias = { " ": "Space", space: "Space", up: "ArrowUp", down: "ArrowDown", left: "ArrowLeft", right: "ArrowRight", enter: "Enter", return: "Enter", esc: "Escape", escape: "Escape", shift: "ShiftLeft", ctrl: "ControlLeft", control: "ControlLeft", tab: "Tab", backspace: "Backspace" };
  if (alias[k.toLowerCase()]) return alias[k.toLowerCase()];
  if (/^[a-z]$/i.test(k)) return "Key" + k.toUpperCase();
  if (/^\d$/.test(k)) return "Digit" + k;
  if (/^Key[A-Z]$|^Digit\d$|^Arrow(Up|Down|Left|Right)$|^(Space|Enter|Escape|ShiftLeft|ShiftRight|ControlLeft|Tab|Backspace)$/.test(k)) return k;
  return null;
}

async function argonPlay(sess, shot, info, history) {
  const prompt = `You are Argon, a QA playtester playing a web game in a real browser.
Game: ${sess.game.title}. ${sess.notes ? `Notes from the developer: ${sess.notes}` : "No notes: work out the goal and controls yourself."}
Play it like a real player: start the game if there is a title screen, make as much progress as you can, restart after a game over, and stay alert for anything broken.
Each turn you pick inputs, then the game runs at full speed for "ms" milliseconds of game time${sess.idleSpeed ? `; while you think, the game keeps running in slow motion (about ${sess.idleSpeed}x), so about ${Math.round(sess.idleSpeed * 4000)} ms of game time passes between your turns` : "; the clock is frozen while you think"}.
If the game exposes "grounded", a jump you start is allowed to finish and land before your next turn, so plan one complete move per turn: hold the direction and the jump key together for the whole jump (a full jump is roughly 700-900 ms), rather than splitting a jump across turns.
The attached screenshot is ${Math.round(VIEW.width * SHOT_SCALE)}x${Math.round(VIEW.height * SHOT_SCALE)} px; click coordinates use this image's pixels.
${info.state ? `The game exposes its internal state:\n${JSON.stringify(info.state).slice(0, 7000)}` : "The game does not expose internal state; rely on the screenshot."}
New page errors since last turn: ${JSON.stringify(info.errors.slice(-5))}
Recent turns (oldest first): ${JSON.stringify(history.slice(-8))}
Reply with JSON only:
{"thought": "<=20 words", "hold": ["KeyW"], "tap": ["Space"], "click": null, "ms": 400, "suspectedBug": null, "done": false}
- hold: keys held for the whole turn. tap: keys pressed briefly at the start. Key names: ${KEY_NAMES}.
- click: null or {"x": number, "y": number} in screenshot pixels.
- ms: 100 to 2000.
- suspectedBug: null, or one short sentence about something that looks broken right now (glitch, freeze, wrong number, physics that misbehaves, character doing something odd). Only report what you actually see.
- done: true only if the game has clearly ended and cannot be restarted.`;
  const a = await argon([{ text: prompt }, { inline_data: { mime_type: "image/jpeg", data: shot } }], 0.4);
  const keys = (v) => (Array.isArray(v) ? v : v ? [v] : []).map(normKey).filter(Boolean).slice(0, 4);
  const sx = 1 / SHOT_SCALE;
  return {
    thought: String(a.thought || "").slice(0, 160),
    hold: keys(a.hold), tap: keys(a.tap),
    click: a.click && Number.isFinite(+a.click.x) ? { x: clamp(+a.click.x * sx, 0, VIEW.width - 1), y: clamp(+a.click.y * sx, 0, VIEW.height - 1) } : null,
    ms: clamp(Number(a.ms) || 400, 100, 2000),
    suspectedBug: a.suspectedBug ? String(a.suspectedBug).slice(0, 200) : null,
    done: Boolean(a.done),
  };
}

// Human mode: Argon watches a person play and calls out what looks broken.
async function argonObserve(sess, shots, info, seconds, earlier) {
  const prompt = `You are Argon, a QA engineer watching a human play the web game "${sess.game.title}" live. ${sess.notes ? `Notes from the developer: ${sess.notes}` : ""}
Attached are ${shots.length} frames from the last ${seconds} seconds, oldest first.
${info.state ? `Game state now: ${JSON.stringify(info.state).slice(0, 5000)}` : "The game exposes no internal state; rely on the frames."}
New page errors since the last check: ${JSON.stringify(info.errors.slice(-5))}
Bugs you already noted this run (do not repeat them): ${JSON.stringify(earlier.map((s) => s.note).slice(-8))}
Say in a few words what the player is doing, and report a bug ONLY if something looks genuinely broken: a freeze (frames identical while the player is clearly acting), an error, a number in the HUD that stopped updating or is wrong, a mechanic that doesn't do what it obviously should, a character facing or moving the wrong way, objects that should be gone but still act solid, visual glitches. The player dying or struggling is not a bug.
Reply with JSON only: {"watching": "<=14 words", "suspectedBug": null | "<=25 words, specific, what you saw"}`;
  const parts = [{ text: prompt }, ...shots.map((s) => ({ inline_data: { mime_type: "image/jpeg", data: s } }))];
  const a = await argon(parts, 0.3);
  return { thought: String(a.watching || "").slice(0, 120), suspectedBug: a.suspectedBug ? String(a.suspectedBug).slice(0, 200) : null };
}

function fixPrompt(sess, iteration, version, sources, telemetry, video) {
  return `You are Argon. You just finished playtest iteration ${iteration} of "${sess.game.title}" (build v${version}).${sess.player === "human" ? " A human tester played this run while you watched; \"suspectedBugs\" are the things you called out live." : ""}
Your job is to FIND AND FIX BUGS: things that are actually broken. Examples: errors and crashes, freezes, mechanics that don't do what they obviously should (a pad that should launch but barely moves, a platform that falls but stays solid), wrong numbers in the HUD, characters or objects facing or moving the wrong way, visual glitches.
${sess.polish ? "After the bugs are fixed, you may also make one small visual polish change, marked \"Look:\"." : "Do not make cosmetic or feature changes. Bugs only."}
Hard is not broken. A jump you missed is not a bug. Never make the game easier: do not change physics, speeds, sizes, gaps, timings, tolerances or level generation to help yourself. Edits that change Skyhop's difficulty are rejected automatically.
Never add code that behaves differently under a test harness. The game must play the same for you as for a human.
Use all the evidence: page errors, the suspected bugs you noted while playing, the game state, ${video ? "the attached video of the run, " : ""}and the source code. Read the code for the mechanics you saw misbehave and find the defect.
Rules for edits:
- Each edit names a "file" from the list below and replaces one exact substring ("find" must appear exactly once in that file, copied character for character).
- Keep edits small and targeted. At most 8 edits. Do not reformat unrelated code. Do not repeat earlier fixes.
- Begin each "why" with "Fix:"${sess.polish ? ' or "Look:"' : ""}.
- If you died because you played badly, list it in "bugs" with severity "low" and a title starting "Not a bug:", and make no edit for it.
${video ? "A VIDEO OF THIS RUN IS ATTACHED (thinking time cut out). Watch all of it and give timestamps in evidence, for example \"0:12 island falls but player stays in the air\".\n" : ""}Earlier changes: ${JSON.stringify(readLog(sess.game.id).slice(1).map((e) => ({ v: e.version, summary: e.summary, rejected: !!e.rejected })))}
Telemetry: ${JSON.stringify(telemetry).slice(0, 50000)}

Reply with JSON only:
{"summary": "one sentence", "bugs": [{"title": "...", "evidence": "...", "severity": "high|medium|low"}], "edits": [{"file": "...", "find": "...", "replace": "...", "why": "..."}]}

${sources.files.map((f) => `===== FILE ${f.file} =====\n${f.text}`).join("\n\n")}
${sources.skipped.length ? `(Not included because of size: ${sources.skipped.join(", ")})` : ""}`;
}

function reportPrompt(sess, iteration, telemetry, video) {
  return `You are Argon, a QA playtester. You just finished playtest iteration ${iteration} of the web game at ${sess.game.url}.
You cannot change its code, so write a bug report for its developers. Report only real defects you have evidence for: errors, freezes, broken mechanics, wrong numbers, visual glitches, controls that don't respond. Hard is not broken.
${video ? "A video of the run is attached (thinking time cut out); give timestamps.\n" : ""}Telemetry: ${JSON.stringify(telemetry).slice(0, 50000)}
Reply with JSON only:
{"summary": "one sentence", "bugs": [{"title": "...", "severity": "high|medium|low", "evidence": "...", "steps": "how to reproduce"}]}`;
}

// ---------- Recording ----------
function ffmpeg(args) {
  return new Promise((resolve, reject) => execFile("ffmpeg", args, { maxBuffer: 1e7 }, (err, so, se) => (err ? reject(new Error(String(se).slice(-400))) : resolve())));
}
async function encodeRecording(frameDir, frames, out, label) {
  if (frames.length < 2) return null;
  const list = frames.map((f, i) => {
    const next = frames[i + 1];
    const d = next ? clamp(next.t - f.t, 0.005, 0.1) : 0.1; // long gaps are Argon thinking; cut them
    return `file '${f.file}'\nduration ${d.toFixed(4)}`;
  }).join("\n") + `\nfile '${frames[frames.length - 1].file}'\n`;
  const listFile = path.join(frameDir, "frames.txt");
  fs.writeFileSync(listFile, list);
  // yuv420p needs even dimensions; screencast frames can come back odd-sized.
  const even = "scale=trunc(iw/2)*2:trunc(ih/2)*2";
  const encode = (vf) => ffmpeg(["-y", "-f", "concat", "-safe", "0", "-i", listFile, "-fps_mode", "vfr", "-vf", vf, "-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", out]);
  const font = ["/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf"].find((f) => fs.existsSync(f));
  const text = label.replace(/[':\\]/g, " ");
  try {
    if (!font) throw new Error("no font");
    await encode(`${even},drawtext=fontfile='${font}':text='${text}':x=24:y=24:fontsize=30:fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=12`);
  } catch (e) {
    await encode(even);
  }
  fs.rmSync(frameDir, { recursive: true, force: true });
  return out;
}

// ---------- Session ----------
const clients = new Set();
function emit(type, data) {
  const msg = `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const c of clients) c.write(msg);
}
let S = null; // the running session

function log(kind, text) {
  console.log(`[${kind}] ${text}`);
  emit("log", { kind, text, t: Date.now() });
}

function upsertCard(card) {
  const i = S.cards.findIndex((c) => c.n === card.n);
  if (i >= 0) S.cards[i] = card; else S.cards.push(card);
  emit("card", card);
}

// A game Chrome left over from an earlier session holds the profile lock and blocks every new launch.
async function killStaleBrowser() {
  await new Promise((r) => execFile("pkill", ["-9", "-f", "playtest-profile"], () => r()));
  await sleep(600);
  const prof = path.join(ROOT, ".playtest-profile");
  for (const f of ["SingletonLock", "SingletonSocket", "SingletonCookie"]) fs.rmSync(path.join(prof, f), { force: true });
}

async function launchBrowser() {
  await killStaleBrowser();
  const browser = await puppeteer.launch({
    executablePath: CHROME, headless: false, defaultViewport: VIEW,
    userDataDir: path.join(ROOT, ".playtest-profile"),
    args: [`--window-size=${VIEW.width + 20},${VIEW.height + 100}`, `--window-position=${WINDOW_POS[0]},${WINDOW_POS[1]}`, "--autoplay-policy=no-user-gesture-required",
      "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows", "--no-first-run", "--no-default-browser-check"],
  });
  const page = (await browser.pages())[0] || (await browser.newPage());
  if (S.player !== "human") await page.evaluateOnNewDocument(CLOCK_JS); // a human plays on the real clock
  const cdp = await page.createCDPSession();
  page.on("pageerror", (e) => { S && S.pageErrors.push({ message: String(e.message || e).slice(0, 300), at: Date.now() }); });
  page.on("console", (m) => { if (m.type() === "error" && S) S.pageErrors.push({ message: m.text().slice(0, 300), at: Date.now() }); });
  // Mirror frames to the lab UI and keep them for recordings
  let lastSent = 0;
  cdp.on("Page.screencastFrame", async (f) => {
    cdp.send("Page.screencastFrameAck", { sessionId: f.sessionId }).catch(() => {});
    if (!S) return;
    const now = Date.now();
    if (now - lastSent > 60) { lastSent = now; emit("frame", { data: f.data }); }
    if (S.rec) {
      const file = `f${String(S.rec.frames.length).padStart(5, "0")}.jpg`;
      fs.writeFileSync(path.join(S.rec.dir, file), Buffer.from(f.data, "base64"));
      S.rec.frames.push({ file, t: f.metadata.timestamp });
    }
  });
  await cdp.send("Page.startScreencast", { format: "jpeg", quality: 70, maxWidth: VIEW.width, maxHeight: VIEW.height, everyNthFrame: 1 });
  return { browser, page, cdp };
}

async function screenshot(cdp) {
  const r = await cdp.send("Page.captureScreenshot", { format: "jpeg", quality: 60, clip: { x: 0, y: 0, width: VIEW.width, height: VIEW.height, scale: SHOT_SCALE } });
  return r.data;
}

async function readInfo(page) {
  const state = await page.evaluate(() => { try { return window.playtest && window.playtest.getState ? window.playtest.getState() : null; } catch (e) { return { hookError: String(e) }; } }).catch(() => null);
  const errors = S.pageErrors.splice(0).map((e) => e.message);
  S.iterErrors.push(...errors);
  return { state, errors };
}

async function execute(page, a) {
  for (const k of a.hold) await page.keyboard.down(k);
  for (const k of a.tap) await page.keyboard.down(k);
  if (a.click) await page.mouse.click(a.click.x, a.click.y);
  const advance = (ms) => page.evaluate((ms, s) => (window.__pt ? window.__pt.advance(ms, s) : new Promise((r) => setTimeout(r, ms))), ms, S.speed);
  if (a.tap.length) {
    await advance(Math.min(90, a.ms));
    for (const k of a.tap) await page.keyboard.up(k);
    if (a.ms > 90) await advance(a.ms - 90);
  } else await advance(a.ms);
  for (const k of a.hold) await page.keyboard.up(k);
  // Let a jump finish at full speed so the landing plays out before the next pause (needs the game's state hook).
  let settled = 0;
  for (let t = 0; t < 1800; t += 100) {
    const st = await page.evaluate(() => { try { const s = window.playtest && window.playtest.getState(); return s ? { grounded: s.grounded, status: s.status } : null; } catch (e) { return null; } }).catch(() => null);
    if (!st || st.grounded !== false || (st.status && st.status !== "play")) break;
    await advance(100); settled += 100;
  }
  return settled;
}

const shouldRecord = (n) => S.recordEvery > 0 && (n === 1 || n % S.recordEvery === 0);

async function runIteration(n) {
  const game = S.game;
  const version = game.editable ? latestGood(game.id) : null;
  const url = game.editable ? `http://localhost:${PORT}/play/${game.id}/v${version}/${game.entry}` : game.url;
  const prev = game.editable ? readLog(game.id).find((e) => e.version === version) : null;
  const changes = prev && prev.version > 1 ? prev.edits.map((e) => e.why) : [];
  emit("iteration", { n, version, changes, recorded: shouldRecord(n), player: S.player });
  log("sys", `Iteration ${n}${version ? ` on build v${version}` : ""}`);
  await sleep(changes.length ? 2800 : 1600); // the lab shows its iteration banner

  const card = { n, version, status: "playing", result: null, fix: null, report: null };
  upsertCard(card);
  S.pageErrors = []; S.iterErrors = [];
  try { await S.page.goto(url, { waitUntil: "load", timeout: 30000 }); }
  catch (e) { log("error", `Page did not load: ${e.message}`); }
  await sleep(800); // let the game boot on its own clock
  if (S.player !== "human") await S.page.evaluate((idle) => { if (window.__pt) { window.__pt.control(true); window.__pt.idle(idle); } }, S.idleSpeed).catch(() => {});
  else await S.page.bringToFront().catch(() => {});
  const loadErrors = S.pageErrors.length;

  S.runStarted = Date.now();
  if (shouldRecord(n)) {
    const dir = path.join(RROOT, game.id, `tmp-${n}`);
    fs.rmSync(dir, { recursive: true, force: true });
    fs.mkdirSync(dir, { recursive: true });
    S.rec = { dir, frames: [] };
    emit("rec", { on: true });
  }

  const history = [], suspected = [];
  let outcome = "ran out of steps", best = 0, lastState = null, sameShots = 0, lastShot = "";
  S.endRun = false;
  if (S.player === "human") {
    // The person plays at full speed; Argon checks the feed every few seconds.
    log("sys", `Your turn: play in the Chrome window. Argon is watching. Press "End run" in the lab when you want Argon to fix what it found.`);
    const shots = [];
    outcome = "time limit reached";
    for (let i = 1; i <= S.maxSteps && !S.stop && !S.endRun; i++) {
      const started = Date.now();
      while (Date.now() - started < S.watchEvery * 1000 && !S.stop && !S.endRun) { await sleep(200); while (S.paused && !S.stop && !S.endRun) await sleep(200); }
      if (S.stop || S.endRun) break;
      emit("status", { running: true, paused: false, iteration: n, version, step: i, maxSteps: S.maxSteps });
      const shot = await screenshot(S.cdp);
      shots.push(shot); if (shots.length > 3) shots.shift();
      const info = await readInfo(S.page);
      if (info.state) { lastState = info.state; if (Number.isFinite(info.state.height)) best = Math.max(best, info.state.height); }
      info.errors.forEach((m) => log("error", `Page error: ${m}`));
      let o;
      try { o = await argonObserve(S, shots, info, S.watchEvery * Math.min(shots.length, 3), suspected); }
      catch (e) { log("error", `Argon could not review the frames: ${e.message}`); continue; }
      emit("action", { thought: o.thought, suspectedBug: o.suspectedBug, hold: [], tap: [], click: null, ms: 0, watching: true });
      log("argon", o.thought);
      if (o.suspectedBug) { suspected.push({ step: i, at: `${Math.round((Date.now() - S.runStarted) / 1000)}s`, note: o.suspectedBug }); log("bug", `Argon suspects: ${o.suspectedBug}`); }
      history.push({ check: i, at: `${Math.round((Date.now() - S.runStarted) / 1000)}s`, watching: o.thought, suspectedBug: o.suspectedBug, errors: info.errors,
        state: lastState ? { status: lastState.status, height: lastState.height, gems: lastState.gems, groundKind: lastState.groundKind } : undefined });
    }
    if (S.endRun) outcome = `ended by the player${best ? ` at ${best} m` : ""}`;
  }
  for (let i = 1; S.player !== "human" && i <= S.maxSteps && !S.stop; i++) {
    while (S.paused && !S.stop) await sleep(200);
    emit("status", { running: true, paused: false, iteration: n, version, step: i, maxSteps: S.maxSteps });
    const shot = await screenshot(S.cdp);
    const info = await readInfo(S.page);
    if (info.state) { lastState = info.state; if (Number.isFinite(info.state.height)) best = Math.max(best, info.state.height); }
    if (info.errors.length) info.errors.forEach((m) => log("error", `Page error: ${m}`));
    // A game that stops repainting while inputs keep coming is frozen
    sameShots = shot === lastShot ? sameShots + 1 : 0;
    lastShot = shot;

    let a;
    try { a = await argonPlay(S, shot, info, history); }
    catch (e) { log("error", `Argon could not choose a move: ${e.message}`); await sleep(1500); continue; }
    emit("action", a);
    log("argon", a.thought);
    if (a.suspectedBug) { suspected.push({ step: i, note: a.suspectedBug }); log("bug", `Argon suspects: ${a.suspectedBug}`); }

    let settled = 0;
    try {
      settled = await Promise.race([execute(S.page, a), sleep(45000).then(() => { throw new Error("the game did not advance within 45 s"); })]);
    } catch (e) {
      log("error", `Step ${i} stalled: ${e.message}`);
      for (const k of [...a.hold, ...a.tap]) await S.page.keyboard.up(k).catch(() => {});
      S.iterErrors.push(`stall: ${e.message}`);
    }
    history.push({ step: i, thought: a.thought, hold: a.hold, tap: a.tap, click: a.click, ms: a.ms, landedAfterMs: settled || undefined, suspectedBug: a.suspectedBug,
      after: lastState ? { status: lastState.status, height: lastState.height, grounded: lastState.grounded, groundKind: lastState.groundKind } : undefined,
      frozenScreens: sameShots || undefined });
    if (a.done) { outcome = "Argon ended the run"; break; }
    if (lastState && lastState.status === "over") {
      outcome = `game over at ${lastState.height ?? "?"} m`;
      const after = await readInfo(S.page);
      if (after.state) lastState = after.state;
      if (i > 3) break;
    }
  }
  if (S.stop) outcome = "stopped";
  if (S.player === "human") await S.page.evaluate(() => { document.title = "Argon is reviewing your run…"; }).catch(() => {});

  let recording = null;
  if (S.rec) {
    const rec = S.rec; S.rec = null;
    emit("rec", { on: false });
    const name = `run-${String(n).padStart(3, "0")}${version ? `-v${version}` : ""}${best ? `-${best}m` : ""}.mp4`;
    try {
      recording = await encodeRecording(rec.dir, rec.frames, path.join(RROOT, game.id, name), `Iteration ${n}${version ? `  build v${version}` : ""}`);
      if (recording) log("sys", `Saved recordings/${game.id}/${name}`);
    } catch (e) { log("error", `Could not encode the recording: ${e.message}`); }
  }

  const result = {
    metric: best || history.length, metricLabel: best ? "m" : "steps", steps: history.length, outcome,
    errors: [...new Set(S.iterErrors)].slice(0, 20), loadErrors, suspected,
    recording: recording ? `/recordings/${game.id}/${path.basename(recording)}` : null,
  };
  card.result = result;
  upsertCard(card);
  const runs = readJson(path.join(VROOT, game.id, "runs.json"), []);
  runs.push({ iteration: n, version, ...result });
  writeJson(path.join(VROOT, game.id, "runs.json"), runs);
  if (S.stop) { card.status = "stopped"; upsertCard(card); return; }

  // Argon reviews the run
  card.status = "fixing"; upsertCard(card);
  emit("reviewing", { n, video: !!recording });
  const telemetry = { result, steps: history, endState: lastState, pageErrors: result.errors, suspectedBugs: suspected };
  let video = null;
  if (recording) {
    try { log("argon", "Uploading the recording for Argon to watch…"); video = await uploadVideo(recording, "video/mp4"); }
    catch (e) { log("error", `Could not send the video to Argon: ${e.message}`); }
  }
  const media = video ? [{ file_data: { mime_type: video.mimeType || "video/mp4", file_uri: video.uri } }] : [];
  try {
    if (game.editable) card.fix = await applyFix(n, version, telemetry, media, !!video);
    else {
      const out = await argon([...media, { text: reportPrompt(S, n, telemetry, !!video) }], 0.2);
      card.report = { summary: String(out.summary || ""), bugs: Array.isArray(out.bugs) ? out.bugs : [], watchedRecording: !!video };
      writeJson(path.join(REPORTS, game.id, `iteration-${String(n).padStart(3, "0")}.json`), { url: game.url, iteration: n, ...card.report });
      log("argon", `Bug report: ${card.report.bugs.length} issue(s). ${card.report.summary}`);
    }
    card.status = "done";
  } catch (e) {
    card.status = "failed"; card.fix = { error: e.message };
    log("error", `Review failed: ${e.message}`);
  }
  upsertCard(card);
  if (game.editable) emit("planted", plantedStatus(game.id));
}

async function applyFix(n, version, telemetry, media, watched) {
  const id = S.game.id;
  const src = vdir(id, version);
  const sources = readSources(src, S.game.entry);
  const out = await argon([...media, { text: fixPrompt(S, n, version, sources, telemetry, watched) }], 0.2);
  const edits = Array.isArray(out.edits) ? out.edits.slice(0, 8) : [];
  const texts = new Map(sources.files.map((f) => [f.file, f.text]));
  const all = () => [...texts.values()].join("\n");
  const locked = difficulty(all());
  const applied = [], skipped = [];
  for (const e of edits) {
    const file = String(e.file || S.game.entry).replace(/^\.?\//, "");
    const find = String(e.find || ""), replace = String(e.replace ?? ""), why = String(e.why || "");
    if (!texts.has(file)) { skipped.push({ file, why, reason: "unknown file" }); continue; }
    const before = texts.get(file);
    const count = find ? before.split(find).length - 1 : 0;
    if (count !== 1) { skipped.push({ file, why, reason: count ? `text found ${count} times` : "text not found" }); continue; }
    texts.set(file, before.replace(find, () => replace));
    const changed = diffKeys(locked, difficulty(all()));
    if (changed.length) { texts.set(file, before); skipped.push({ file, why, reason: `would change locked difficulty (${changed.join(", ")})` }); continue; }
    applied.push({ file, find, replace, why });
  }
  const entry = {
    version, parent: version, iteration: n, summary: String(out.summary || ""), bugs: Array.isArray(out.bugs) ? out.bugs : [],
    edits: applied, skipped, watchedRecording: watched, createdAt: new Date().toISOString(),
  };
  for (const s of skipped) log("error", `Skipped edit to ${s.file}: ${s.reason} (${s.why})`);
  if (!applied.length) { entry.noChange = true; log("argon", `No changes. ${entry.summary}`); return entry; }

  const log_ = readLog(id);
  const next = Math.max(...log_.map((x) => x.version)) + 1;
  copyGame(src, vdir(id, next));
  const problems = [];
  for (const f of new Set(applied.map((a) => a.file))) {
    fs.writeFileSync(path.join(vdir(id, next), f), texts.get(f));
    problems.push(...compileProblems(f, texts.get(f)));
  }
  entry.version = next;
  if (problems.length) { entry.rejected = true; entry.rejectReason = problems.join("; "); }
  log_.push(entry);
  writeJson(logFile(id), log_);
  log("argon", `Build v${next}${entry.rejected ? " REJECTED (" + entry.rejectReason + ")" : ""}: ${entry.summary}`);
  for (const a of applied) log("argon", `  ${a.why}`);
  return entry;
}

async function runSession(opts) {
  const game = resolveTarget(opts.target);
  if (game.editable) initVersions(game, opts.fresh);
  S = {
    game, notes: String(opts.notes || "").slice(0, 2000), maxSteps: clamp(Number(opts.maxSteps) || 40, 5, 500),
    iterations: clamp(Number(opts.iterations) || 5, 1, 1000), endless: !!opts.endless, speed: clamp(Number(opts.speed) || 1, 1, 4),
    recordEvery: clamp(Number(opts.recordEvery ?? 5), 0, 100), polish: !!opts.polish,
    player: opts.player === "human" ? "human" : "argon", watchEvery: clamp(Number(opts.watchEvery) || 4, 2, 30), endRun: false, runStarted: Date.now(),
    idleSpeed: clamp(Number(opts.idleSpeed ?? 0.15), 0, 1),
    stop: false, paused: false, cards: [], pageErrors: [], iterErrors: [], rec: null,
  };
  emit("session", publicSession());
  emit("planted", game.editable ? plantedStatus(game.id) : null);
  log("sys", `Playtesting ${game.editable ? `${game.title} (local, Argon can fix it)` : `${game.url} (URL, Argon writes bug reports)`}`);
  try {
    Object.assign(S, await launchBrowser());
    const runs = game.editable ? readJson(path.join(VROOT, game.id, "runs.json"), []) : [];
    const startAt = runs.length ? runs[runs.length - 1].iteration : 0;
    for (let k = 1; (k <= S.iterations || S.endless) && !S.stop; k++) await runIteration(startAt + k);
  } catch (e) {
    log("error", `Session stopped: ${e.message}`);
  } finally {
    if (S.browser) await S.browser.close().catch(() => {});
    S.browser = null;
    S.running = false;
    S.rec = null;
    emit("status", { running: false });
    log("sys", "Playtest finished");
    if (S.onFinished) S.onFinished();
  }
}

// Stops the running session fast (closing the browser aborts the current step) and resolves when it has wound down.
function stopSession() {
  return new Promise((resolve) => {
    if (!S || !S.browser) return resolve();
    S.stop = true; S.paused = false;
    S.onFinished = resolve;
    const proc = S.browser.process();
    S.browser.close().catch(() => {});
    setTimeout(() => { try { if (proc && proc.exitCode === null) proc.kill("SIGKILL"); } catch (e) {} }, 4000); // graceful close failed: force it
    setTimeout(resolve, 20000);
  });
}

// Restart demo: archive what exists, wipe back to the original build, start a fresh session.
async function restartDemo(opts) {
  await stopSession();
  const game = resolveTarget(opts.target);
  const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  const v = path.join(VROOT, game.id), r = path.join(RROOT, game.id), a = path.join(ROOT, "archive", `${game.id}-${stamp}`);
  if (fs.existsSync(v) && readJson(path.join(v, "runs.json"), []).length) {
    fs.mkdirSync(a, { recursive: true });
    fs.renameSync(v, path.join(a, "versions"));
    if (fs.existsSync(r)) fs.renameSync(r, path.join(a, "recordings"));
    console.log(`[demo] archived previous session to archive/${path.basename(a)}`);
  } else {
    fs.rmSync(v, { recursive: true, force: true });
    fs.rmSync(r, { recursive: true, force: true });
  }
  runSession({ ...opts, fresh: true });
}

function publicSession() {
  if (!S) return null;
  return {
    game: { id: S.game.id, title: S.game.title, kind: S.game.kind, url: S.game.url || null, editable: S.game.editable }, player: S.player,
    running: S.running !== false && !!S.browser, paused: S.paused, cards: S.cards,
    runs: S.game.editable ? readJson(path.join(VROOT, S.game.id, "runs.json"), []) : S.cards.filter((c) => c.result).map((c) => ({ iteration: c.n, version: c.version, ...c.result })),
  };
}

// ---------- HTTP ----------
function send(res, code, body, type) {
  res.writeHead(code, { "content-type": type || "application/json", "cache-control": "no-store" });
  res.end(typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body));
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => { data += c; if (data.length > 1e6) req.destroy(); });
    req.on("end", () => { try { resolve(data ? JSON.parse(data) : {}); } catch (e) { reject(e); } });
    req.on("error", reject);
  });
}
function safeJoin(base, rel) {
  const p = path.resolve(base, "." + path.sep + rel);
  return p.startsWith(base + path.sep) || p === base ? p : null;
}
const HEAD = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><style>body{margin:0}[hidden]{display:none!important}</style></head><body>';

function localGames() {
  if (!fs.existsSync(GAMES)) return [];
  return fs.readdirSync(GAMES, { withFileTypes: true }).filter((d) => d.isDirectory() && fs.existsSync(path.join(GAMES, d.name, "index.html")))
    .map((d) => ({ id: slug(d.name), path: `games/${d.name}`, title: d.name, planted: !!readJson(PLANTED, {})[slug(d.name)] }));
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  try {
    if (url.pathname === "/favicon.ico") { res.writeHead(204); return res.end(); }
    if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/playtest.html")) {
      return send(res, 200, fs.readFileSync(path.join(ROOT, "playtest.html")), "text/html; charset=utf-8");
    }
    let m = url.pathname.match(/^\/play\/([a-z0-9-]+)\/v(\d+)\/(.*)$/);
    if (req.method === "GET" && m) {
      const base = vdir(m[1], Number(m[2]));
      const file = safeJoin(base, decodeURIComponent(m[3]) || "index.html");
      if (!file || !fs.existsSync(file) || fs.statSync(file).isDirectory()) return send(res, 404, "Not found", "text/plain");
      const ext = path.extname(file).toLowerCase();
      let body = fs.readFileSync(file);
      if ((ext === ".html" || ext === ".htm") && !/^\s*<!doctype/i.test(body.toString("utf8", 0, 200))) body = HEAD + body.toString("utf8") + "</body></html>";
      return send(res, 200, body, MIME[ext] || "application/octet-stream");
    }
    m = url.pathname.match(/^\/recordings\/([a-z0-9-]+)\/([\w.-]+\.mp4)$/);
    if (req.method === "GET" && m) {
      const file = path.join(RROOT, m[1], m[2]);
      if (!fs.existsSync(file)) return send(res, 404, "Not found", "text/plain");
      return send(res, 200, fs.readFileSync(file), "video/mp4");
    }
    if (req.method === "GET" && url.pathname === "/api/events") {
      res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store", connection: "keep-alive" });
      res.write(`event: hello\ndata: ${JSON.stringify({ session: publicSession() })}\n\n`);
      clients.add(res);
      req.on("close", () => clients.delete(res));
      return;
    }
    if (req.method === "GET" && url.pathname === "/api/config") {
      return send(res, 200, { argon: ARGON_READY, model: MODEL || null, games: localGames(), session: publicSession(), view: VIEW });
    }
    if (req.method === "GET" && url.pathname === "/api/planted") return send(res, 200, plantedStatus(url.searchParams.get("game")));
    if (req.method === "GET" && url.pathname === "/api/versions") return send(res, 200, readLog(url.searchParams.get("game")));
    if (req.method === "POST" && url.pathname === "/api/start") {
      if (!ARGON_READY) return send(res, 400, { error: "Argon is not configured. Set ARGON_API_KEY and ARGON_MODEL in .env." });
      if (S && S.browser) return send(res, 409, { error: "A playtest is already running. Stop it first." });
      const opts = await readBody(req);
      resolveTarget(opts.target); // validate before replying
      runSession(opts);
      return send(res, 200, { ok: true });
    }
    if (req.method === "POST" && url.pathname === "/api/restart-demo") {
      if (!ARGON_READY) return send(res, 400, { error: "Argon is not configured. Set ARGON_API_KEY and ARGON_MODEL in .env." });
      const opts = await readBody(req);
      resolveTarget(opts.target);
      emit("demo-restart", {});
      restartDemo(opts).catch((e) => log("error", `Restart failed: ${e.message}`));
      return send(res, 200, { ok: true });
    }
    if (req.method === "POST" && url.pathname === "/api/pause") {
      if (S) { S.paused = !S.paused; log("sys", S.paused ? "Paused" : "Resumed"); emit("status", { running: true, paused: S.paused }); }
      return send(res, 200, { paused: S ? S.paused : false });
    }
    if (req.method === "POST" && url.pathname === "/api/endrun") {
      if (S && S.player === "human") { S.endRun = true; log("sys", "Run ended by the player; Argon is reviewing it"); }
      return send(res, 200, { ok: true });
    }
    if (req.method === "POST" && url.pathname === "/api/stop") {
      if (S && S.browser) { log("sys", "Stopping"); stopSession(); }
      return send(res, 200, { ok: true });
    }
    send(res, 404, { error: "Not found" });
  } catch (e) {
    console.error(e);
    send(res, 500, { error: e.message });
  }
}).listen(PORT, () => {
  console.log(`Argon Playtest Lab → http://localhost:${PORT}`);
  console.log(ARGON_READY ? `Argon model: ${MODEL}` : "Argon not configured: set ARGON_API_KEY and ARGON_MODEL in .env.");
});
