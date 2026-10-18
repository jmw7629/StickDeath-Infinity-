#!/usr/bin/env python3
"""Exercise the compiled headless draft renderer through the production Python adapter (#212).

macOS only (the CLI uses AVFoundation). Usage:

    python3 scripts/backend/verify_draft_renderer_cli.py <path to SpatterDraftRenderer> <empty work directory>

1. Plans the 2026-10-18 daily brief (`draft_queue.plan_brief`, 19-digit seed),
   renders it with `renderer_cli.CLIRenderer` and submits it through
   `draft_queue.run_once` to the in-memory review queue.
2. Re-checks the receipt fields that matter for owner review against the files.
3. Confirms a brief over the planner's element budget is refused (exit 2).

Previews use the real owner-only DraftPreviewStore on a throwaway private
directory with a random key; nothing is uploaded, fetched or published.
"""
import datetime as dt
import hashlib
import json
import secrets
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from backend.spatter import draft_queue as dq  # noqa: E402
from backend.spatter import renderer_cli as rc  # noqa: E402
from backend.ingestion.preview import PreviewLinks  # noqa: E402
from backend.spatter.draft_preview import DraftPreviewStore, draft_upload_id  # noqa: E402

DAY = dt.date(2026, 10, 18)
NOW = dt.datetime(2026, 10, 18, 9, 0, tzinfo=dt.timezone.utc)


def main(cli: Path, work: Path) -> None:
    work.mkdir(parents=True, exist_ok=True)
    plan = dq.plan_brief(DAY)
    assert len(str(plan.seed)) == 19, plan.seed
    print("BRIEF", plan.brief)
    previews = []
    # The real owner-only preview store on a throwaway private intake directory and
    # a random per-run signing key; the link is checked but never fetched over a network.
    intake = work.resolve() / "intake"
    intake.mkdir(mode=0o700)
    links = PreviewLinks("https://intake.invalid", secrets.token_bytes(32), lifetime=600)
    owner = str(uuid.uuid4())
    drafts = DraftPreviewStore(intake, links, owner, retention=3600)

    def preview(path, sha, plan):
        assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == sha
        previews.append((str(path), sha))
        return drafts.publish(Path(path), sha, plan)

    renderer = rc.CLIRenderer(cli.resolve(), work.resolve() / "drafts", preview, fps=24, width=640, height=360, timeout=300)
    store = dq.InMemoryStore(now=lambda: NOW)
    outcome = dq.run_once(store, owner="ci-worker", reviewer="owner", now=lambda: NOW, renderer=renderer, target_date=DAY)
    print("OUTCOME", json.dumps(outcome.as_dict(), sort_keys=True))
    assert outcome.state == "review_pending", outcome.reason
    job = store.jobs[DAY]
    quality = job["quality"]
    expected_frames = int(round(plan.seconds * 24))
    assert dq.quality_record_problem(quality) is None, quality
    assert quality["passes"] is True and quality["failures"] == [], quality
    movie_counts = quality["movie"]
    assert movie_counts["decodedFrameCount"] == movie_counts["expectedFrameCount"] == quality["frameCount"], quality
    assert quality["actualTicks"] == quality["requestedTicks"] == expected_frames, quality
    assert abs(movie_counts["decodedDurationSeconds"] - plan.seconds) < 0.001, quality
    assert not any(f["kind"] in ("blankFrame", "frozenFrame", "outOfCanvas") for f in quality["findings"]), quality
    assert len(previews) == 1 and previews[0][1] == job["sha256"]
    upload = draft_upload_id(job["sha256"])
    assert drafts.authority(upload, owner, job["sha256"]) is not None
    assert drafts.authority(upload, str(uuid.uuid4()), job["sha256"]) is None
    assert hashlib.sha256((intake / (upload + ".mp4")).read_bytes()).hexdigest() == job["sha256"]
    movie = Path(previews[0][0])
    assert movie.stat().st_size > 1000 and movie.suffix == ".mp4"
    review = store.reviews[0]
    assert review["state"] == "pending" and review["destinations"] == [] and review["render_digest"] == job["sha256"]
    # The retained-render record the owner's renewal and approval path needs.
    assert review["artifact"]["object_key"] == upload + ".mp4", review
    assert review["artifact"]["byte_count"] == (intake / (upload + ".mp4")).stat().st_size, review
    project = next(movie.parents[1].glob("project.json"))
    assert hashlib.sha256(project.read_bytes()).hexdigest() == review["source_project_digest"]
    assert json.loads(project.read_text())["fps"] == 24
    print("PASS rendered", expected_frames, "ticks,", quality["movie"]["decodedFrameCount"], "decoded frames,", plan.seconds, "s, sha256", job["sha256"], "-> owner review queue only")

    over = {"brief": "A red stick figure walks left to right, then explodes; a blue stick figure runs right to left, then explodes; "
                     "a green stick figure jumps, then falls; 8 seconds; seed 3.", "fps": 24, "width": 640, "height": 360}
    refused = subprocess.run([str(cli), "--job", "-", "--output-dir", str(work)], input=json.dumps(over).encode(),
                             capture_output=True, timeout=120)
    receipt = json.loads(refused.stdout)
    assert refused.returncode == 2 and receipt["status"] == "failed" and receipt["published"] is False, (refused.returncode, receipt)
    print("PASS over-budget brief refused:", receipt["error"][:160])


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(Path(sys.argv[1]), Path(sys.argv[2]))
