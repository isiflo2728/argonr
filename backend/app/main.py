import asyncio
import json
import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from google import genai
from google.genai import errors, types
from pydantic import BaseModel, Field, ValidationError

from app import cloud, refine, storage
from app.mesh import MEDIA_TYPES, SYSTEM_INSTRUCTION, InvalidMeshError, MeshFormat, Scene, export, validate

GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-4-argon")
MAX_IMAGE_BYTES = 10 * 1024 * 1024

app = FastAPI(title="argonr backend")
app.mount("/outputs/models", StaticFiles(directory=storage.MODELS_DIR), name="models")

VIEWER_PAGE = Path(__file__).parent / "static" / "viewer.html"

# Created lazily so the server still starts (health, viewer, model listing) without a key.
_client: genai.Client | None = None


def gemini() -> genai.Client:
    global _client
    if _client is None:
        if not os.getenv("GEMINI_API_KEY"):
            raise HTTPException(status_code=503, detail="GEMINI_API_KEY is not set; add it to .env")
        _client = genai.Client()
    return _client


class CompletionRequest(BaseModel):
    prompt: str = Field(..., min_length=1)


class CompletionResponse(BaseModel):
    model: str
    text: str
    saved_to: str


class Model3DRequest(BaseModel):
    prompt: str = Field(..., min_length=1, description="Description of the object to model")
    format: MeshFormat = MeshFormat.GLB


class Model3DResponse(BaseModel):
    url: str = Field(description="Download URL: a GCS URL when uploads are configured, else this server")
    storage: str = Field(description="'gcs' or 'local'")
    format: MeshFormat
    filename: str
    saved_to: str
    parts: int
    vertices: int
    faces: int


class RefineResponse(Model3DResponse):
    parent: str = Field(description="Filename of the model that was refined")
    assessment: str = Field(description="What Argon saw wrong with the model in the photo")
    changes: list[str] = Field(description="What was changed")
    scale: float = Field(description="Overall scale applied: target_size_m / apparent_size_m")
    apparent_size_m: float = Field(description="How big Argon judged the model looked in the photo (largest side)")
    target_size_m: float = Field(description="How big Argon judged it should look in that scene (largest side)")
    size_m: list[float] = Field(description="New size [width, height, depth] in meters")
    skipped_edits: list[str] = Field(description="Edits naming parts that don't exist, ignored")


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


async def publish(scene: Scene, fmt: MeshFormat, prompt: str, http_request: Request, extra: dict[str, str]) -> dict:
    """Validate, export, save and upload a scene. Returns the Model3DResponse fields."""
    try:
        stats = validate(scene)
    except InvalidMeshError as e:
        raise HTTPException(status_code=502, detail=f"Model returned an invalid mesh: {e}")

    path = await storage.save("models", prompt, fmt, export(scene, fmt))
    scene_path = await storage.save_scene(path, scene.model_dump_json())
    metadata = {"prompt": prompt[:1000], **extra}

    if cloud.enabled():
        try:
            url = await cloud.upload(path, f"models/{path.name}", MEDIA_TYPES[fmt], metadata)
            await cloud.upload(scene_path, f"scenes/{path.name}.json", "application/json", {})
        except Exception as e:
            raise HTTPException(
                status_code=502,
                detail=f"Upload to Cloud Storage failed ({e}); the model was saved locally to {path}",
            )
    else:
        url = str(http_request.url_for("models", path=path.name))

    storage_kind = "gcs" if cloud.enabled() else "local"
    await storage.save_metadata(path, {**metadata, "url": url, "storage": storage_kind})
    return {
        "url": url,
        "storage": storage_kind,
        "format": fmt,
        "filename": path.name,
        "saved_to": str(path),
        "parts": len(scene.parts),
        **stats,
    }


@app.post("/model3d", response_model=Model3DResponse)
async def model3d(request: Model3DRequest, http_request: Request) -> Model3DResponse:
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
    return Model3DResponse(**await publish(scene, request.format, request.prompt, http_request, {}))


async def load_scene(name: str) -> tuple[Scene, dict]:
    """The Scene a saved model was built from, plus its metadata.

    Prefers the stored Scene JSON; falls back to reading the GLB itself for
    models generated before scenes were stored. Checks local disk, then the bucket.
    """
    name = Path(name).name
    scene_json, model_bytes = await asyncio.to_thread(storage.read_local, name)
    metadata = await asyncio.to_thread(storage.read_metadata, name)
    if cloud.enabled():
        if scene_json is None:
            data = await cloud.download(f"scenes/{name}.json")
            scene_json = data.decode() if data else None
        if scene_json is None and model_bytes is None:
            model_bytes = await cloud.download(f"models/{name}")
        if not metadata:
            metadata = await cloud.metadata(f"models/{name}")

    if scene_json is not None:
        return Scene.model_validate_json(scene_json), metadata
    if model_bytes is None:
        raise HTTPException(status_code=404, detail=f"No model named {name!r}; see GET /models")
    if not name.endswith(".glb"):
        raise HTTPException(
            status_code=422,
            detail="Only GLB models, or models generated after refinement support was added, can be refined",
        )
    try:
        return refine.scene_from_glb(model_bytes), metadata
    except (ValueError, KeyError, ValidationError) as e:
        raise HTTPException(status_code=422, detail=f"Could not read {name}: {e}")


@app.post("/model3d/refine", response_model=RefineResponse)
async def refine_model(
    http_request: Request,
    model: str = Form(..., description="Filename of the model to improve, as listed by GET /models"),
    image: UploadFile = File(..., description="Photo or screenshot of the model placed in the AR scene"),
    note: str = Form("", description="Optional: what looks wrong, e.g. 'it looks too small'"),
    format: MeshFormat = Form(MeshFormat.GLB),
) -> RefineResponse:
    """Improve a model so it fits the real scene in the photo: size, proportions, parts and colors."""
    if not (image.content_type or "").startswith("image/"):
        raise HTTPException(status_code=415, detail=f"Expected an image, got {image.content_type!r}")
    photo = await image.read(MAX_IMAGE_BYTES + 1)
    if len(photo) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail="Image is larger than 10 MB")

    scene, metadata = await load_scene(model)

    try:
        response = await gemini().aio.models.generate_content(
            model=GEMINI_MODEL,
            contents=[
                types.Part.from_bytes(data=photo, mime_type=image.content_type),
                refine.prompt(scene, note),
            ],
            config=types.GenerateContentConfig(
                system_instruction=refine.INSTRUCTION,
                response_mime_type="application/json",
                response_schema=refine.RefinePlan,
            ),
        )
    except errors.APIError as e:
        raise HTTPException(status_code=502, detail=f"Gemini API error: {e.message}")

    plan = response.parsed
    if not isinstance(plan, refine.RefinePlan):
        raise HTTPException(status_code=502, detail="Model did not return a valid refinement plan")
    try:
        refined, scale, skipped = refine.apply(scene, plan)
    except ValueError as e:
        raise HTTPException(status_code=502, detail=str(e))

    original_prompt = (metadata.get("prompt") or scene.name).removesuffix(" (refined)")
    result = await publish(
        refined, format, f"{original_prompt} (refined)", http_request, {"parent": Path(model).name}
    )
    return RefineResponse(
        **result,
        parent=Path(model).name,
        assessment=plan.assessment,
        changes=plan.changes,
        scale=round(scale, 4),
        apparent_size_m=plan.apparent_size_m,
        target_size_m=plan.target_size_m,
        size_m=[round(s, 4) for s in refine.size(refined)],
        skipped_edits=skipped,
    )
