#!/bin/bash
# run_tests.sh — run PathMap's suite and EXIT WITH THE RESULT.
#
# WHY THIS EXISTS (2026-07-23). The invocation documented at the top of tools/repl.jl,
#     printf 'include("test/runtests.jl")\n' | julia --project=. tools/repl.jl
# DOES NOT RUN THE TESTS AT ALL. Without `-i`, julia executes the script argument and NEVER READS
# STDIN, so the piped `include` is discarded. Measured: 0 lines of output, 0 test summaries, EXIT 0.
# A completely silent no-op that reports success — the documented way to test this package could not
# fail, because it never ran anything.
#
# Adding `-i` runs the suite but is still exit-code blind: `julia -i` with piped stdin is
# interactive, and interactive mode SWALLOWS exceptions — the throw prints, the REPL continues, and
# the trailing `exit()` returns 0. Measured on this package: a suite ending
# `151 passed, 0 failed, 1 errored, 1 broken` EXITED 0. (MORK had the identical hole; see its
# tools/run_tests.sh and commit c543841, where a shadowed `Base.run` left that repo's only upstream
# differential check erroring on every mandated run, unnoticed, because the exit code said 0.)
#
# The fix: put the driver in a FILE, guard the include, and exit with a code computed from whether it
# threw. A Julia testset throws `Some tests did not pass: …` when anything failed OR errored, so
# failures and errors both land here.
#
# `< /dev/null` is LOAD-BEARING — not tidiness. Aqua's `test_persistent_tasks` spawns via
# `run(cmd, stdin, stdout, stderr; wait=false)` (Aqua persistent_tasks.jl:114), handing it the
# CURRENT stdin as an explicit stdio handle. Piping the driver in leaves stdin a PipeEndpoint that
# printf has ALREADY CLOSED — `isopen(stdin) == false` — and libuv rejects a closed handle with
# EINVAL. That is the permanent `1 errored` this suite carried. Isolated to the stdio argument, NOT
# the environment: default-stdio spawn OK, explicit-stdio spawn EINVAL, explicit-stdio spawn under
# `< /dev/null` OK (stdin is then an open IOStream).
#
# ✅ CLOSED — this header used to say "PathMap has NO differential oracle against upstream, so a green
# suite means self-consistent, not conformant". That has not been true since 2026-07-27 and the note
# was actively misleading by 2026-08-01. There are now THREE upstream-graded gates, all wired into
# the suite and all run by this script:
#
#   test/differential/run_differential.jl   42 curated scenarios, ours vs the Rust probe
#   test/differential/run_fuzz.jl           3000 generated cases, byte-compared; ratcheted at 30
#                                           KNOWN_DIVERGENT, each attributed to a named upstream
#                                           defect in fuzz/TRIAGE.md
#   test/test_restrict.jl                   28 hand-written RESTRICT cases, expectations taken
#                                           verbatim from `gen_fuzz --exec`
#
# The oracle is `test/differential/rust_probe`, which depends on the upstream checkout BY PATH, so
# it grades against whatever is vendored (currently 52fd9df) rather than a snapshot of it.
#
# ⚠️ WHAT A GREEN SUITE STILL DOES NOT MEAN. The fuzz corpus generates 12 ops and UNIT values only,
# so value-payload algebra is unexercised (run_fuzz.jl's header explains why), and ops outside that
# vocabulary — join_k_path_into, restrict, graft_child_maps, meet_k_path_into, join_into_take — are
# reached only by hand-written cases. Two real defects hid in exactly that gap this week. Read a
# green suite as "conforms on the covered surface", and check the surface before trusting it.
#
# Usage:  tools/run_tests.sh            # whole suite
#         tools/run_tests.sh path.jl    # one file
# Exit:   0 = all green · 1 = failure/error
set -uo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:-test/runtests.jl}"

ROOT="$PWD"
case "$TARGET" in /*) ABS_TARGET="$TARGET" ;; *) ABS_TARGET="$ROOT/$TARGET" ;; esac

# ABSOLUTE paths inside the driver, and the repl load INSIDE the guard. Both are scar tissue: a
# relative `include("tools/repl.jl")` from a driver in /tmp resolves against the SCRIPT'S directory,
# threw, and was swallowed by `-i` — so passing AND failing targets both exited 0. Under `-i`,
# nothing outside an explicit try/exit can be trusted to fail the build.
DRIVER="$(mktemp "${TMPDIR:-/tmp}/pathmap_run_tests_XXXXXX.jl")"
trap 'rm -f "$DRIVER"' EXIT
cat > "$DRIVER" <<EOF
ok = try
    include(raw"$ROOT/tools/repl.jl")
    include(raw"$ABS_TARGET")
    true
catch e
    showerror(stderr, e); println(stderr)
    false
end
exit(ok ? 0 : 1)
EOF

# --threads: ALSO load-bearing. The concurrency tests guard REAL fixes — the node-keyed atomic
# refcount (close-out 2-A) replaced a racy per-wrapper `Ref{Int} += 1` — and they degrade to
# `@test_skip` below 2 threads because single-threaded they would pass VACUOUSLY. Julia defaults to
# 1 thread, so under every invocation this repo documented, that guard asserted NOTHING while the
# suite read green. The inert-testset check in test/runtests.jl is what surfaces it.
# ── MEMORY CEILING — the test process must die BEFORE the machine does ──────────────────────────
#
# THE SAME GUARD AS `Core/tools/run_tests.sh`, added the same day and for the same measured reason
# (these three runners are one lineage; this one is a separate repo, so it is a copy and not an
# include). MEASURED 2026-08-10 in Core: a test evaluated a space-wide `match` with a variable
# pattern, the process grew past the box's 17 GB, and the kernel OOM-killer chose its victim by score
# — it killed the VS Code SERVER, not the runaway. A bad test in one process cost the developer their
# editor session.
#
# A cgroup scope fixes the blast radius: the runaway hits ITS OWN ceiling, dies with 137, and nothing
# outside the scope is a candidate. `MemorySwapMax=0` matters as much as `MemoryMax` — without it the
# process thrashes swap for minutes first. `--heap-size-hint` is the cooperative half, set BELOW the
# hard cap so Julia's GC gets its chance before the kernel does.
#
# Override:       PATHMAP_TEST_MEM_MAX=12G tools/run_tests.sh
# Escape hatch:   PATHMAP_TEST_MEM_MAX=none tools/run_tests.sh
MEM_MAX="${PATHMAP_TEST_MEM_MAX:-8G}"
HEAP_HINT="${PATHMAP_TEST_HEAP_HINT:-6G}"
JL=(julia --project=. --threads="${JULIA_TEST_THREADS:-4}" --heap-size-hint="$HEAP_HINT"
    -i "$DRIVER")

if [ "$MEM_MAX" = "none" ]; then
  echo "run_tests.sh: memory ceiling DISABLED (PATHMAP_TEST_MEM_MAX=none)" >&2
  "${JL[@]}" < /dev/null
elif command -v systemd-run >/dev/null 2>&1 &&
     systemd-run --user --scope -p MemoryMax=256M --quiet true >/dev/null 2>&1; then
  # `--scope` runs it as a child of THIS shell, so stdin/stdout and the exit code pass through
  # unchanged — which the `< /dev/null` discipline above depends on.
  systemd-run --user --scope -p MemoryMax="$MEM_MAX" -p MemorySwapMax=0 --quiet \
      "${JL[@]}" < /dev/null
  rc=$?
  [ $rc -eq 137 ] && echo "run_tests.sh: KILLED at the ${MEM_MAX} ceiling — a test allocated without
  bound. Find it before raising PATHMAP_TEST_MEM_MAX." >&2
  exit $rc
else
  echo "run_tests.sh: WARNING — systemd-run --user --scope unavailable; running WITHOUT a memory
  ceiling. A runaway test can OOM-kill unrelated processes on this machine." >&2
  "${JL[@]}" < /dev/null
fi
# allow-cold-start: full-suite runner; a suite run is a cold run by nature
