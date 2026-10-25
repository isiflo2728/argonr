"""The actual loop: Argon writes a scene, looks at what it made, fixes it.

    python3 argon_loop.py runs/<job>          # resume/run a job dir
    python3 argon_loop.py --selftest          # one generate pass, no job dir

A job directory holds everything:
    reference.mp4          what the user filmed
    frames/f*.jpg          evenly spaced stills from it
    <n>.usda               the scene at iteration n
    views<n>/view*.png     turntable renders of it
    views<n>/metrics.json  measured facts: mesh count, verts, bounds
    critique<n>.json       what Argon found wrong, and the fix

Argon never sees a mesh library or a modeller. It writes USD ASCII as text,
which is code generation — its strongest mode — and the fix step is a rewrite
of that text rather than patching a script that then has to run.
"""
import json, os, pathlib, re, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parent
RENDERER = ROOT / "tools" / "usd_render"
MODEL = "gemini-4-argon"
MAX_FRAMES = 8


def load_key():
    env = ROOT / ".env"
    if env.exists():
        found = re.search(r"GEMINI_API_KEY=(\S+)", env.read_text())
        if found:
            os.environ.setdefault("GEMINI_API_KEY", found.group(1))
    if not os.environ.get("GEMINI_API_KEY"):
        sys.exit("No GEMINI_API_KEY. Put it in server/.env")


def client():
    from google import genai
    return genai.Client()


def image_parts(paths):
    """Interactions wants typed content objects, one per image."""
    import base64
    out = []
    for p in paths[:MAX_FRAMES]:
        mime = "image/png" if p.suffix.lower() == ".png" else "image/jpeg"
        out.append({"type": "image",
                    "mime_type": mime,
                    "data": base64.b64encode(p.read_bytes()).decode(),
                    "resolution": "high"})
    return out


def text_part(body):
    return {"type": "text", "text": body}


def ask(c, parts, *, thinking="high", max_tokens=None):
    config = {"thinking_level": thinking}
    if max_tokens:
        config["max_output_tokens"] = max_tokens
    r = c.interactions.create(model=MODEL, input=parts, generation_config=config)
    return r.output_text or ""


def extract(text, kind):
    """Models fence their output more often than not. Take the fenced block if
    there is one, otherwise trust the whole reply."""
    fence = re.search(rf"```(?:{kind})?\s*\n(.*?)```", text, re.S)
    body = fence.group(1) if fence else text
    return body.strip()


# ---------------------------------------------------------------- generate

GENERATE = """You are modelling a real scene from footage of it.

Write a single USD ASCII file (.usda) reproducing what you see. Rules:

- Output ONLY the .usda. No prose, no explanation.
- Start with `#usda 1.0`, set `metersPerUnit = 1` and `upAxis = "Y"`.
- One `def Mesh` per distinct physical object, named for what it is
  (Desk, Mug, Keyboard...). A viewer will read these names.
- REAL WORLD SCALE IN METRES. A mug is about 0.09 m across, a desk about
  1.2 m wide. Getting scale right matters more than detail.
- The supporting surface sits at y = 0 and everything rests on or above it.
  Nothing floats.
- Give every mesh `primvars:displayColor` matching what you see.
- Position with `xformOp:translate` plus `xformOpOrder`.
- Counter-clockwise winding when viewed from outside, or faces render black.
- Boxy approximations are fine and preferred. Keep it under 2000 vertices.

{hint}

Reproduce the layout you observe: what is on the surface, and where relative
to everything else."""


def generate(c, job):
    frames = sorted((job / "frames").glob("*.jpg"))
    hint = (job / "hint.txt").read_text().strip() if (job / "hint.txt").exists() else ""
    hint_line = f"The person filming adds: {hint}" if hint else ""

    parts = image_parts(frames) + [text_part(GENERATE.format(hint=hint_line))]
    text = ask(c, parts, thinking="high", max_tokens=65536)
    usda = extract(text, "usda")
    if not usda.startswith("#usda"):
        usda = "#usda 1.0\n" + usda
    return usda


# ---------------------------------------------------------------- critique

RUBRIC = """G1 manifold    no mesh is degenerate or zero-volume
G2 budget      under 2000 vertices total
G3 grounded    nothing floats; everything rests on the surface or another object
G4 normals     no face renders black from outside
G5 scale       real-world metres, cross-checked between objects
M1 silhouette  the render's outline matches the footage from the same angle
M2 inventory   every object in the footage is present, and nothing invented
M3 layout      relative positions match the footage
V1 reads       recognisable at a glance"""

CRITIQUE = """The first set of images is the real scene, filmed.
The second set is a turntable render of the model built from it.

Measured facts about that model:
{metrics}

Score the model against this rubric, each 0.0 to 1.0:

{rubric}

Reply with ONLY a JSON object:

{{"score": <weighted mean, 0-1>,
  "match_score": <how closely the render matches the footage, 0-1>,
  "object_count": <distinct objects in the model>,
  "headline": "<five words on the single biggest problem>",
  "items": {{"G1": 1.0, "G2": 1.0, "G3": 0.5, "G4": 1.0, "G5": 0.4,
             "M1": 0.6, "M2": 0.7, "M3": 0.8, "V1": 0.7}},
  "defects": [
    {{"id": "d1", "rubric": "G5", "severity": "high|med|low",
      "evidence": "<what you see, with the number that is wrong>",
      "cause": "<why the file produces it>",
      "fix": "<the specific edit to the .usda>"}}
  ],
  "keep": ["<what already works and must not be broken>"]}}

Be specific and quantitative. "The desk is 2.4 m wide; the footage shows
about 1.2 m" beats "the scale is off". At most five defects, worst first."""


def critique(c, job, index):
    views = job / f"views{index}"
    renders = sorted(views.glob("view*.png"))
    reference = sorted((job / "frames").glob("*.jpg"))
    metrics = (views / "metrics.json")
    metrics_text = metrics.read_text() if metrics.exists() else "{}"

    parts = (image_parts(reference) + image_parts(renders)
             + [text_part(CRITIQUE.format(metrics=metrics_text, rubric=RUBRIC))])
    text = ask(c, parts, thinking="high", max_tokens=32768)
    try:
        return json.loads(extract(text, "json"))
    except json.JSONDecodeError:
        return {"score": 0.0, "match_score": None, "object_count": None,
                "headline": "critique did not parse", "items": {},
                "defects": [], "keep": [], "raw": text[:2000]}


# --------------------------------------------------------------------- fix

FIX = """Here is the current .usda:

```usda
{usda}
```

Your own critique of it:

```json
{critique}
```

Rewrite the file so the defects are fixed. Everything under "keep" must
survive unchanged. Output ONLY the complete .usda — not a diff, not an
excerpt, not a word of explanation."""


def fix(c, usda, crit):
    slim = {k: crit.get(k) for k in ("defects", "keep", "headline")}
    text = ask(c, [text_part(FIX.format(usda=usda, critique=json.dumps(slim, indent=1)))],
               thinking="high", max_tokens=65536)
    out = extract(text, "usda")
    return out if out.startswith("#usda") else "#usda 1.0\n" + out


# ------------------------------------------------------------------ render

def render(job, index):
    scene = job / f"{index}.usda"
    views = job / f"views{index}"
    if not RENDERER.exists():
        print(f"  ! renderer missing — build it: cd tools && swiftc -O usd_render.swift -o usd_render")
        return False
    done = subprocess.run([str(RENDERER), str(scene), str(views), "8", "700"],
                          capture_output=True, text=True, timeout=180)
    if done.returncode != 0:
        print(f"  ! render failed: {done.stdout.strip()} {done.stderr.strip()[:200]}")
        return False
    print(f"  {done.stdout.strip()}")
    return True


# -------------------------------------------------------------------- loop

def run(job, passes=3, on_progress=None):
    """Generate, then critique-and-fix. Writes every artefact into `job`."""
    load_key()
    c = client()
    job = pathlib.Path(job)

    def progress(stage, index):
        print(f"[{index}] {stage}")
        if on_progress:
            on_progress(stage, index)

    results = []
    usda = None

    for index in range(passes):
        if index == 0:
            progress("generating", 0)
            started = time.time()
            usda = generate(c, job)
            print(f"  wrote {len(usda)} chars in {time.time()-started:.0f}s")
        else:
            progress("fixing", index)
            started = time.time()
            usda = fix(c, usda, results[-1]["critique"])
            print(f"  rewrote {len(usda)} chars in {time.time()-started:.0f}s")

        (job / f"{index}.usda").write_text(usda)

        progress("rendering", index)
        ok = render(job, index)

        progress("critiquing", index)
        crit = critique(c, job, index) if ok else {
            "score": 0.0, "headline": "did not render", "defects": [],
            "keep": [], "match_score": None, "object_count": None}
        (job / f"critique{index}.json").write_text(json.dumps(crit, indent=2))
        print(f"  score {crit.get('score')} · {crit.get('headline')}")

        results.append({"index": index, "critique": crit})

    return results


def selftest():
    load_key()
    c = client()
    job = ROOT / "runs" / "selftest"
    (job / "frames").mkdir(parents=True, exist_ok=True)
    if not list((job / "frames").glob("*.jpg")):
        (job / "hint.txt").write_text(
            "no footage available; invent a plausible desk with a mug, "
            "keyboard and monitor")
    print("generating from Argon (no footage, hint only)...")
    started = time.time()
    usda = generate(c, job)
    (job / "0.usda").write_text(usda)
    print(f"  {len(usda)} chars in {time.time()-started:.0f}s -> {job}/0.usda")
    render(job, 0)
    print(json.dumps(json.loads((job / "views0" / "metrics.json").read_text()), indent=1)
          if (job / "views0" / "metrics.json").exists() else "(no metrics)")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    elif len(sys.argv) > 1:
        run(sys.argv[1], passes=int(sys.argv[2]) if len(sys.argv) > 2 else 3)
    else:
        sys.exit(__doc__)
