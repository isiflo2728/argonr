import asyncio
import json
import os
import time
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from google import genai
from google.genai import errors, types
from pydantic import BaseModel, Field

from app import cloud, storage
from app import loop as loop_mod, playtest as playtest_mod, procedural, render as render_mod, world as world_mod
from app.mesh import MEDIA_TYPES, SYSTEM_INSTRUCTION, InvalidMeshError, MeshFormat, Scene, export, validate

GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-4-argon")

app = FastAPI(title="Hello World API")
# Created lazily so the server still starts (health, viewer, model listing) without a key.
_client: genai.Client | None = None


def gemini() -> genai.Client:
    global _client
    if _client is None:
        if not os.getenv("GEMINI_API_KEY"):
            raise HTTPException(status_code=503, detail="GEMINI_API_KEY is not set; add it to .env")
        _client = genai.Client()
    return _client
app.mount("/outputs/models", StaticFiles(directory=storage.MODELS_DIR), name="models")

VIEWER_PAGE = Path(__file__).parent / "static" / "viewer.html"


class CompletionRequest(BaseModel):
    prompt: str = Field(..., min_length=1)


class CompletionResponse(BaseModel):
    model: str
    text: str
    saved_to: str


class Model3DRequest(BaseModel):
    prompt: str = Field(..., min_length=1, description="Description of the object to model")
    format: MeshFormat = MeshFormat.GLB
    procedural: bool = Field(
        True,
        description="Have the model write a program that computes the geometry "
                    "rather than listing vertices. Far better curvature; set "
                    "false to use the direct path.",
    )


class Model3DResponse(BaseModel):
    method: str = Field(description="'procedural' or 'direct'")
    url: str = Field(description="Download URL: a GCS URL when uploads are configured, else this server")
    storage: str = Field(description="'gcs' or 'local'")
    format: MeshFormat
    filename: str
    saved_to: str
    parts: int
    vertices: int
    faces: int


class WorldRequest(BaseModel):
    prompt: str = Field(..., min_length=1, description="The game to build")


class WorldResponse(BaseModel):
    world: dict = Field(description="The whole playable world")
    entities: int
    vertices: int
    faces: int
    meshes: int
    program_chars: int = Field(description="Size of the program Argon wrote")
    seconds: float


class WorldReviseRequest(BaseModel):
    world: dict = Field(..., description="The world as it stands")
    instruction: str = Field(..., min_length=1, description="What to change")


@app.post("/world", response_model=WorldResponse)
async def build_world(request: WorldRequest) -> WorldResponse:
    """A whole playable world in one decode.

    Generating object by object makes every call a cold start, so nothing
    shares a scale or a palette and nothing knows where anything else is. One
    program returns every asset, the layout and the behaviour together.
    """
    return await _world(world_mod.SYSTEM_INSTRUCTION, request.prompt)


@app.post("/world/revise", response_model=WorldResponse)
async def revise_world(request: WorldReviseRequest) -> WorldResponse:
    prompt = (f"Current world:\n\n{json.dumps(request.world)}\n\n"
              f"Request: {request.instruction}")
    return await _world(world_mod.REVISE_INSTRUCTION, prompt)


async def _world(instruction: str, prompt: str) -> WorldResponse:
    started = time.monotonic()
    try:
        response = await gemini().aio.models.generate_content(
            model=GEMINI_MODEL,
            contents=prompt,
            config=types.GenerateContentConfig(
                system_instruction=instruction,
                # The whole world arrives in this one response.
                max_output_tokens=262144,
            ),
        )
    except errors.APIError as e:
        raise HTTPException(status_code=502, detail=f"Gemini API error: {e.message}")

    code = response.text or ""
    try:
        built, stats = world_mod.world_from_program(code)
    except (procedural.ProgramError, ValueError) as e:
        raise HTTPException(status_code=502, detail=f"World program failed: {e}")

    took = round(time.monotonic() - started, 1)
    print(f"[world] {built.name!r}: {stats['entities']} entities, "
          f"{stats['vertices']} verts, {len(code)} chars of program, {took}s")
    await storage.save("worlds", built.name, "json", built.model_dump_json(indent=1))

    return WorldResponse(world=built.model_dump(), program_chars=len(code),
                         seconds=took, **stats)


class PlaytestRequest(BaseModel):
    world: dict


class IterateRequest(BaseModel):
    world: dict
    goal: str = Field("", description="What the game was meant to be")
    passes: int = Field(3, ge=1, le=6)
    runs: int = Field(5, ge=1, le=20)


@app.post("/world/playtest")
async def playtest_world(request: PlaytestRequest) -> dict:
    """Play it through and report what is measurably wrong."""
    return await asyncio.to_thread(playtest_mod.playtest, request.world, 5)


@app.post("/world/iterate/stream")
async def iterate_world_stream(request: IterateRequest):
    """The same loop, streamed as newline-delimited JSON.

    A pass takes a couple of minutes. Watching the score climb is the whole
    point, so the UI gets each pass the moment it lands rather than a result
    at the end.
    """
    from fastapi.responses import StreamingResponse

    run_dir = storage.OUTPUT_DIR / "worldruns" / str(int(time.time()))

    async def events():
        current = request.world
        goal = request.goal or current.get("pitch", "")
        history: list[dict] = []

        for index in range(request.passes):
            yield json.dumps({"event": "pass_start", "pass": index}) + "\n"

            telemetry = await asyncio.to_thread(
                playtest_mod.playtest, current, request.runs)
            yield json.dumps({"event": "playtested", "pass": index,
                              "telemetry": telemetry}) + "\n"

            frames = await asyncio.to_thread(
                render_mod.render, current, run_dir / f"pass{index}", 6)
            yield json.dumps({"event": "rendered", "pass": index,
                              "frames": len(frames)}) + "\n"

            try:
                verdict = await loop_mod.critique(
                    gemini(), GEMINI_MODEL, goal, current, telemetry, frames)
            except errors.APIError as e:
                yield json.dumps({"event": "error", "detail": e.message}) + "\n"
                return

            entry = {"pass": index, "score": verdict.get("score"),
                     "verdict": verdict.get("verdict"),
                     "bugs": verdict.get("bugs", []),
                     "playable": telemetry["playable"],
                     "avg_seconds": telemetry["avg_seconds"],
                     "winners": telemetry["winners"]}
            yield json.dumps({"event": "critiqued", **entry}) + "\n"

            bugs = verdict.get("bugs", [])
            if index == request.passes - 1 or not bugs:
                history.append(entry)
                break

            try:
                current, stats, chars = await loop_mod.fix(
                    gemini(), GEMINI_MODEL, current, verdict, telemetry, history)
                entry["fixed"] = True
                yield json.dumps({"event": "fixed", "pass": index,
                                  "program_chars": chars, "stats": stats,
                                  "world": current}) + "\n"
            except Exception as e:
                entry["fix_error"] = str(e)[:300]
                yield json.dumps({"event": "fix_failed", "pass": index,
                                  "detail": str(e)[:300]}) + "\n"
                history.append(entry)
                break
            history.append(entry)

        after = await asyncio.to_thread(playtest_mod.playtest, current, request.runs)
        yield json.dumps({"event": "done", "world": current,
                          "history": history, "after": after}) + "\n"

    return StreamingResponse(events(), media_type="application/x-ndjson")


@app.post("/world/iterate")
async def iterate_world(request: IterateRequest) -> dict:
    """Argon plays its own game, works out what is broken, and rewrites it.

    The measurements are ground truth it cannot argue with: a match that ends
    in four seconds ended in four seconds. That is what makes the loop
    converge rather than drift on taste.
    """
    run_dir = storage.OUTPUT_DIR / "worldruns" / str(int(time.time()))

    def render(world: dict, index: int):
        return render_mod.render(world, run_dir / f"pass{index}", frames=6)

    started = time.monotonic()
    try:
        final, history = await loop_mod.iterate(
            gemini(), GEMINI_MODEL, request.goal or request.world.get("pitch", ""),
            request.world, render, passes=request.passes, runs=request.runs)
    except errors.APIError as e:
        raise HTTPException(status_code=502, detail=f"Gemini API error: {e.message}")

    after = playtest_mod.playtest(final, runs=request.runs)
    await storage.save("worlds", final.get("name", "world") + "-iterated", "json",
                       json.dumps(final, indent=1))

    return {"world": final, "history": history, "after": after,
            "seconds": round(time.monotonic() - started, 1)}


@app.get("/")
async def root() -> dict[str, str]:
    return {"message": "Hello, World!"}


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/viewer", include_in_schema=False)
async def viewer() -> FileResponse:
    return FileResponse(VIEWER_PAGE)


@app.get("/models")
async def list_models() -> list[dict[str, str | int | None]]:
    # The bucket is the source of truth when uploads are on: local disk is
    # ephemeral on Cloud Run, so outputs/ only lasts as long as the instance.
    if cloud.enabled():
        return await cloud.list_models()
    return await asyncio.to_thread(storage.list_models)


@app.post("/completion", response_model=CompletionResponse)
async def completion(request: CompletionRequest) -> CompletionResponse:
    try:
        response = await gemini().aio.models.generate_content(
            model=GEMINI_MODEL,
            contents=request.prompt,
        )
    except errors.APIError as e:
        raise HTTPException(status_code=502, detail=f"Gemini API error: {e.message}")
    text = response.text or ""
    record = {"model": GEMINI_MODEL, "prompt": request.prompt, "text": text}
    path = await storage.save("completions", request.prompt, "json", json.dumps(record, indent=2))
    return CompletionResponse(model=GEMINI_MODEL, text=text, saved_to=str(path))


@app.post("/model3d", response_model=Model3DResponse)
async def model3d(request: Model3DRequest, http_request: Request) -> Model3DResponse:
    method = "direct"

    # Writing a program beats listing coordinates by a wide margin: measured
    # on the same teapot prompt, 3124 vertices against 230, 1107 distinct
    # face normals against 176, and faster. The direct path stays as the
    # fallback, since a generated program can always fail to run.
    if request.procedural:
        try:
            response = await gemini().aio.models.generate_content(
                model=GEMINI_MODEL,
                contents=request.prompt,
                config=types.GenerateContentConfig(
                    system_instruction=procedural.PROGRAM_INSTRUCTION,
                ),
            )
            scene, stats = procedural.scene_from_program(response.text or "")
            method = "procedural"
        except errors.APIError as e:
            raise HTTPException(status_code=502, detail=f"Gemini API error: {e.message}")
        except (procedural.ProgramError, InvalidMeshError, ValueError) as e:
            print(f"[model3d] procedural failed ({e}); falling back to direct")
            request = request.model_copy(update={"procedural": False})

    if method == "direct":
        try:
            response = await gemini().aio.models.generate_content(
                model=GEMINI_MODEL,
                contents=request.prompt,
                config=types.GenerateContentConfig(
                    system_instruction=SYSTEM_INSTRUCTION,
                    response_mime_type="application/json",
                    response_schema=Scene,
                ),
            )
        except errors.APIError as e:
            raise HTTPException(status_code=502, detail=f"Gemini API error: {e.message}")

        scene = response.parsed
        if not isinstance(scene, Scene):
            raise HTTPException(status_code=502, detail="Model did not return a valid 3D scene")
        try:
            stats = validate(scene)
        except InvalidMeshError as e:
            raise HTTPException(status_code=502, detail=f"Model returned an invalid mesh: {e}")

    mesh = export(scene, request.format)
    path = await storage.save("models", request.prompt, request.format, mesh)

    if cloud.enabled():
        try:
            url = await cloud.upload(
                path, f"models/{path.name}", MEDIA_TYPES[request.format], {"prompt": request.prompt[:1000]}
            )
        except Exception as e:
            raise HTTPException(
                status_code=502,
                detail=f"Upload to Cloud Storage failed ({e}); the model was saved locally to {path}",
            )
    else:
        url = str(http_request.url_for("models", path=path.name))

    storage_kind = "gcs" if cloud.enabled() else "local"
    await storage.save_metadata(path, {"prompt": request.prompt, "url": url, "storage": storage_kind})

    return Model3DResponse(
        method=method,
        url=url,
        storage=storage_kind,
        format=request.format,
        filename=path.name,
        saved_to=str(path),
        parts=len(scene.parts),
        **stats,
    )
