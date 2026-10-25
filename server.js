// Argon Playtest Lab server.
// Serves the lab UI and versioned builds of Skyhop, and relays play and fix requests to the Argon model.
//   node server.js            (reads .env if present)
// Env: ARGON_API_KEY (or GEMINI_API_KEY), ARGON_MODEL, ARGON_BASE_URL, PORT

const http = require("http");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const ROOT = __dirname;
const VDIR = path.join(ROOT, "versions");
const LOG = path.join(VDIR, "log.json");
const RUNS = path.join(VDIR, "runs.json");
const RDIR = path.join(ROOT, "recordings");

loadDotEnv(path.join(ROOT, ".env"));
const API_KEY = process.env.ARGON_API_KEY || process.env.GEMINI_API_KEY || "";
const MODEL = process.env.ARGON_MODEL || "";
const BASE_URL = (process.env.ARGON_BASE_URL || "https://generativelanguage.googleapis.com/v1beta").replace(/\/$/, "");
const PORT = Number(process.env.PORT) || 5173;
const ARGON_READY = Boolean(API_KEY && MODEL);

function loadDotEnv(file) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !(m[1] in process.env)) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
}

// ---------- Versions ----------
function readLog() { return JSON.parse(fs.readFileSync(LOG, "utf8")); }
function writeLog(log) { fs.writeFileSync(LOG, JSON.stringify(log, null, 2)); }
function versionFile(v) { return path.join(VDIR, `v${v}.html`); }
function latestGood(log) { return [...log].reverse().find((e) => !e.rejected).version; }

function initVersions() {
  if (!fs.existsSync(VDIR)) fs.mkdirSync(VDIR);
  if (!fs.existsSync(LOG)) {
    fs.copyFileSync(path.join(ROOT, "skyhop.html"), versionFile(1));
    writeLog([{ version: 1, parent: null, iteration: 0, summary: "Original build", bugs: [], edits: [], createdAt: new Date().toISOString() }]);
  }
}

function inlineScripts(html) {
  const out = [];
  const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
  let m;
  while ((m = re.exec(html))) out.push(m[1]);
  return out;
}

function validateBuild(html) {
  const problems = [];
  for (const code of inlineScripts(html)) {
    try { new vm.Script(code); } catch (e) { problems.push(`Script does not compile: ${e.message}`); }
  }
  if (!html.includes("window.skyhop")) problems.push("Playtest harness (window.skyhop) was removed");
  return problems;
}

// ---------- Argon ----------
async function argon(parts, temperature) {
  const res = await fetch(`${BASE_URL}/models/${encodeURIComponent(MODEL)}:generateContent`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": API_KEY },
    body: JSON.stringify({
      contents: [{ role: "user", parts }],
      generationConfig: { responseMimeType: "application/json", temperature },
    }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Argon returned ${res.status}: ${body.error?.message || JSON.stringify(body).slice(0, 300)}`);
  const text = (body.candidates?.[0]?.content?.parts || []).filter((p) => !p.thought).map((p) => p.text || "").join("");
  try {
    return JSON.parse(text.replace(/^```(?:json)?\s*|\s*```$/g, ""));
  } catch (e) {
    throw new Error(`Argon's reply was not valid JSON: ${text.slice(0, 200)}`);
  }
}

const PLAY_RULES = `You are Argon, playtesting the 3D platform game Skyhop. Climb as high as possible.
Coordinates: x and z are horizontal, y is up. Each platform is listed relative to the player (dx, dy, dz) with its radius.
Physics: gravity 32, jump velocity 12.5 (peak about 2.4 m when jump is held; releasing early cuts the jump), run speed 7.2 m/s.
A held jump stays airborne about 0.8 s and covers about 5.5 m at full speed on level ground, less when climbing.
Platform kinds: start/normal are solid, moving drifts sideways, crumble falls about 0.55 s after you land, spring launches you about 7.5 m up.
You land only from above. Falling 16 m below your best height ends the run. Gems float 1.1 m above some platforms.
Each turn you choose one action that lasts "seconds". Move is a world-space direction {x, z} with length up to 1.
Reply with JSON only: {"thought": "<=16 words", "move": {"x": number, "z": number}, "jump": boolean, "hold": boolean, "seconds": number between 0.1 and 1.2}`;

async function act({ state, history, screenshot }) {
  const parts = [{ text: `${PLAY_RULES}\n\nRecent turns (oldest first):\n${JSON.stringify(history || [])}\n\nCurrent state:\n${JSON.stringify(state)}` }];
  if (screenshot && screenshot.startsWith("data:image/")) {
    const [, mime, data] = screenshot.match(/^data:(image\/\w+);base64,(.*)$/) || [];
    if (data) parts.push({ inline_data: { mime_type: mime, data } });
  }
  const a = await argon(parts, 0.4);
  return {
    thought: String(a.thought || "").slice(0, 160),
    move: { x: Number(a.move?.x) || 0, z: Number(a.move?.z) || 0 },
    jump: Boolean(a.jump),
    hold: a.hold === undefined ? Boolean(a.jump) : Boolean(a.hold),
    seconds: Math.min(1.2, Math.max(0.1, Number(a.seconds) || 0.4)),
  };
}

async function fix({ version, iteration, telemetry }) {
  const log = readLog();
  const source = fs.readFileSync(versionFile(version), "utf8");
  const earlier = log.filter((e) => e.version > 1).map((e) => ({ version: e.version, summary: e.summary, rejected: e.rejected || false }));
  const prompt = `You are Argon. You just finished playtest iteration ${iteration} of Skyhop (build v${version}).
Every pass has two jobs, and you must do both:
1. FIX: find real bugs and unfair design shown by the telemetry and fix them. Look at errors and anomalies, deaths that were not the player's fault (impossible gaps, platforms too high, landing failures, crumbling too fast), getting stuck, and anything else the evidence supports.
2. LOOK BETTER: make the game visibly better looking than the last build, in a way a viewer would notice right away. Ideas: richer lighting and real shadows, nicer materials and colors, grass or detail on islands, trails and particles, a glow on gems, a more alive sky (sun, moon, aurora), screen effects on landing, character animation (blinking, squash, a little hat), HUD polish. Pick one or two new improvements each pass, building on the earlier passes instead of undoing them. Keep it running smoothly at 60 fps.
Rules:
- Each edit replaces one exact substring of the file ("find" must appear exactly once, copied character for character). To add new code, find a short unique anchor line and replace it with the anchor plus your new code.
- Only load scripts from cdnjs.cloudflare.com. The game uses three.js r128 (global THREE); use only APIs that exist in r128.
- Keep the playtest harness (window.skyhop, its step/reset/getState/screenshot methods, logEvent calls) working.
- At most 8 edits. Do not reformat or rewrite unrelated code. Do not repeat fixes already made.
- Mark each edit's "why" starting with "Fix:" or "Look:".
Earlier fixes: ${JSON.stringify(earlier)}
Telemetry from this iteration:
${JSON.stringify(telemetry).slice(0, 60000)}

Reply with JSON only:
{"summary": "one sentence", "bugs": [{"title": "...", "evidence": "...", "severity": "high|medium|low"}], "edits": [{"find": "...", "replace": "...", "why": "..."}]}

FILE v${version}:
${source}`;

  const out = await argon([{ text: prompt }], 0.2);
  const edits = Array.isArray(out.edits) ? out.edits.slice(0, 8) : [];
  let html = source;
  const applied = [], skipped = [];
  for (const e of edits) {
    const find = String(e.find || ""), replace = String(e.replace ?? "");
    const count = find ? html.split(find).length - 1 : 0;
    if (count !== 1) { skipped.push({ ...e, reason: count === 0 ? "text not found" : `text found ${count} times` }); continue; }
    html = html.replace(find, () => replace);
    applied.push({ find, replace, why: String(e.why || "") });
  }

  const next = Math.max(...log.map((e) => e.version)) + 1;
  const entry = {
    version: next, parent: version, iteration,
    summary: String(out.summary || ""), bugs: Array.isArray(out.bugs) ? out.bugs : [],
    edits: applied, skipped, createdAt: new Date().toISOString(),
  };
  if (!applied.length) {
    entry.version = version; entry.noChange = true;
    return entry;
  }
  const problems = validateBuild(html);
  fs.writeFileSync(versionFile(next), html);
  if (problems.length) { entry.rejected = true; entry.rejectReason = problems.join("; "); }
  log.push(entry);
  writeLog(log);
  console.log(`[fix] iteration ${iteration}: v${version} → v${next}${entry.rejected ? " REJECTED: " + entry.rejectReason : ""} · ${applied.length} applied, ${skipped.length} skipped · ${entry.summary}`);
  for (const e of applied) console.log(`      ${e.why}`);
  return entry;
}

function rollback({ version, reason }) {
  const log = readLog();
  const e = log.find((x) => x.version === version);
  if (e && version !== 1) { e.rejected = true; e.rejectReason = reason || "Failed to load in the lab"; writeLog(log); }
  return { version: latestGood(log), log };
}

// ---------- HTTP ----------
function send(res, code, body, type) {
  res.writeHead(code, { "content-type": type || "application/json", "cache-control": "no-store" });
  res.end(typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body));
}
function readRuns() { try { return JSON.parse(fs.readFileSync(RUNS, "utf8")); } catch (e) { return []; } }
function readRaw(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0;
    req.on("data", (c) => { size += c.length; if (size > limit) req.destroy(); else chunks.push(c); });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => { data += c; if (data.length > 20e6) req.destroy(); });
    req.on("end", () => { try { resolve(data ? JSON.parse(data) : {}); } catch (e) { reject(e); } });
    req.on("error", reject);
  });
}

const HEAD = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><style>body{margin:0}[hidden]{display:none!important}</style></head><body>';
// Keeps WebGL frames readable so the lab can record them, whatever Argon does to the renderer setup.
const RECORDABLE = '<script>(function(){var g=HTMLCanvasElement.prototype.getContext;HTMLCanvasElement.prototype.getContext=function(t,o){if(/webgl/.test(t))o=Object.assign({},o,{preserveDrawingBuffer:true});return g.call(this,t,o)}})()</script>';

initVersions();

http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  try {
    if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/playtest.html")) {
      return send(res, 200, fs.readFileSync(path.join(ROOT, "playtest.html")), "text/html; charset=utf-8");
    }
    if (req.method === "GET" && url.pathname === "/game") {
      const v = Number(url.searchParams.get("v")) || latestGood(readLog());
      const file = versionFile(v);
      if (!fs.existsSync(file)) return send(res, 404, `No build v${v}`, "text/plain");
      const html = fs.readFileSync(file, "utf8");
      const page = /^\s*<!doctype/i.test(html) ? html.replace(/<head[^>]*>/i, (m) => m + RECORDABLE) : HEAD + RECORDABLE + html + "</body></html>";
      return send(res, 200, page, "text/html; charset=utf-8");
    }
    if (req.method === "GET" && url.pathname === "/api/config") {
      return send(res, 200, { argon: ARGON_READY, model: MODEL || null });
    }
    if (req.method === "GET" && url.pathname === "/api/versions") return send(res, 200, readLog());
    if (req.method === "POST" && url.pathname === "/api/reset-versions") {
      for (const f of fs.readdirSync(VDIR)) fs.unlinkSync(path.join(VDIR, f)); // also clears runs.json
      initVersions();
      return send(res, 200, readLog());
    }
    if (req.method === "POST" && url.pathname === "/api/act") {
      if (!ARGON_READY) return send(res, 400, { error: "Argon is not configured. Set ARGON_API_KEY and ARGON_MODEL." });
      const body = await readBody(req);
      const a = await act(body);
      console.log(`[act] h=${body.state?.height ?? "?"}m ${a.jump ? "JUMP " : ""}${a.thought}`);
      return send(res, 200, a);
    }
    if (req.method === "POST" && url.pathname === "/api/fix") {
      if (!ARGON_READY) return send(res, 400, { error: "Argon is not configured. Set ARGON_API_KEY and ARGON_MODEL." });
      return send(res, 200, await fix(await readBody(req)));
    }
    if (req.method === "POST" && url.pathname === "/api/rollback") return send(res, 200, rollback(await readBody(req)));
    if (req.method === "POST" && url.pathname === "/api/report") {
      const b = await readBody(req);
      console.log(`[run] iteration ${b.iteration} on v${b.version}: ${b.height} m, ${b.gems} gems, ${b.steps} steps, ${b.outcome}, ${b.errors} errors`);
      const runs = readRuns().filter((r) => r.iteration !== b.iteration);
      runs.push(b);
      fs.writeFileSync(RUNS, JSON.stringify(runs, null, 2));
      return send(res, 200, { ok: true });
    }
    if (req.method === "GET" && url.pathname === "/api/runs") return send(res, 200, readRuns());
    if (req.method === "POST" && url.pathname === "/api/recording") {
      if (!fs.existsSync(RDIR)) fs.mkdirSync(RDIR);
      const n = String(Number(url.searchParams.get("iteration")) || 0).padStart(3, "0");
      const v = Number(url.searchParams.get("version")) || 0;
      const h = Number(url.searchParams.get("height")) || 0;
      const file = `run-${n}-v${v}-${h}m.webm`;
      const data = await readRaw(req, 500e6);
      fs.writeFileSync(path.join(RDIR, file), data);
      console.log(`[rec] saved recordings/${file} (${(data.length / 1e6).toFixed(1)} MB)`);
      return send(res, 200, { file });
    }
    if (req.method === "GET" && url.pathname.startsWith("/recordings/")) {
      const file = path.join(RDIR, path.basename(url.pathname));
      if (!fs.existsSync(file)) return send(res, 404, "Not found", "text/plain");
      return send(res, 200, fs.readFileSync(file), "video/webm");
    }
    send(res, 404, { error: "Not found" });
  } catch (e) {
    console.error(e);
    send(res, 500, { error: e.message });
  }
}).listen(PORT, () => {
  console.log(`Argon Playtest Lab → http://localhost:${PORT}`);
  console.log(ARGON_READY ? `Argon model: ${MODEL}` : "Argon not configured: running with the offline bot (set ARGON_API_KEY and ARGON_MODEL).");
});
