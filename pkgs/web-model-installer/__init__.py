"""Web Model Installer for ComfyUI.

Server-side handler for the "Missing Models" panel Download button. The
frontend bundle is patched at build time (separately) to call
`window.__wmi.start(model)`; our companion JS extension POSTs to the endpoints
registered here, and the actual file transfer happens on the server into the
correct `folder_paths` location.

This module is server-extension only — it ships no ComfyUI nodes.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
import uuid
from pathlib import Path
from typing import Any

import aiohttp
from aiohttp import web

import folder_paths  # type: ignore
from server import PromptServer  # type: ignore

log = logging.getLogger("web-model-installer")

NODE_CLASS_MAPPINGS: dict[str, Any] = {}
NODE_DISPLAY_NAME_MAPPINGS: dict[str, Any] = {}
WEB_DIRECTORY = "./web"

# Sanity ceiling — no single model should exceed this. Largest legitimate
# checkpoints today sit in the tens of GiB.
_MAX_CONTENT_LENGTH = 100 * 1024 * 1024 * 1024  # 100 GiB

# Mirrors the frontend's ALLOWED_SUFFIXES plus .json for VAE/config sidecars.
_ALLOWED_SUFFIXES: frozenset[str] = frozenset({
    ".safetensors",
    ".sft",
    ".ckpt",
    ".pth",
    ".pt",
    ".bin",
    ".gguf",
    ".onnx",
    ".pkl",
    ".pickle",
    ".json",
})

# Control chars (incl. NUL) we strip from incoming filenames before validation.
_CONTROL_CHARS = "".join(chr(c) for c in range(32)) + "\x7f"

_PROGRESS_INTERVAL_S = 0.5
_CHUNK_SIZE = 1024 * 256
_SOCK_READ_TIMEOUT_S = 300

_DOWNLOADS: dict[str, dict[str, Any]] = {}


# ---------------------------------------------------------------------------
# Validation / path resolution
# ---------------------------------------------------------------------------

def _resolve_save_dir(directory: str) -> Path:
    """Map a ComfyUI folder name (e.g. 'checkpoints') to a real filesystem path."""
    try:
        paths = folder_paths.get_folder_paths(directory)
    except Exception:
        paths = None
    if paths:
        return Path(paths[0])
    base = Path(folder_paths.models_dir) if hasattr(folder_paths, "models_dir") else Path("models")
    return base / directory


def _known_directories() -> set[str]:
    try:
        return set(folder_paths.get_folder_names())
    except Exception:
        return set()


def _sanitize_filename(name: str) -> str:
    name = os.path.basename(name)
    name = name.translate({ord(c): None for c in _CONTROL_CHARS}).strip()
    if not name or name in (".", ".."):
        raise ValueError("invalid filename")
    if "/" in name or "\\" in name:
        raise ValueError("filename must not contain path separators")
    suffix = Path(name).suffix.lower()
    if suffix not in _ALLOWED_SUFFIXES:
        raise ValueError(f"filename extension {suffix!r} is not allowed")
    return name


def _validate_directory(directory: str) -> str:
    if not directory:
        raise ValueError("directory required")
    if "/" in directory or "\\" in directory or directory.startswith("."):
        raise ValueError("invalid directory")
    known = _known_directories()
    if known and directory not in known:
        raise ValueError(f"directory {directory!r} is not a registered folder_paths name")
    return directory


def _validate_url(url: str) -> str:
    if not (url.startswith("http://") or url.startswith("https://")):
        raise ValueError("unsupported url scheme (only http/https)")
    return url


# ---------------------------------------------------------------------------
# Event emission
# ---------------------------------------------------------------------------

def _emit(event: str, payload: dict[str, Any]) -> None:
    try:
        PromptServer.instance.send_sync(event, payload)
    except Exception:
        log.exception("[WMI] failed to emit %s", event)


# ---------------------------------------------------------------------------
# Download worker
# ---------------------------------------------------------------------------

async def _download_task(
    job_id: str,
    url: str,
    save_dir: Path,
    filename: str,
    directory: str,
) -> None:
    job = _DOWNLOADS[job_id]
    tmp_path = save_dir / (filename + ".partial")
    final_path = save_dir / filename
    save_dir.mkdir(parents=True, exist_ok=True)

    _emit("wmi.progress", {
        "job_id": job_id,
        "status": "running",
        "filename": filename,
        "directory": directory,
        "url": url,
        "downloaded": 0,
        "total": 0,
    })

    try:
        timeout = aiohttp.ClientTimeout(total=None, sock_read=_SOCK_READ_TIMEOUT_S)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(url, allow_redirects=True) as resp:
                if resp.status >= 400:
                    raise RuntimeError(f"HTTP {resp.status}")
                total = int(resp.headers.get("content-length") or 0)
                if total > _MAX_CONTENT_LENGTH:
                    raise RuntimeError(
                        f"content-length {total} exceeds cap {_MAX_CONTENT_LENGTH}"
                    )
                job["total"] = total
                downloaded = 0
                last_emit = 0.0
                with open(tmp_path, "wb") as f:
                    async for chunk in resp.content.iter_chunked(_CHUNK_SIZE):
                        f.write(chunk)
                        downloaded += len(chunk)
                        if downloaded > _MAX_CONTENT_LENGTH:
                            raise RuntimeError(
                                f"download exceeded cap {_MAX_CONTENT_LENGTH}"
                            )
                        job["downloaded"] = downloaded
                        now = time.monotonic()
                        if now - last_emit >= _PROGRESS_INTERVAL_S:
                            _emit("wmi.progress", {
                                "job_id": job_id,
                                "status": "running",
                                "filename": filename,
                                "directory": directory,
                                "downloaded": downloaded,
                                "total": total,
                            })
                            last_emit = now
        # Atomic publish: rename only after the body is fully written.
        os.replace(tmp_path, final_path)
        job["status"] = "done"
        job["finished_at"] = time.time()
        log.info("[WMI] Finished: %s", final_path)
        _emit("wmi.done", {
            "job_id": job_id,
            "status": "done",
            "filename": filename,
            "directory": directory,
            "path": str(final_path),
            "downloaded": job.get("downloaded", 0),
            "total": job.get("total", 0),
        })
    except asyncio.CancelledError:
        # Cancellation comes from POST /api/wmi/cancel calling task.cancel().
        # We tidy up the partial file and re-raise so the task ends in CANCELLED
        # state (rather than appearing to have completed normally).
        job["status"] = "cancelled"
        job["finished_at"] = time.time()
        _unlink_quiet(tmp_path)
        log.info("[WMI] Cancelled: %s", filename)
        _emit("wmi.cancelled", {
            "job_id": job_id,
            "status": "cancelled",
            "filename": filename,
            "directory": directory,
        })
        raise
    except (aiohttp.ClientError, OSError, RuntimeError, asyncio.TimeoutError) as e:
        job["status"] = "error"
        job["error"] = str(e)
        job["finished_at"] = time.time()
        log.exception("[WMI] Download failed for %s: %s", filename, e)
        _unlink_quiet(tmp_path)
        _emit("wmi.error", {
            "job_id": job_id,
            "status": "error",
            "filename": filename,
            "directory": directory,
            "error": str(e),
        })
    finally:
        job.pop("task", None)


def _unlink_quiet(path: Path) -> None:
    try:
        path.unlink(missing_ok=True)
    except OSError:
        log.exception("[WMI] failed to unlink %s", path)


# ---------------------------------------------------------------------------
# HTTP routes
# ---------------------------------------------------------------------------

@PromptServer.instance.routes.post("/api/wmi/download")
async def _route_download(request: web.Request) -> web.Response:
    try:
        data = await request.json()
    except ValueError:
        return web.json_response({"error": "invalid json"}, status=400)
    if not isinstance(data, dict):
        return web.json_response({"error": "json body must be an object"}, status=400)

    url = str(data.get("url") or "").strip()
    filename_in = str(data.get("filename") or "").strip()
    directory_in = str(data.get("directory") or "").strip()

    if not url or not filename_in or not directory_in:
        return web.json_response(
            {"error": "url, filename, directory required"}, status=400
        )

    try:
        url = _validate_url(url)
        filename = _sanitize_filename(filename_in)
        directory = _validate_directory(directory_in)
    except ValueError as e:
        return web.json_response({"error": str(e)}, status=400)

    save_dir = _resolve_save_dir(directory)
    final_path = save_dir / filename

    if final_path.exists():
        return web.json_response({
            "error": f"file already exists at {final_path}",
            "path": str(final_path),
        }, status=409)

    job_id = uuid.uuid4().hex
    job: dict[str, Any] = {
        "id": job_id,
        "url": url,
        "filename": filename,
        "directory": directory,
        "path": str(final_path),
        "status": "running",
        "downloaded": 0,
        "total": 0,
        "started_at": time.time(),
    }
    _DOWNLOADS[job_id] = job
    # The task owns the only reference to its own cancellation; the cancel
    # route reaches it via _DOWNLOADS[job_id]["task"]. We do NOT await this
    # task here — the HTTP handler returns immediately with the job_id.
    task = asyncio.create_task(
        _download_task(job_id, url, save_dir, filename, directory),
        name=f"wmi-download-{job_id}",
    )
    job["task"] = task

    log.info("[WMI] Queued download: %s -> %s", url, final_path)
    return web.json_response({
        "job_id": job_id,
        "filename": filename,
        "directory": directory,
        "path": str(final_path),
    })


@PromptServer.instance.routes.get("/api/wmi/status")
async def _route_status(request: web.Request) -> web.Response:
    jobs = [
        {k: v for k, v in j.items() if k != "task"}
        for j in _DOWNLOADS.values()
    ]
    return web.json_response({"jobs": jobs})


@PromptServer.instance.routes.post("/api/wmi/cancel")
async def _route_cancel(request: web.Request) -> web.Response:
    try:
        data = await request.json()
    except ValueError:
        return web.json_response({"error": "invalid json"}, status=400)
    if not isinstance(data, dict):
        return web.json_response({"error": "json body must be an object"}, status=400)

    job_id = str(data.get("job_id") or "").strip()
    if not job_id:
        return web.json_response({"error": "job_id required"}, status=400)
    job = _DOWNLOADS.get(job_id)
    if job is None:
        return web.json_response({"error": "unknown job"}, status=404)
    task: asyncio.Task[None] | None = job.get("task")
    if task is None or task.done():
        return web.json_response({"error": "job not active"}, status=409)
    task.cancel()
    return web.json_response({"job_id": job_id, "status": "cancelling"})


log.info("[WMI] web-model-installer loaded")

