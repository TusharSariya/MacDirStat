#!/usr/bin/env python3
"""Read-only comparison of the production scanner against an independent lstat walk."""
import os
from pathlib import Path
import stat
import subprocess
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: scripts/verify-real-scan.py /path/to/readable/stable/folder")
root = Path(sys.argv[1]).resolve(strict=True)
if not root.is_dir():
    raise SystemExit("Choose a folder")
count, logical = 1, 0

def failed(error):
    raise error  # This check requires a fully readable tree, not a partial baseline.

for parent, directories, files in os.walk(root, followlinks=False, onerror=failed):
    for name in directories + files:
        info = os.lstat(os.path.join(parent, name))
        count += 1
        if not stat.S_ISDIR(info.st_mode):
            logical += info.st_size
print(f"Independent baseline: {count} entries, {logical} logical bytes", flush=True)
environment = dict(os.environ, MACDIRSTAT_BENCHMARK_PATH=str(root),
                   MACDIRSTAT_EXPECT_NODES=str(count), MACDIRSTAT_EXPECT_BYTES=str(logical))
result = subprocess.run(["swift", "test", "-c", "release", "--filter",
                         "DiskScannerTests/testReadOnlyPerformanceProbe"],
                        cwd=Path(__file__).resolve().parent.parent, env=environment)
raise SystemExit(result.returncode)
