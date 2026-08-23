#!/bin/bash
# Fail if any repo OUTSIDE PathMap reaches directly into a ReadZipperCore field.
#
# 🔴 WHY THIS IS A SCRIPT AND NOT A ONE-OFF GREP. On 2026-08-23, splitting
# `ReadZipperCore.ancestors` into three columns passed PathMap's ENTIRE suite — 4097-assertion
# upstream differential included — and then failed at runtime, because `MORK/src/kernel/Space.jl`
# called `empty!(z.ancestors)` directly. A differential over PathMap's own API can NEVER exercise a
# consumer that reaches through it, so no amount of PathMap testing catches this class. The sweep IS
# the enforcement, and an enforcement that lives in a transcript is not one.
#
# Exceptions are allowed ONLY where PathMap exports an intent-named function for the access
# (e.g. `anc_empty!`, and a future `zipper_borrow_path_buf` for the live-buffer alias). Add the
# accessor, do not widen this list.
# ─── THIS GATE IS RED ON PURPOSE, AS OF 2026-08-23 ──────────────────────────────────────────────
# Baseline at time of commit: 9 fields, 18 sites, ALL in MORK/src/kernel/Space.jl. Committed RED so
# it is a standing obligation with a number attached, not a file someone may or may not run. Two
# groups, different fixes and different urgency:
#
#   1. `Space.jl:137-145` — a hand-rolled zipper RE-INIT writing root_node/root_val/root_key_start/
#      origin_path_len/focus_node/focus_iter_token. This is PathMap's CONSTRUCTOR INVARIANTS living
#      in MORK, maintained in two repos with nothing enforcing agreement. It is a live maintenance
#      hazard today, independent of any arena work, and it BREAKS under ADR-001 because the node
#      fields become handles. Fix: export a `zipper_reinit!` from PathMap. Highest urgency.
#
#   2. prefix_buf / origin_path_len reads (`:1271`, `:1280`, `:2571`, `:2593`). Mechanical, and
#      PROBABLY unaffected by ADR-001 — the arena replaces NODE storage; the path buffer stays a
#      Vector{UInt8}. ⚠️ Recorded as CONDITIONAL, not settled: if a later increment moves prefix_buf
#      into arena-backed storage these go live again. Do not inherit "probably unaffected" as fact.
#      `_coref_path_buf` is the one to keep rather than remove — its consumer deliberately ALIASES
#      the live buffer zero-copy (mirroring upstream space.rs:176), so it wants an intent-named
#      export like `zipper_borrow_path_buf`, not deletion.
#
# HOW THIS WAS FOUND: splitting `ReadZipperCore.ancestors` passed PathMap's ENTIRE suite — 4097
# assertion upstream differential included — then failed at runtime because MORK reached in. A
# differential over PathMap's own API CANNOT exercise a consumer that reaches through it. That is
# why this gate exists and why strengthening PathMap's tests would not have helped.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIELDS="root_key_start root_val root_node focus_node focus_iter_token prefix_buf origin_path_len anc_nodes anc_toks anc_offs"
SCOPES="MORK/src MORK/test Core/src"
fail=0
for f in $FIELDS; do
  for d in $SCOPES; do
    [ -d "$ROOT/$d" ] || continue
    hits=$(grep -rn "\.$f\b" "$ROOT/$d" 2>/dev/null | grep -v '^\S*: *[0-9]*: *#')
    [ -n "$hits" ] && { echo "DIRECT FIELD ACCESS  .$f"; echo "$hits" | sed 's/^/    /'; fail=1; }
  done
done
if [ "$fail" -eq 0 ]; then
  echo "encapsulation OK — no direct ReadZipperCore field access outside PathMap"
else
  echo
  echo "🔴 Each site above breaks silently under ADR-001's arena increment, with PathMap green."
  echo "   Fix by exporting an intent-named accessor from PathMap, not by editing this script."
fi
exit $fail
