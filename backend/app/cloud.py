"""Upload generated files to Google Cloud Storage and return a shareable URL.

Configured via environment variables (see .env):
  GCS_BUCKET                      bucket to upload to; uploads are disabled when empty
  GOOGLE_APPLICATION_CREDENTIALS  path to a service-account JSON key
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


def _upload(path: Path, object_name: str, content_type: str) -> str:
    blob = _bucket().blob(object_name)
    blob.cache_control = "public, max-age=31536000, immutable"  # file names are unique
    blob.upload_from_filename(path, content_type=content_type)

    if os.getenv("GCS_PUBLIC_URLS", "").lower() == "true":
        return blob.public_url
    seconds = min(int(os.getenv("GCS_SIGNED_URL_SECONDS", MAX_SIGNED_URL_SECONDS)), MAX_SIGNED_URL_SECONDS)
    return blob.generate_signed_url(version="v4", expiration=timedelta(seconds=seconds), method="GET")


async def upload(path: Path, object_name: str, content_type: str) -> str:
    """Upload a local file to the configured bucket and return a URL to download it."""
    return await asyncio.to_thread(_upload, path, object_name, content_type)
