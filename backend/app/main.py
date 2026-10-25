import asyncio
import json
import os
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
from app import procedural
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
