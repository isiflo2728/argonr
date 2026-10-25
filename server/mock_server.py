#!/usr/bin/env python3
"""Mock of the real loop server, stdlib only.

    python3 mock_server.py            # 0.0.0.0:8787

Takes the phone's reference photo, walks a job through the real stages on a
timer, and hands back real .usdz files — so the iOS app can be built and
demoed before loop.py or Argon exist. Models come from Blender if it's on
PATH, otherwise from fixtures/*.usdz.

Contract (matches Models.swift):
    POST /generate        multipart: image (jpeg, optional) + hint  -> {"job_id": ...}
    POST /iterate/<job>   one more pass on demand                   -> {"ok": true}
    GET  /status/<job>                                              -> JobStatus
    GET  /model/<job>/<n>.usdz                                      -> binary
"""
import email, json, os, shutil, subprocess, sys, threading, time, uuid
from email.policy import default as email_policy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "runs"
FIXTURES = ROOT / "fixtures"
RENDERER = ROOT / "tools" / "usd_render"   # optional; only the loop needs it

# Set this to hand back absolute model URLs instead of paths on this server —
# which is what happens once models live in cloud storage. Lets the app's
# remote-URL path be exercised before the real backend is ready.
#   MODEL_BASE_URL=https://storage.googleapis.com/your-bucket python3 mock_server.py
MODEL_BASE_URL = os.environ.get("MODEL_BASE_URL", "").rstrip("/")


def model_url(job, index):
    leaf = f"{job}/{index}.usda"
    return f"{MODEL_BASE_URL}/{leaf}" if MODEL_BASE_URL else f"/model/{leaf}"

FIRST_PASS = 3          # iterations produced by /generate
MAX_VARIANT = 5         # blender_build.py knows variants 0..5
STAGES = ["generating", "rendering", "watching", "critiquing", "fixing"]
SECONDS_PER_STAGE = 1.4

JOBS = {}
LOCK = threading.Lock()

DEFECTS = [
    {"id": "d1", "rubric": "G5", "severity": "high",
     "evidence": "Model is 2.4 m across; the photo reads about 1 m.",
     "cause": "scale applied twice", "fix": "apply scale once, then freeze the transform"},
    {"id": "d2", "rubric": "G3", "severity": "high",
     "evidence": "A loose chunk floats 0.6 m above the body, unconnected.",
     "cause": "stray primitive never joined", "fix": "remove loose parts before export"},
    {"id": "d3", "rubric": "G4", "severity": "high",
     "evidence": "142 flipped faces; the interior renders black.",
     "cause": "extrude without recalculating normals",
     "fix": "call normals_make_consistent after the extrude"},
    {"id": "d4", "rubric": "M1", "severity": "med",
     "evidence": "Silhouette overlap with the photo is 0.61; target is 0.85.",
     "cause": "body too boxy against the reference",
     "fix": "bevel the vertical edges and taper toward the base"},
    {"id": "d5", "rubric": "G8", "severity": "med",
     "evidence": "Every part shares one material; the photo shows two.",
     "cause": "single material slot", "fix": "add a second slot and assign it"},
    {"id": "d6", "rubric": "V1", "severity": "low",
     "evidence": "Reads flat from the front.",
     "cause": "curvature too shallow", "fix": "raise the top arc about 20 percent"},
]
HEADLINES = ["first pass", "scale corrected", "loose geometry removed",
             "silhouette tightened", "second material added", "silhouette tuned"]


FFMPEG = shutil.which("ffmpeg")


def extract_frames(job, count=8):
    """Even-spaced stills from the reference clip. These are what the critique
    scores against at specific angles; the clip itself is what Argon reasons
    over. No ffmpeg -> the real backend can do this instead."""
    clip = OUT / job / "reference.mp4"
    if not clip.exists() or not FFMPEG:
        return []
    frames_dir = OUT / job / "frames"
    frames_dir.mkdir(exist_ok=True)
    try:
        subprocess.run(
            [FFMPEG, "-y", "-loglevel", "error", "-i", str(clip),
             "-vf", f"fps={count}/10,scale=640:-2", str(frames_dir / "f%02d.jpg")],
            check=True, capture_output=True, timeout=120)
    except Exception as exc:
        print(f"[mock] ffmpeg failed: {exc}")
        return []
    return sorted(frames_dir.glob("*.jpg"))


def build_model(job, index):
    """Writes the scene as USD ASCII. No modeller involved — Argon emits this
    text directly, and RealityKit loads it on the phone as-is."""
    dest = OUT / job / f"{index}.usda"
    dest.parent.mkdir(parents=True, exist_ok=True)
    variant = min(index, MAX_VARIANT)
    try:
        subprocess.run([sys.executable, str(ROOT / "usda_build.py"), str(dest), str(variant)],
                       check=True, capture_output=True, timeout=60)
    except Exception as exc:
        print(f"[mock] usda_build failed: {exc}")
        return None

    # The loop's eyes: render turntable frames with Apple's own USD loader, so
    # what the critique sees matches what the phone will show.
    if RENDERER.exists():
        views = OUT / job / f"views{index}"
        try:
            subprocess.run([str(RENDERER), str(dest), str(views), "8", "700"],
                           check=True, capture_output=True, timeout=120)
        except Exception as exc:
            print(f"[mock] render failed: {exc}")
    return dest


def worker(job):
    """Produces iterations until the job's target is met, then parks."""
    while True:
        with LOCK:
            state = JOBS[job]
            index = len(state["iterations"])
            if index >= state["target"]:
                state["stage"] = "done"
                state["done"] = True
                state["running"] = False
                return

        for stage in STAGES:
            with LOCK:
                JOBS[job]["stage"] = stage
                JOBS[job]["iteration"] = index
            time.sleep(SECONDS_PER_STAGE)

        path = build_model(job, index)
        with LOCK:
            JOBS[job]["iterations"].append({
                "index": index,
                "score": round(min(0.38 + 0.095 * index, 0.97), 2),
                "match_score": round(min(0.42 + 0.09 * index, 0.95), 2)
                               if JOBS[job]["has_reference"] else None,
                "object_count": min(1 + index, 4) if JOBS[job]["kind"] == "scene" else None,
                "model_path": model_url(job, index) if path else None,
                "headline": HEADLINES[min(index, len(HEADLINES) - 1)],
                "defects": DEFECTS[index:index + 2],
            })


def start_worker(job):
    with LOCK:
        if JOBS[job]["running"]:
            return
        JOBS[job]["running"] = True
        JOBS[job]["done"] = False
    threading.Thread(target=worker, args=(job,), daemon=True).start()


def parse_multipart(content_type, body):
    raw = b"Content-Type: " + content_type.encode() + b"\r\nMIME-Version: 1.0\r\n\r\n" + body
    msg = email.message_from_bytes(raw, policy=email_policy)
    fields = {}
    if not msg.is_multipart():
        return fields
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition")
        payload = part.get_payload(decode=True) or b""
        fields[name] = payload if part.get_filename() else payload.decode("utf-8", "replace")
    return fields


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"[mock] {fmt % args}")

    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_POST(self):
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        if parts == ["generate"]:
            fields = parse_multipart(self.headers.get("Content-Type", ""), body)
            video = fields.get("video") if isinstance(fields.get("video"), bytes) else None
            image = fields.get("image") if isinstance(fields.get("image"), bytes) else None
            hint = fields.get("hint", "")
            kind = fields.get("kind", "object")

            job = uuid.uuid4().hex[:8]
            (OUT / job).mkdir(parents=True, exist_ok=True)
            if video:
                (OUT / job / "reference.mp4").write_bytes(video)
            elif image:
                (OUT / job / "reference.jpg").write_bytes(image)

            with LOCK:
                JOBS[job] = {"hint": hint, "kind": kind,
                             "has_reference": bool(video or image),
                             "stage": "generating",
                             "iteration": 0, "total_iterations": FIRST_PASS,
                             "target": FIRST_PASS, "done": False, "running": False,
                             "iterations": [], "error": None}

            size = len(video or image or b"")
            source = "video" if video else "image" if image else "hint only"
            print(f"[mock] job {job}: kind={kind} {source} {size}B hint={hint!r}")
            if video:
                frames = extract_frames(job)
                print(f"[mock] job {job}: extracted {len(frames)} reference frames")
            start_worker(job)
            return self._send(200, json.dumps({"job_id": job}).encode())

        if len(parts) == 2 and parts[0] == "iterate":
            job = parts[1]
            with LOCK:
                if job not in JOBS:
                    return self._send(404, b'{"error":"no such job"}')
                JOBS[job]["target"] += 1
                JOBS[job]["total_iterations"] = JOBS[job]["target"]
            start_worker(job)
            print(f"[mock] job {job}: iterate -> target {JOBS[job]['target']}")
            return self._send(200, b'{"ok":true}')

        self._send(404, b'{"error":"not found"}')

    def do_GET(self):
        parts = [p for p in self.path.split("?")[0].split("/") if p]

        if len(parts) == 2 and parts[0] == "status":
            with LOCK:
                state = JOBS.get(parts[1])
                payload = {k: v for k, v in state.items()
                           if k not in ("running", "has_reference", "hint", "kind")} if state else None
            body = json.dumps(payload).encode() if payload else b'{"error":"no such job"}'
            return self._send(200 if payload else 404, body)

        if len(parts) == 3 and parts[0] == "model":
            path = OUT / parts[1] / parts[2]
            if not path.exists():
                return self._send(404, b'{"error":"not built yet"}')
            ctype = "model/vnd.usdz+zip" if path.suffix == ".usdz" else "text/plain"
            return self._send(200, path.read_bytes(), ctype)

        self._send(404, b'{"error":"not found"}')


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    FIXTURES.mkdir(exist_ok=True)
    print(f"[mock] renderer: {RENDERER if RENDERER.exists() else 'not built (models still work; the loop has no eyes)'}")
    print("[mock] listening on 0.0.0.0:8787")
    ThreadingHTTPServer(("0.0.0.0", 8787), Handler).serve_forever()
