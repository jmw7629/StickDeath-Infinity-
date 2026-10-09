"""Explicit bounded operator command. No cron or listener is installed."""
import argparse
import json
import sys

from .application import create_application


def main():
    parser = argparse.ArgumentParser(description="Expire privately staged server renders after lease fencing.")
    parser.add_argument("--execute", action="store_true", help="Required: allow removal of expired server copies.")
    parser.add_argument("--limit", type=int, default=25, choices=range(1, 101), metavar="1..100")
    args = parser.parse_args()
    if not args.execute:
        parser.error("No deletion performed. Supply --execute in the approved host maintenance job.")
    try:
        app = create_application()
        removed = app.upload.store.expire(app.upload.register_review.artifact_released, limit=args.limit)
    except Exception:
        # Never print configuration, signed URLs, tokens, paths or raw RPC errors.
        print("Retention did not finish; preserve remaining files and inspect private host diagnostics.", file=sys.stderr)
        return 1
    print(json.dumps({"removed": removed, "candidate_limit": args.limit}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
