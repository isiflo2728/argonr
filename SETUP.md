# argonr — setup

Describe an object. The backend builds it. It lands on a real surface in
front of you.

## Run it

    cd backend
    cp .env.example .env        # add GEMINI_API_KEY
    pip install -r requirements.txt
    uvicorn app.main:app --host 0.0.0.0 --port 8010

Then put `http://<your-laptop>:8010` in the app under Settings.
Find the address with `ipconfig getifaddr en0`.

AR does nothing in the simulator — run on a real device. The camera and
local-network usage strings are already in the build settings. If a request
fails with an ATS error, add `App Transport Security Settings` →
`Allow Local Networking` = YES under Target → Info.

## How the two halves meet

    POST /model3d   {"prompt": "a wooden chair", "format": "usda"}
                    -> {url, storage, format, filename, parts, vertices, faces}
    GET  /models    -> [{name, format, size, created, url, prompt, public_url}]
    GET  /health    -> {"status": "ok"}

    POST /model3d/refine   multipart:
                     model   filename from GET /models
                     image   JPEG of the AR view
                     note    optional, e.g. "it looks too small"
                     format  glb
                    -> {url, filename, parent, parts, vertices, faces,
                        assessment, changes[], scale,
                        apparent_size_m, target_size_m, skipped_edits[]}

`Models.swift` is the only coupling. Change it and the backend's schema
together, or neither.

### Format

RealityKit loads USD — `.usda`, `.usdc`, `.usdz` — and nothing else. Not glTF,
not OBJ, not STL.

The deployed backend offers `glb/obj/stl`, so the app asks for GLB and
converts it to USD ASCII **on the device** (`GLBConverter.swift`). That keeps
it working against the deployed backend with nothing else running. Geometry,
node transforms and flat per-material colour survive; textures, PBR maps,
animation and skinning do not.

`mesh.py` in this repo adds a `usda` exporter that builds USD from the same
part list every other format comes from, losing nothing. Once that ships,
change `GenerateRequest.format` to `"usda"` — the download path already
passes USD straight through, so nothing else needs to move.

The app sniffs the format from the file's leading bytes rather than trusting
the URL, because signed cloud links end in a query string and object keys
often carry no extension. A non-USD file produces an error naming what
arrived instead of failing silently.

Models already built in another format show a warning in the library list
rather than failing when tapped.

### Cloud storage

When `cloud.enabled()`, `/model3d` uploads and returns a public URL, and the
app fetches from there — an absolute URL ignores the configured base address,
so nothing in the app changes. Signed links expire; `public_url` being
present is not a promise that it still resolves.

## Verified end to end

- `POST /model3d {"prompt": "a wooden chair", "format": "usda"}` → 42s,
  19 parts, 156 vertices, 236 faces
- The returned URL serves a file beginning `#usda`, 19 meshes, and renders
  through Apple's own USD stack
- `GET /models` lists it, correctly typed as `usda`


## 8. Improving a model from the room

The viewer has a camera button that snapshots the AR view — the model
composited into the real scene — and posts it to `/refine`.

That frame carries something a server-side render cannot have: the model at
true scale beside real objects, seen from a human standing height. "The legs
are too thin" is a judgement you can only make looking at a chair next to an
actual chair.

The response is the same shape as `/model3d`, so a refined model simply
replaces the current one. Until the endpoint exists the button returns a
plain "no /refine endpoint yet" rather than a bare 404.

Only models that came from the backend can be refined — a pasted URL has no
filename the backend would recognise, so the button is disabled for those.
The SwiftUI overlay is a sibling view of the AR view, so the controls stay
out of the captured frame.


## 9. Verified against the deployed backend

    POST /model3d {"prompt": "a wooden chair", "format": "glb"}
      -> 34s, 17 parts, 136 vertices, uploaded to GCS
    the GLB converts on device to 17 USD meshes, identical coordinates to the
      reference converter, and renders through Apple's USD stack

    POST /model3d/refine (multipart)
      -> 6.6s, returns a new model plus its assessment and parent

The refine endpoint is properly cautious: handed an image that did not match
the model, it said so and changed nothing rather than inventing a correction.
