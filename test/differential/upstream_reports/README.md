# Upstream defect reports for `Adam-Vandervorst/PathMap` — ready to submit

Two defects found by differential-fuzzing our Julia port against the Rust build (3000 random
programs, delta-debugged to minimal reproducers). Both were confirmed by EXECUTION via
`gen_fuzz --exec <dir>`, not by reading. **Not yet filed**: `gh` is not installed on this machine.

Each file's first line is the issue TITLE; everything after the `---` is the BODY.

```bash
for f in pathmap-*.md; do
  gh issue create -R Adam-Vandervorst/PathMap -t "$(head -1 $f)" -F <(tail -n +3 $f)
done
```

⚠️ The MORK defects go to a DIFFERENT upstream — `trueagi-io/MORK`, see
`MORK/test/conformance/upstream_reports/`.

## Both are silent data loss

| file | defect |
|---|---|
| `pathmap-1` | `subtract_into` removes a value at a PREFIX of a subtracted path, on dense nodes. One op, three keys. |
| `pathmap-2` | `graft_map` destroys the subtrie it just grafted, when the source map has a root value. One op. |

`pathmap-1` carries a note listing the shapes that are CORRECT upstream. It resisted six hypotheses
because each was tested on a shape too small to reach the dense-node path, and a reader without that
warning would repeat the mistake.

Full write-ups, including the refuted hypotheses, are in `../UPSTREAM_BUGS.md`.
