# Indexing performance goal

Status: completed after six measured iterations; 24 regular core tests and integration checks pass, and the signed arm64 app/helper build succeeds. Optimize through correctness-checked iterations on this 14-core
Apple-silicon Mac, preserving UI responsiveness, cancellation, symlink semantics,
allocation reporting and the depth-first node layout. Administrator helper OS
lifecycle testing is explicitly deferred by the user.

## Method

Compile production source with Swift 6 and -O. Compare first observed runs separately
from repeated warm runs; do not call a first run a controlled cold-cache test. Do not
flush system caches or modify user data. Compare per-path metadata, not just root sums.
Benchmark narrow/deep and broad trees; investigate native metadata and bounded worker
counts. Stop after several measured alternatives fail to materially improve realistic
workloads, documenting tradeoffs rather than claiming theoretical optimality.

Harness: `Tests/Performance/ScannerBenchmark.swift`.

## Research

- Apple: [Apple silicon tuning](https://developer.apple.com/documentation/apple-silicon/tuning-your-code-s-performance-for-apple-silicon).
- Apple: [Scheduling CPU work](https://developer.apple.com/documentation/xcode/scheduling-cpu-work-efficiently).
- Apple XNU: [getattrlistbulk](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/getattrlistbulk.2).
- Apple: [getattrlist attributes](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/getattrlist.2.html).

Bulk enumeration returns link metadata without following links. Requested fields
must be checked against returned attribute flags; mount points and firmlinks need
special treatment. Foundation prefetch already uses bulk operations where possible,
so a lower-level rewrite is not automatically a syscall-count improvement.

## Initial observations

Xcode.app, 167,226 entries, 10,348,945,117 logical bytes and 4,244,824,064 allocated bytes:

| Implementation | First observed | Warm runs | Peak process RSS |
|---|---:|---:|---:|
| Existing Foundation scanner | 5.277 s | 2.430 / 2.439 s | 199 MB |
| Experimental physical FTS/stat scanner | 1.319 s | 1.275 / 1.273 s | 199 MB |

The FTS run followed Foundation's scans and is warm, not a cold comparison.
Its totals match on Xcode but it is not approved for production until broader
per-entry allocation, permissions and cancellation equivalence checks pass.

## Iterations and decision

1. Native FTS physical traversal reuses `stat` metadata, eliminating a Foundation
   metadata conversion plus a second lstat per entry. Physical mode never follows
   symbolic links; NOCHDIR avoids process-global working-directory mutation.
2. Partition depth 2 with 1–14 workers: ~1.58–1.71 s on Xcode, slower than serial
   FTS because work is uneven and merging/sorting adds cost. Rejected.
3. Partition depths 3–5: depth 4 exposes useful independent work. Eight workers
   reached ~1.04 s before the subsequent sorting improvement; depth 5 added little.
4. Remove per-subtree sorting and sort only after merging: four workers ~0.90 s,
   eight ~0.86 s, fourteen ~0.90 s. Choose four as the performance/memory/CPU-use
   compromise, rather than saturating every core for a small extra gain.
5. `getattrlistbulk` prototype: ~1.33 s on Xcode, behind serial FTS (~1.27 s).
   Directories require additional metadata handling; retain prototype only under
   Tests/Performance, not in the app. It intentionally aborts on entry errors and
   does not implement the app's partial-result policy.
6. Reserve merge storage and reuse already-cached display names. The final Xcode
   candidate reaches ~0.90 s with ~196 MB peak RSS, comparable to reference memory,
   rather than the earlier ~250 MB parallel implementation. Flat trees bypass the
   merge when there are no subtrees to distribute.

Final alternating fresh-process Xcode run (both implementations observe warm caches
except the first reference run, which was not controlled cold):

| Round | Reference | Four-worker candidate | Candidate peak RSS |
|---|---:|---:|---:|
| 1 | 3.274 s | 0.892 s | 196 MB |
| 2 | 2.530 s | 0.904 s | 195 MB |
| 3 | 2.587 s | 0.900 s | 196 MB |

Per-entry validation: all 167,226 Xcode entries and 242,878 Homebrew Cellar entries
match the original scanner's logical/allocated sizes, identities, directory/link
flags, and descendant counts. Resource-fork, sparse-file, hard-link, symlink-cycle,
broken-link and FIFO fixtures also pass. Unit checks cover partial permissions,
root protection, cancelled scans, and contiguous depth-first subtree IDs after merge.

The application and read-only helper now call the asynchronous parallel scanner.
Each subtree owns its nodes; a lock protects only throttled progress. A deterministic
merge restores the depth-first ID intervals required by treemap selection. Root
errors remain fatal, subtree failures produce visible partial results, and cancellation
propagates through the task group, traversal, merge and sorting.

## Limits and stopping criterion

No claim of an absolute speed limit: repeated scans benefit from filesystem caches,
CPU scheduling/thermal conditions vary, and slow disks/network/cloud providers were
not benchmarked. System caches were not flushed. The implementation retains a full
in-memory tree; peak memory scales with entry count. Fixed-depth partitioning can
still be uneven on unusual trees. Future profiling could justify a dynamic queue or
parallel sorting, but current measurements do not establish that benefit.

Additional worker counts, deeper partitioning and bulk metadata did not produce a
compelling improvement over the chosen configuration. Process-based scanning was
not adopted: it adds metadata serialization/IPC and independent heaps to a workload
already parallelized inside one process. This is an architectural inference, not a
measured process benchmark. GPU/Metal cannot execute filesystem metadata syscalls;
no GPU indexing path was introduced. Native Swift concurrency and user-initiated QoS
let macOS schedule work across core types rather than manually pinning cores.

Reproduce the final alternating timings and complete per-entry comparison:

```sh
scripts/benchmark-scanner.sh /Applications/Xcode.app
scripts/benchmark-scanner.sh /opt/homebrew/Cellar
```

The stored benchmark defaults to the preserved reference implementation; WORKERS
selects the production parallel scanner, SCANNER=fts selects serial native traversal,
and SCANNER=bulk selects the experimental bulk parser. DEPTH defaults to 4.

Final alternating Homebrew Cellar run:

| Round | Reference | Four-worker candidate | Candidate peak RSS |
|---|---:|---:|---:|
| 1 | 4.116 s | 1.016 s | 253 MB |
| 2 | 4.065 s | 1.045 s | 254 MB |
| 3 | 4.048 s | 1.009 s | 254 MB |

Reference peak RSS was ~236 MB. All three runs reported 242,878 entries,
9,562,003,680 logical bytes and 10,091,474,944 allocated bytes. The final per-entry
comparison found zero differences. Benchmarks exclude app rendering and full UI
publication; core scan time includes traversal, merge, aggregation and sorting.
