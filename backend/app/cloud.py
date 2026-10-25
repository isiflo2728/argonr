"""Upload generated files to Google Cloud Storage and return a shareable URL.

Configured via environment variables (see .env):
  GCS_BUCKET                      bucket to upload to; uploads are disabled when empty
  GOOGLE_APPLICATION_CREDENTIALS  path to a service-account JSON key (not needed on Cloud
                                  Run, which uses the service's own identity)
  GCS_PUBLIC_URLS                 "true" to return permanent public URLs (bucket must
                                  allow public reads); otherwise signed URLs are returned
  GCS_SIGNED_URL_SECONDS          signed URL lifetime, max 7 days (default)
"""

import asyncio
import os
from datetime import timedelta
from functools import lru_cache
from pathlib import Path

from google.cloud import storage as gcs

MAX_SIGNED_URL_SECONDS = 7 * 24 * 3600  # limit for V4 signed URLs


def enabled() -> bool:
    return bool(os.getenv("GCS_BUCKET"))


@lru_cache
def _bucket() -> gcs.Bucket:
    return gcs.Client().bucket(os.environ["GCS_BUCKET"])


def _url(blob: gcs.Blob) -> str:
    if os.getenv("GCS_PUBLIC_URLS", "").lower() == "true":
        return blob.public_url
    # Signing needs a private key: a key file locally, or on Cloud Run the
    # Service Account Token Creator role on the service's own account.
    seconds = min(int(os.getenv("GCS_SIGNED_URL_SECONDS", MAX_SIGNED_URL_SECONDS)), MAX_SIGNED_URL_SECONDS)
    return blob.generate_signed_url(version="v4", expiration=timedelta(seconds=seconds), method="GET")


def _upload(path: Path, object_name: str, content_type: str, metadata: dict[str, str]) -> str:
    blob = _bucket().blob(object_name)
    blob.cache_control = "public, max-age=31536000, immutable"  # file names are unique
    blob.metadata = metadata
    blob.upload_from_filename(path, content_type=content_type)
    return _url(blob)


async def upload(path: Path, object_name: str, content_type: str, metadata: dict[str, str]) -> str:
    """Upload a local file to the configured bucket and return a URL to download it."""
    return await asyncio.to_thread(_upload, path, object_name, content_type, metadata)


def _list_models(prefix: str) -> list[dict[str, str | int | None]]:
    models = []
    for blob in _bucket().list_blobs(prefix=prefix):
        name = blob.name.removeprefix(prefix)
        fmt = name.rsplit(".", 1)[-1]
        if fmt not in ("glb", "obj", "stl"):
            continue
        url = _url(blob)
        models.append({
            "name": name,
            "format": fmt,
            "size": blob.size,
            "created": blob.time_created.astimezone().isoformat(timespec="seconds"),
            "url": url,
            "prompt": (blob.metadata or {}).get("prompt"),
            "public_url": url,
        })
    models.sort(key=lambda m: m["created"], reverse=True)
    return models


async def list_models(prefix: str = "models/") -> list[dict[str, str | int | None]]:
    """List uploaded models, newest first, in the same shape as storage.list_models."""
    return await asyncio.to_thread(_list_models, prefix)
