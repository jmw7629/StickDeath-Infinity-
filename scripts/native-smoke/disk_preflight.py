#!/usr/bin/env python3
"""Read-only free-space preflight for expensive native work (#295).

Reports whether the volume holding PATH has the headroom the October 8
checkpoints recorded: at least 1.85 GiB free before starting a bounded native
run, and never continuing below the 1.4 GiB floor at which Xcode result
finalization was interrupted. The script only measures; it never deletes,
moves or creates files, and it does not lower either threshold.

Exit codes: 0 start headroom met, 2 below start but above the floor (do not
begin new expensive work), 3 at or below the floor (stop and record the
checkpoint), 4 measurement failed. Output is one JSON object on stdout.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time

GIB = 1024 ** 3
START_GIB = 1.85
FLOOR_GIB = 1.4
EXIT_OK, EXIT_BELOW_START, EXIT_BELOW_FLOOR, EXIT_ERROR = 0, 2, 3, 4


def measure(path: str, start_gib: float = START_GIB, floor_gib: float = FLOOR_GIB,
            usage=shutil.disk_usage, now=time.time) -> dict:
    if start_gib <= floor_gib or floor_gib <= 0:
        raise ValueError("The start threshold must exceed a positive floor")
    if start_gib < START_GIB or floor_gib < FLOOR_GIB:
        raise ValueError("The recorded 1.85 GiB start / 1.4 GiB floor cannot be lowered here")
    total, used, free = usage(path)
    free_gib = free / GIB
    if free_gib >= start_gib:
        status, exit_code = "ok", EXIT_OK
        advice = "Start headroom met; still monitor during the run."
    elif free_gib > floor_gib:
        status, exit_code = "below-start", EXIT_BELOW_START
        advice = "Do not start new expensive native work; finish or checkpoint current work only."
    else:
        status, exit_code = "below-floor", EXIT_BELOW_FLOOR
        advice = "Stop expensive work and record the checkpoint; housekeeping is a separate, owner-reviewed step."
    return {
        "path": os.path.abspath(path), "measuredAt": int(now()),
        "totalBytes": total, "usedBytes": used, "freeBytes": free,
        "freeGiB": round(free_gib, 3), "startGiB": start_gib, "floorGiB": floor_gib,
        "status": status, "exitCode": exit_code, "advice": advice,
        "deletedAnything": False, "readOnly": True,
    }


def main(argv: list[str] | None = None, usage=shutil.disk_usage) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("path", nargs="?", default=os.path.expanduser("~"), help="a path on the volume to measure (default: home)")
    parser.add_argument("--start-gib", type=float, default=START_GIB, help="required free space to begin (>= 1.85)")
    parser.add_argument("--floor-gib", type=float, default=FLOOR_GIB, help="stop threshold (>= 1.4)")
    arguments = parser.parse_args(argv)
    try:
        result = measure(arguments.path, arguments.start_gib, arguments.floor_gib, usage=usage)
    except (OSError, ValueError) as error:
        print(json.dumps({"path": arguments.path, "status": "error", "error": str(error), "exitCode": EXIT_ERROR,
                          "deletedAnything": False, "readOnly": True}, sort_keys=True))
        return EXIT_ERROR
    print(json.dumps(result, sort_keys=True))
    return result["exitCode"]


if __name__ == "__main__":
    sys.exit(main())
