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
# KNOWN GAP, recorded here deliberately: PathMap has NO differential oracle against upstream, though
# the Rust source sits at ~/JuliaAGI/dev-zone/PathMap-upstream. Every test here checks our port
# against expectations we wrote ourselves, which cannot catch a silently-wrong value we did not
# anticipate — the exact class MORK's upstream_conformance.jl exists to catch. Do not read a green
# PathMap suite as "conforms to upstream"; it means "self-consistent".
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
julia --project=. --threads="${JULIA_TEST_THREADS:-4}" -i "$DRIVER" < /dev/null
# allow-cold-start: full-suite runner; a suite run is a cold run by nature
