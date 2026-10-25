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

    CaptureScreen   record a 10s orbit (or fall back to one photo)
    GeneratingScreen  live loop stages, current defect in Argon's words
    ViewerScreen    AR + version strip; tap v0 / v5 to swap in place,
                    Iterate for another pass without leaving AR

The viewer opens the moment iteration 0 lands, so the model is on the table
while the loop is still improving it. That swap is the demo.

## 4. The contract

Swap `mock_server.py` for the real one; keep these three endpoints and the
iOS side needs no changes.

    POST /generate   multipart: video (mp4) OR image (jpeg), + hint, + kind
                     kind is "scene" (orbit video) or "object" (single photo)
                     -> {"job_id": "..."}
    GET  /status/<job>        -> JobStatus
    GET  /model/<job>/<n>.usdz

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
