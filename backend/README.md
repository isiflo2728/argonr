# backend

Text-to-3D API on Gemini 4 Argon. Describe an object, get a colored 3D model
back, uploaded to Google Cloud Storage with a public URL.

This sits alongside `server/` (the photo → render → critique → fix loop the
iOS app talks to) rather than replacing it. It does **not** implement the
app's `/generate` / `/status` / `/iterate` contract yet, and it exports glTF,
OBJ and STL — not USD, which the app's viewer requires. See
[Relation to server/](#relation-to-server).

## Run

    cd backend
    python3 -m venv .venv
    .venv/bin/pip install -r requirements.txt
    cp .env.example .env              # add GEMINI_API_KEY
    .venv/bin/uvicorn app.main:app --reload

Serves on http://localhost:8000. Interactive API docs at `/docs`, and a
browser viewer for every generated model at `/viewer`.

`requirements.txt` pins `cryptography<49`: newer releases have no prebuilt
wheel for Intel macOS on Python 3.14, and building from source needs OpenSSL.

## Endpoints

| Method | Path | What it does |
|---|---|---|
| `POST` | `/model3d` | `{"prompt": "...", "format": "glb" \| "obj" \| "stl"}` → generates a model, saves it, uploads it, returns its URL |
| `GET` | `/models` | Every generated model, newest first, with prompt and public URL |
| `GET` | `/viewer` | three.js viewer: browse, rotate and generate models |
| `POST` | `/completion` | `{"prompt": "..."}` → plain Argon text completion |
| `GET` | `/health` | Liveness check |

`/model3d` response:

```json
{
  "url": "https://storage.googleapis.com/<bucket>/models/20261025-122234-a-red-toy-car-7af038.glb",
  "storage": "gcs",
  "format": "glb",
  "filename": "20261025-122234-a-red-toy-car-7af038.glb",
  "saved_to": "outputs/models/20261025-122234-a-red-toy-car-7af038.glb",
  "parts": 9, "vertices": 188, "faces": 268
}
```

Generation takes roughly 40–90 seconds.

## How models are built

Argon never writes a file format directly. It returns a `Scene` — named parts,
each with an sRGB color, vertices and polygon faces — enforced with Gemini
structured output (`response_schema`). The server validates it (face indices in
range, colors in 0–1, no degenerate faces) and exports it:

- **GLB** — one mesh and PBR material per part. Passes the Khronos glTF validator.
- **OBJ** — per-vertex colors (`v x y z r g b`), one object per part.
- **STL** — ASCII, converted to Z-up. No color; STL can't store it.

Because every format comes from the same `Scene`, adding another exporter
(USD, for instance) doesn't touch the prompt or validation. See `app/mesh.py`.

## Cloud Storage

Set in `.env`:

    GCS_BUCKET=your-bucket
    GOOGLE_APPLICATION_CREDENTIALS=/absolute/path/to/service-account-key.json
    GCS_PUBLIC_URLS=true

- `GCS_PUBLIC_URLS=true` returns permanent `https://storage.googleapis.com/...`
  URLs; the bucket needs `allUsers` → Storage Object Viewer.
- Otherwise it returns V4 signed URLs valid for 7 days (`GCS_SIGNED_URL_SECONDS`).
- With `GCS_BUCKET` empty, uploads are skipped and URLs point at this server.
- If an upload fails the request returns 502, but the model is kept in `outputs/`.

The service account only needs **Storage Object Creator** on the bucket. Keep
the key outside the repo — this repo is public.

## Deploy (Cloud Run)

Runs as the `argon-uploader` service account, so no key file is needed. With
uploads on, `/models` lists the bucket rather than local disk, which Cloud Run
wipes on every restart.

    ./deploy.sh                          # build, deploy, smoke test
    SKIP_BUILD=1 ./deploy.sh             # redeploy the last image, e.g. after changing settings
    ENV_FILE=~/other/.env ./deploy.sh    # read the Gemini key from another file

**The Gemini key** is read at deploy time from `$GEMINI_API_KEY`, or else from
`GEMINI_API_KEY=` in `.env` (gitignored), and set as a Cloud Run environment
variable. Never write the key into `deploy.sh` — this repo is public. Anyone
with Viewer access to the Cloud Run service in the console can see it.

Other settings (`PROJECT`, `BUCKET`, `MIN_INSTANCES`, `MAX_INSTANCES`, ...) can
be overridden from the environment.

One-time setup: the service account needs **Storage Object Creator** and
**Storage Object Viewer** on the bucket.

`--min-instances=1` keeps one instance warm so requests never hit a cold
start. That instance is billed while idle, so run
`MIN_INSTANCES=0 SKIP_BUILD=1 ./deploy.sh` once the hackathon is over.

The service is public so the phone can reach it, which also means anyone with
the URL can spend Gemini quota. `--max-instances` caps the damage.

## Layout

    app/main.py           routes
    app/mesh.py           Scene schema, validation, GLB/OBJ/STL exporters
    app/cloud.py          GCS upload and URL signing
    app/storage.py        local outputs/ folder and per-model metadata
    app/static/viewer.html

Generated files go to `outputs/` (gitignored): `models/` holds each model plus
a `<name>.json` sidecar with its prompt and public URL; `completions/` holds
one JSON per completion.

## Relation to server/

The iOS app can reach one server at a time, and it speaks the contract in
`SETUP.md` §4. What's reusable from here for that loop:

- **GCS upload with public URLs** — `SETUP.md` §6 already expects
  `model_path` to be able to point at cloud storage.
- **Structured scene output** — a `Scene` → `.usda` exporter would let this
  backend's models load in the app's viewer.

Whether the loop moves here or these pieces move into `server/` is still to be
decided.
