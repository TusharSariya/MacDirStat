#!/bin/zsh
# Read-only scans. Build once, then alternate reference and candidate to reduce order bias.
set -eu
cd "${0:A:h:h}"
if [[ $# -ne 1 ]]; then
  print -u2 'Usage: scripts/benchmark-scanner.sh /path/to/readable/stable/folder'
  exit 2
fi
benchmark_dir=$(mktemp -d /tmp/MacDirStat-benchmark.XXXXXX)
trap 'rm -rf "$benchmark_dir"' EXIT
xcrun swiftc -O -swift-version 6 -parse-as-library MacDirStat/Core/*.swift \
  Tests/Performance/{ScannerBenchmark,ReferenceScanner,BulkScannerExperiment}.swift -o "$benchmark_dir/benchmark"
for iteration in 1 2 3; do
  print "Reference round $iteration"
  "$benchmark_dir/benchmark" "$1" 1
  print "Parallel round $iteration (4 workers, depth 4)"
  WORKERS=4 DEPTH=4 "$benchmark_dir/benchmark" "$1" 1
done
xcrun swiftc -O -swift-version 6 -parse-as-library MacDirStat/Core/*.swift \
  Tests/Performance/{ReferenceScanner,ScannerParity}.swift -o "$benchmark_dir/parity"
"$benchmark_dir/parity" "$1"
