"""Renderer for the daily draft queue (#212) backed by the headless macOS CLI.

`Tools/SpatterDraftRenderer` is compiled from the production Studio sources
(the deterministic `SpatterMultiClauseBrief` planner, `StudioCommandExecutor`,
`StudioMovieExportService` and `SpatterQualityReport`). This module runs it as
a subprocess with a bounded wall-clock timeout, keeps the job lease alive while
it runs, and accepts its JSON receipt only after re-measuring the files it names.

The result is a PRIVATE DRAFT. Nothing here uploads, publishes or contacts a
provider: the owner's review queue receives the render digest and a private
preview URL produced by an injected `publish_preview` callable, and the owner
must approve that exact render before any release. Without a configured CLI
`renderer_from_env` returns None and the queue keeps failing honestly with the
OWNER-GATED capacity message; without a private preview publisher the render
fails with an explicit message instead of inventing a URL.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Mapping, Optional

from .draft_queue import Plan, RenderResult

ENV_CLI = "SDI_DRAFT_RENDERER_CLI"
ENV_OUTPUT = "SDI_DRAFT_RENDER_DIR"
ENV_TIMEOUT = "SDI_DRAFT_RENDER_TIMEOUT_SECONDS"
ENV_WIDTH = "SDI_DRAFT_RENDER_WIDTH"
ENV_HEIGHT = "SDI_DRAFT_RENDER_HEIGHT"
ENV_FPS = "SDI_DRAFT_RENDER_FPS"

RECEIPT_SCHEMA = "sdi_spatter_draft_render_receipt"
RECEIPT_VERSION = 1
MAX_RECEIPT_BYTES = 4 * 1024 * 1024
# The job lease is 15 minutes and is renewed by every heartbeat; one render must
# finish well inside it even if a heartbeat is lost.
MAX_TIMEOUT_SECONDS = 840
DEFAULT_TIMEOUT_SECONDS = 600
HEARTBEAT_SECONDS = 60
PREVIEW_NOT_CONFIGURED = ("Private preview storage is not configured (OWNER-GATED). The draft renderer needs a private HTTPS "
                          "preview publisher before a render can reach the owner's review queue; nothing was uploaded or published.")
_SHA = re.compile(r"[a-f0-9]{64}")

PreviewPublisher = Callable[[Path, str, Plan], str]


class RendererError(RuntimeError):
    """Public-safe render failure; draft_queue records the message as the job error."""


def _sha256_file(path: Path) -> tuple[str, int]:
    digest, size = hashlib.sha256(), 0
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


class CLIRenderer:
    """`draft_queue.Renderer` that invokes the headless macOS draft renderer."""

    def __init__(self, executable: Path, output_root: Path, publish_preview: Optional[PreviewPublisher] = None, *,
                 fps: int = 24, width: int = 640, height: int = 360, timeout: float = DEFAULT_TIMEOUT_SECONDS,
                 heartbeat_interval: float = HEARTBEAT_SECONDS, popen: Callable[..., subprocess.Popen] = subprocess.Popen,
                 clock: Callable[[], float] = time.monotonic):
        executable = Path(executable)
        if not executable.is_absolute() or not executable.is_file() or not os.access(executable, os.X_OK):
            raise ValueError(f"{ENV_CLI} must be the absolute path of an executable file.")
        output_root = Path(output_root)
        if not output_root.is_absolute():
            raise ValueError(f"{ENV_OUTPUT} must be an absolute directory path.")
        if not (1 <= fps <= 60 and 16 <= width <= 1920 and 16 <= height <= 1920):
            raise ValueError("Render size must be 16–1920 pixels at 1–60 FPS.")
        if not (1 <= timeout <= MAX_TIMEOUT_SECONDS) or not (1 <= heartbeat_interval <= timeout):
            raise ValueError(f"Render timeout must be 1–{MAX_TIMEOUT_SECONDS} seconds with a shorter heartbeat interval.")
        self.executable, self.output_root, self.publish_preview = executable, output_root, publish_preview
        self.fps, self.width, self.height = fps, width, height
        self.timeout, self.heartbeat_interval = float(timeout), float(heartbeat_interval)
        self._popen, self._clock = popen, clock

    def job(self, plan: Plan) -> dict:
        # Seed as a decimal string: 63-bit seeds are exact only as integers, never doubles.
        return {"brief": plan.brief, "seed": str(plan.seed), "fps": self.fps, "width": self.width, "height": self.height,
                "job_id": f"draft-{plan.target_date.isoformat()}", "project_name": f"Spatter daily draft {plan.target_date.isoformat()}"}

    def render(self, plan: Plan, heartbeat: Callable[[], None]) -> RenderResult:
        if self.publish_preview is None:
            raise RendererError(PREVIEW_NOT_CONFIGURED)
        self.output_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        run_dir = Path(tempfile.mkdtemp(prefix=f"draft-{plan.target_date.isoformat()}-", dir=self.output_root))
        keep = False
        try:
            job_path = run_dir / "job.json"
            job_path.write_text(json.dumps(self.job(plan), sort_keys=True))
            os.chmod(job_path, 0o600)
            receipt = self._run(job_path, run_dir, heartbeat)
            result = self._validate(receipt, plan, run_dir)
            keep = True  # the private draft stays on disk for the owner's review
            return result
        finally:
            if not keep:
                shutil.rmtree(run_dir, ignore_errors=True)

    def _run(self, job_path: Path, run_dir: Path, heartbeat: Callable[[], None]) -> Mapping[str, Any]:
        command = [str(self.executable), "--job", str(job_path), "--output-dir", str(run_dir)]
        heartbeat()
        with tempfile.TemporaryFile(dir=run_dir) as out, tempfile.TemporaryFile(dir=run_dir) as err:
            process = self._popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err, cwd=str(run_dir),
                                  env={"PATH": "/usr/bin:/bin", "LANG": "C", "HOME": str(run_dir), "TMPDIR": str(run_dir)}, close_fds=True)
            deadline = self._clock() + self.timeout
            while True:
                remaining = deadline - self._clock()
                if remaining <= 0:
                    process.kill()
                    process.wait()
                    raise RendererError(f"The draft renderer exceeded its {int(self.timeout)} s limit and was stopped. No draft was submitted.")
                try:
                    code = process.wait(timeout=min(self.heartbeat_interval, remaining))
                    break
                except subprocess.TimeoutExpired:
                    heartbeat()
            heartbeat()
            out.seek(0)
            raw = out.read(MAX_RECEIPT_BYTES + 1)
        if len(raw) > MAX_RECEIPT_BYTES:
            raise RendererError("The draft renderer receipt exceeded its size limit.")
        try:
            receipt = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise RendererError(f"The draft renderer exited with status {code} without a valid JSON receipt.") from None
        if not isinstance(receipt, dict):
            raise RendererError("The draft renderer receipt is not a JSON object.")
        if code != 0 or receipt.get("status") != "rendered":
            message = str(receipt.get("error") or "no reason given")[:1500]
            raise RendererError(f"The draft renderer refused or failed (exit {code}): {message}")
        return receipt

    def _file(self, entry: Any, run_dir: Path, label: str) -> tuple[Path, str]:
        if not isinstance(entry, Mapping) or not isinstance(entry.get("path"), str) or not _SHA.fullmatch(str(entry.get("sha256", ""))):
            raise RendererError(f"The receipt's {label} entry is incomplete.")
        path = Path(entry["path"])
        try:
            resolved = path.resolve(strict=True)
        except OSError:
            raise RendererError(f"The receipt's {label} file does not exist.") from None
        if path.is_symlink() or not resolved.is_file() or run_dir.resolve() not in resolved.parents:
            raise RendererError(f"The receipt's {label} file is outside this render's private directory.")
        actual, size = _sha256_file(resolved)
        if actual != entry["sha256"] or ("bytes" in entry and entry["bytes"] != size):
            raise RendererError(f"The receipt's {label} digest does not match the file on disk.")
        return resolved, actual

    def _validate(self, receipt: Mapping[str, Any], plan: Plan, run_dir: Path) -> RenderResult:
        def fail(detail: str):
            raise RendererError("The draft renderer receipt was rejected: " + detail)
        if receipt.get("schema") != RECEIPT_SCHEMA or receipt.get("version") != RECEIPT_VERSION:
            fail("unknown schema or version.")
        if receipt.get("private_draft") is not True or receipt.get("published") is not False or receipt.get("owner_approval_required") is not True:
            fail("it does not describe an unpublished private draft awaiting owner approval.")
        if receipt.get("brief") != plan.brief or str(receipt.get("seed")) != str(plan.seed):
            fail("brief or seed differs from the planned job.")
        if (receipt.get("fps"), receipt.get("width"), receipt.get("height")) != (self.fps, self.width, self.height):
            fail("frame rate or canvas size differs from the job.")
        movie_path, movie_sha = self._file(receipt.get("movie"), run_dir, "movie")
        self._file(receipt.get("manifest"), run_dir, "manifest")
        _, project_sha = self._file(receipt.get("project"), run_dir, "project")
        if receipt.get("project_digest") != project_sha:
            fail("project digest does not match the saved editable project.")
        storyboard = receipt.get("storyboard")
        if not isinstance(storyboard, Mapping) or storyboard.get("schema") != "spatter_storyboard" or str(storyboard.get("seed")) != str(plan.seed):
            fail("storyboard is missing or belongs to another seed.")
        decoded, expected = receipt.get("decoded_frame_count"), receipt.get("expected_frame_count")
        duration = receipt.get("decoded_duration_seconds")
        if not (isinstance(decoded, int) and isinstance(expected, int) and not isinstance(decoded, bool) and decoded >= 1 and expected >= 1):
            fail("decoded frame counts are missing.")
        if not isinstance(duration, (int, float)) or isinstance(duration, bool) or not math.isfinite(duration):
            fail("decoded duration is missing.")
        quality = receipt.get("quality")
        if not isinstance(quality, Mapping) or not isinstance(quality.get("passes"), bool) or not isinstance(quality.get("failures"), list):
            fail("quality report is missing.")
        quality = dict(quality)
        # Measurements are re-stated next to the verdict so the review shows what was decoded.
        quality.update(decoded_frame_count=decoded, expected_frame_count=expected, decoded_duration_seconds=duration,
                       expected_duration_seconds=receipt.get("expected_duration_seconds"), planned_seconds=plan.seconds)
        failures = list(quality["failures"])
        # Independent cross-checks: a passing verdict must agree with the decoded movie and the plan.
        if decoded != expected:
            failures.append(f"Decoded {decoded} frames; the manifest expected {expected}.")
        if abs(float(duration) - plan.seconds) > 1.0 / self.fps + 0.0005:
            failures.append(f"Decoded duration {float(duration):.3f} s differs from the planned {plan.seconds:.3f} s.")
        if failures != quality["failures"]:
            quality.update(passes=False, failures=failures)
        preview_url = ""
        if quality["passes"]:
            preview_url = self.publish_preview(movie_path, movie_sha, plan)
            if not isinstance(preview_url, str) or not preview_url.startswith("https://") or len(preview_url) > 4096:
                raise RendererError("The private preview publisher did not return an HTTPS URL. No draft was submitted.")
        return RenderResult(sha256=movie_sha, storyboard=dict(storyboard), quality=quality,
                            source_project_digest=project_sha, preview_url=preview_url)


def _bounded_int(environ: Mapping[str, str], key: str, default: int) -> int:
    raw = environ.get(key, "").strip()
    if not raw:
        return default
    if not re.fullmatch(r"[0-9]{1,5}", raw):
        raise ValueError(f"{key} must be a whole number.")
    return int(raw)


def renderer_from_env(environ: Optional[Mapping[str, str]] = None,
                      publish_preview: Optional[PreviewPublisher] = None) -> Optional[CLIRenderer]:
    """The configured CLI renderer, or None when `SDI_DRAFT_RENDERER_CLI` is unset.

    None keeps `draft_queue.run_once` on its honest OWNER-GATED failure path.
    A set-but-invalid configuration raises instead of silently disabling rendering."""
    environ = os.environ if environ is None else environ
    executable = environ.get(ENV_CLI, "").strip()
    if not executable:
        return None
    output = environ.get(ENV_OUTPUT, "").strip() or str(Path(tempfile.gettempdir()) / "sdi-spatter-drafts")
    return CLIRenderer(Path(executable), Path(output), publish_preview,
                       fps=_bounded_int(environ, ENV_FPS, 24), width=_bounded_int(environ, ENV_WIDTH, 640),
                       height=_bounded_int(environ, ENV_HEIGHT, 360),
                       timeout=_bounded_int(environ, ENV_TIMEOUT, DEFAULT_TIMEOUT_SECONDS))
