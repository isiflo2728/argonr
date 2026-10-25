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

`Models.swift` is the only coupling. Change it and the backend's schema
together, or neither.

### Why the app asks for `usda`

RealityKit loads USD — `.usda`, `.usdc`, `.usdz` — and nothing else. Not glTF,
not OBJ, not STL.

The backend already models everything as parts with vertices, faces and a
colour, which is the shape USD wants, so `mesh.py` exports it directly and
nothing is lost. The alternative is shipping GLB and converting on the way,
which costs a round trip and drops colour to whatever the converter recovers.

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
