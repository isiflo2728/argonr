import asyncio
import json
import os
import re
import uuid
from datetime import datetime
from pathlib import Path

OUTPUT_DIR = Path(os.getenv("OUTPUT_DIR", "outputs"))
MODELS_DIR = OUTPUT_DIR / "models"
MODELS_DIR.mkdir(parents=True, exist_ok=True)


def _filename(prompt: str, extension: str) -> str:
    """Build a sortable, unique name like 20261025-104512-a-simple-table-1a2b3c.obj."""
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    slug = re.sub(r"[^a-z0-9]+", "-", prompt.lower()).strip("-")[:40].rstrip("-") or "output"
    return f"{timestamp}-{slug}-{uuid.uuid4().hex[:6]}.{extension}"


def _write(path: Path, content: str | bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(content, bytes):
        path.write_bytes(content)
    else:
        path.write_text(content)


def _metadata_path(model: Path) -> Path:
    # Sidecar next to the model, e.g. chair-1a2b3c.glb -> chair-1a2b3c.glb.json
    return model.with_name(model.name + ".json")


def _read_metadata(model: Path) -> dict:
    try:
        return json.loads(_metadata_path(model).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}  # models generated before metadata was recorded


async def save_metadata(model: Path, metadata: dict) -> None:
    """Record details about a saved model (prompt, uploaded URL) for the viewer."""
    await asyncio.to_thread(_write, _metadata_path(model), json.dumps(metadata, indent=2))


def list_models() -> list[dict[str, str | int | None]]:
    """List saved 3D models, newest first."""
    files = [p for p in MODELS_DIR.iterdir() if p.suffix in (".glb", ".obj", ".stl", ".usda")]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    models = []
    for p in files:
        metadata = _read_metadata(p)
        models.append({
            "name": p.name,
            "format": p.suffix.lstrip("."),
            "size": p.stat().st_size,
            "created": datetime.fromtimestamp(p.stat().st_mtime).isoformat(timespec="seconds"),
            "url": f"/outputs/models/{p.name}",
            "prompt": metadata.get("prompt"),
            # Uploaded copy; None if the model was never uploaded. Signed URLs expire.
            "public_url": metadata.get("url") if metadata.get("storage") == "gcs" else None,
        })
    return models


async def save(category: str, prompt: str, extension: str, content: str | bytes) -> Path:
    """Save a generated output under OUTPUT_DIR/<category>/ and return its path."""
    path = OUTPUT_DIR / category / _filename(prompt, extension)
    await asyncio.to_thread(_write, path, content)
    return path
