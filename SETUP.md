# argonr — setup

Phone is the viewer. Laptop runs the loop. They talk over the local network.

## 0. Dependencies

    brew install ffmpeg      # extracts reference frames from the capture

That is the only one. There is no modeller in the pipeline: Argon emits USD
ASCII (.usda) directly, and the turntable renderer is 90 lines of Swift against
SceneKit, which ships with macOS.

    cd server/tools && swiftc -O usd_render.swift -o usd_render

Needed for the real pipeline, not just the mock. Until it's there, models come
back `null` and the AR view stays empty.

## 1. Start the server

    cd server
    python3 mock_server.py          # 0.0.0.0:8787, stdlib only

Port 8787, not 8000 — you already have something on 8000.

Your LAN IP right now: **10.1.63.55** → so the phone wants
`http://10.1.63.55:8787`. Re-check with `ipconfig getifaddr en0` if you move
networks; the app has an editable field for it on the prompt screen, so no
rebuild needed.

## 2. Run on a real device

AR does nothing in the simulator. Plug the phone in, pick it as the
destination, set a team under Signing & Capabilities. Camera and local-network
usage strings are already in the build settings.

**If the first request fails with an ATS error:** Target → Info → add
`App Transport Security Settings` → `Allow Local Networking` = YES. Only needed
if plain HTTP gets blocked; try without it first.

## 3. What's wired

The app is a viewer. Models are built elsewhere; its job is to put one on the
table in front of you and let you say what should change.

    LoadScreen    paste a model URL, or attach to a job on the loop server
    ViewerScreen  AR placement, version strip, and a text field for changes

Two ways in, deliberately:

**Paste a URL.** Renders anything reachable. No versions and no iteration, but
it cannot be broken by a backend being down — which is the one thing you want
guaranteed when a judge is holding the phone.

**Attach to a job.** Adds the version strip and the ability to ask for
changes. Needs the three endpoints below.

## 4. The contract

Swap `mock_server.py` for the real one; keep these three endpoints and the
iOS side needs no changes.

    POST /generate   multipart: video (mp4) OR image (jpeg), + hint, + kind
                     kind is "scene" (orbit video) or "object" (single photo)
                     -> {"job_id": "..."}
    GET  /status/<job>        -> JobStatus
    GET  /model/<job>/<n>.usda

JobStatus:

    {"stage": "generating|rendering|watching|critiquing|fixing|done|error",
     "iteration": 2, "total_iterations": 6, "done": false, "error": null,
     "iterations": [
       {"index": 0, "score": 0.38, "match_score": 0.42, "object_count": 3,
        "model_path": "/model/ab12/0.usdz", "headline": "first pass",
        "defects": [{"id": "d1", "rubric": "G4", "severity": "high",
                     "evidence": "142 flipped faces; lid renders black",
                     "cause": "extrude without recalculating normals",
                     "fix": "call normals_make_consistent after the extrude"}]}
     ]}

Server speaks snake_case; the decoder converts. `Models.swift` is the only
coupling between the halves — change both together or neither.

## 5. Next

`usda_build.py` is the stand-in for what Argon writes. Variants 0-5 start
wrong — oversized, geometry floating free, normals inverted — and get
corrected, so the version strip has something real before the loop exists.

Replacing that one file with Argon's output is the whole remaining job. Argon
emits a `.usda`; `usd_render` renders eight turntable frames and a
`metrics.json` of measured facts (mesh count, vertex count, bounds); Argon
reads those next to the reference frames and rewrites the `.usda`.


## 6. Models hosted elsewhere

`model_path` may be a path on the loop server **or a fully-qualified URL** —
cloud storage, a CDN, a signed link. The app takes either; an absolute string
ignores the base address.

Two things the host must get right:

**HTTPS.** App Transport Security blocks plain HTTP to a public host. Cloud
storage is https by default, so this is only a problem for a hand-rolled host.

**USD.** The viewer needs `.usda`, `.usdc` or `.usdz`. It does **not** load
glTF, GLB or OBJ. The app identifies the format from the file's leading bytes
rather than the URL, because signed links end in a query string and object
keys often carry no extension at all. A glTF gets a plain error naming what
arrived instead of failing silently.

To exercise that path before the real backend exists, point the mock at any
static host:

    MODEL_BASE_URL=https://storage.googleapis.com/your-bucket python3 mock_server.py

`model_path` then comes back absolute, and the app fetches from there.


## 7. Models that are not USD

The viewer needs USD. If the model host produces **GLB, OBJ or STL** — which
is common, since most generators emit glTF — point the app at the conversion
proxy instead of at the file:

    http://<laptop>:8787/convert?url=<url-encoded model url>

It fetches the model, converts it to USD ASCII, and caches the result by URL.
A model does not change under its own link, so the second fetch is instant.

What survives the conversion: triangle geometry, node transforms (translation,
rotation, scale), and flat base colour per material. What does not: textures,
PBR maps, animation, skinning. For a model being read on a table that is the
part that matters.

Verified against hand-built files of each format, including a GLB whose
second mesh is positioned by a node transform — the colours and the offset
both come through.

No conversion is needed if the host can emit `.usda`, `.usdc` or `.usdz`.
That stays the better option: ask first, convert second.
