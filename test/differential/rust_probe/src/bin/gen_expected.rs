//! Ground-truth generator for PathMap's upstream differential gate.
//!
//! Emits one `SCENARIO<TAB>RESULT` line per case, run against the UPSTREAM Rust `pathmap`.
//! `test/differential/run_differential.jl` runs the SAME scenarios in Julia and compares.
//!
//! Rules for adding a scenario:
//!   * the name must be stable — it is the ratchet key in EXPECTED_PASS.txt
//!   * RESULT must be a total, canonical string (sorted keys) so a diff is meaningful
//!   * the Julia side must construct the scenario identically; keep the two in the same order
//!
//! Regenerate:  cargo run --release --bin gen_expected > ../expected/upstream.tsv
use pathmap::PathMap;
use pathmap::zipper::*;

/// Canonical rendering: sorted value-paths plus the value count.
/// Sorted so trie iteration order can never make a passing case look failing.
fn dump(m: &PathMap<()>) -> String {
    let mut z = m.read_zipper();
    let mut v: Vec<String> = vec![];
    while z.to_next_val() {
        v.push(String::from_utf8_lossy(z.path()).to_string());
    }
    v.sort();
    format!("[{}] vc={}", v.join(","), m.val_count())
}

fn mk(keys: &[&str]) -> PathMap<()> {
    let mut m = PathMap::<()>::new();
    for k in keys {
        m.set_val_at(k.as_bytes(), ());
    }
    m
}

fn emit(name: &str, result: String) {
    println!("{}\t{}", name, result);
}

fn main() {
    // ---- path_exists_at ------------------------------------------------------
    // Mid-edge prefixes. This is the shape that was WRONG in our port until
    // 2026-07-27 (reported "a"/"abcd"/"abcdefghi" absent) and had no upstream check.
    let m = mk(&["abc", "abcdefghij"]);
    for p in ["a", "ab", "abc", "abcd", "abcdefghi", "abcdefghij", "abz", "abcx", ""] {
        emit(
            &format!("path_exists_at/{}", if p.is_empty() { "<empty>" } else { p }),
            format!("{}", m.path_exists_at(p.as_bytes())),
        );
    }
    // Empty-path existence, across map states — pins what "" means before we change our answer.
    let empty_map = PathMap::<()>::new();
    emit("path_exists_at/empty_map_empty_path", format!("{}", empty_map.path_exists_at(b"")));
    emit("path_exists_at/empty_map_some_path", format!("{}", empty_map.path_exists_at(b"a")));
    let mut rootonly = PathMap::<()>::new();
    rootonly.set_val_at(b"", ());
    emit("path_exists_at/rootval_empty_path", format!("{}", rootonly.path_exists_at(b"")));
    emit("path_exists_at/rootval_some_path", format!("{}", rootonly.path_exists_at(b"a")));

    let key16 = "zzzzzzzzzzzzzzzz";
    let m2 = mk(&[key16]);
    let bits: String = (1..=16)
        .map(|n| if m2.path_exists_at(&key16.as_bytes()[..n]) { 'T' } else { 'F' })
        .collect();
    emit("path_exists_at/16z_prefixes", bits);

    // ---- get_val_at / val_count ---------------------------------------------
    emit("basic/mk_three", dump(&mk(&["a", "ab", "abc"])));
    emit("basic/empty", dump(&PathMap::<()>::new()));
    let mut m = mk(&["k1", "k2", "k3"]);
    m.remove_val_at(b"k2", false);
    emit("basic/remove_noprune", dump(&m));
    let mut m = mk(&["k1", "k2", "k3"]);
    m.remove_val_at(b"k2", true);
    emit("basic/remove_prune", dump(&m));

    // ---- graft / algebra at a NON-ROOT focus ---------------------------------
    // The `graft_root_vals` family. An audit reported 4/4 divergences here; these
    // pin upstream's actual answers so the claim is settled by the gate, not by argument.
    let mut a = mk(&["p", "px", "q"]);
    let src = mk(&["y"]);
    {
        let mut wz = a.write_zipper_at_path(b"p");
        wz.graft_map(src);
    }
    emit("graft/graft_map_at_p", dump(&a));

    let mut a = mk(&["p", "px", "q"]);
    let src = mk(&["x"]);
    {
        let sz = src.read_zipper();
        let mut wz = a.write_zipper_at_path(b"p");
        wz.meet_into(&sz, false);
    }
    emit("graft/meet_into_at_p", dump(&a));

    let mut a = mk(&["p", "px", "q"]);
    let mut src = PathMap::<()>::new();
    src.set_val_at(b"", ());
    {
        let sz = src.read_zipper();
        let mut wz = a.write_zipper_at_path(b"p");
        wz.subtract_into(&sz, false);
    }
    emit("graft/subtract_into_rootval_at_p", dump(&a));

    let mut a = mk(&["px", "py", "q"]);
    let src = mk(&["y"]);
    {
        let sz = src.read_zipper();
        let mut wz = a.write_zipper_at_path(b"p");
        wz.join_into(&sz);
    }
    emit("graft/join_into_at_p", dump(&a));

    // ---- graft_root_vals: DISCRIMINATING cases -------------------------------
    // The three failing graft scenarios above all have the focus value present and the
    // source root value absent, so they cannot tell "we ignore the focus value" apart from
    // "we clear the focus value". These pin the other direction and the ops the first set
    // never reaches. `graft_root_vals` is a DEFAULT feature (Cargo.toml:39); under it the
    // focus value is the counterpart of the source's ROOT value.

    // graft_map where the SOURCE ROOT has a value and the focus does NOT: upstream's
    // `Some(src_val) => self.set_val(src_val)` (write_zipper.rs:1471) MAKES `p` appear.
    let mut a = mk(&["px", "q"]);
    let mut src = PathMap::<()>::new();
    src.set_val_at(b"", ());
    src.set_val_at(b"y", ());
    {
        let mut wz = a.write_zipper_at_path(b"p");
        wz.graft_map(src);
    }
    emit("graft/graft_map_rootval_sets_focus", dump(&a));

    // join_map_into: upstream HAS a graft_root_vals block (write_zipper.rs:1682) even though
    // its own doc comment claims "the currently implemented behavior is NO". The body wins.
    // `join_into` (read-zipper variant) has NO such block — hence the asymmetry, and hence
    // `graft/join_into_at_p` passing is NOT evidence that join is ported.
    let mut a = mk(&["px", "q"]);
    let mut src = PathMap::<()>::new();
    src.set_val_at(b"", ());
    {
        let mut wz = a.write_zipper_at_path(b"p");
        wz.join_map_into(src);
    }
    emit("graft/join_map_into_rootval_at_p", dump(&a));

    // CONTROL: join must NOT clear the focus value when the source root has none
    // (`(Some(_), None) => Identity`). Guards against over-correcting meet's clear into join.
    let mut a = mk(&["p", "px", "q"]);
    let src = mk(&["y"]);
    {
        let mut wz = a.write_zipper_at_path(b"p");
        wz.join_map_into(src);
    }
    emit("graft/join_map_into_keeps_focus_val", dump(&a));

    // take_map at a focus holding ONLY a value: upstream takes the value out into the
    // returned map's root_val (write_zipper.rs:2121) and returns Some even with no root node.
    let mut a = mk(&["p", "q"]);
    let taken = {
        let mut wz = a.write_zipper_at_path(b"p");
        wz.take_map(false)
    };
    emit(
        "graft/take_map_valonly_taken",
        match &taken {
            Some(m) => dump(m),
            None => "None".to_string(),
        },
    );
    emit("graft/take_map_valonly_residue", dump(&a));

    // ---- join / meet / subtract at ROOT --------------------------------------
    let mut a = mk(&["a", "b"]);
    let b = mk(&["b", "c"]);
    {
        let sz = b.read_zipper();
        let mut wz = a.write_zipper();
        wz.join_into(&sz);
    }
    emit("algebra/join_root", dump(&a));

    let mut a = mk(&["a", "b", "c"]);
    let b = mk(&["b", "c", "d"]);
    {
        let sz = b.read_zipper();
        let mut wz = a.write_zipper();
        wz.meet_into(&sz, false);
    }
    emit("algebra/meet_root", dump(&a));

    let mut a = mk(&["a", "b", "c"]);
    let b = mk(&["b"]);
    {
        let sz = b.read_zipper();
        let mut wz = a.write_zipper();
        wz.subtract_into(&sz, false);
    }
    emit("algebra/subtract_root", dump(&a));

    // ---- the Option<V> blanket-impl boundary ---------------------------------
    // `a` has a CHILD at "a" but NO VALUE there; `b` HAS a value at "a". Both ops then drive the
    // `impl for Option<V>` blanket with self = None and other = Some(()) — the branch upstream's
    // own `option_subtract_test` never asserts (it only ever has `Some(..)` on the left) and that
    // none of the existing 42 fixtures reached. Our port returned Identity(SELF_IDENT) there where
    // ring.rs:734 says `None => AlgebraicResult::None`, which routes `_cf_combine_results` down a
    // different branch: KEEP the entry instead of REMOVE it.
    let mut a = mk(&["ab"]);
    let b = mk(&["a"]);
    {
        let sz = b.read_zipper();
        let mut wz = a.write_zipper();
        wz.subtract_into(&sz, false);
    }
    emit("algebra/subtract_val_absent", dump(&a));

    let mut a = mk(&["ab"]);
    let b = mk(&["a"]);
    {
        let sz = b.read_zipper();
        let mut wz = a.write_zipper();
        wz.meet_into(&sz, false);
    }
    emit("algebra/meet_val_absent", dump(&a));

    // The SAME boundary but on a DENSE node, which is the only place `CoFreeEntry` pairs are
    // subtracted/met field-by-field. The two fixtures above use a single 2-byte key, which
    // path-compresses to a LineListNode and never enters that code at all — a fixture that cannot
    // reach the branch cannot catch the bug in it. 300 flat 2-byte keys force a DenseByteNode root
    // whose entry for 'a' has CHILDREN BUT NO VALUE, while `b` has a VALUE at "a" and no children.
    let keys: Vec<String> = (0..300)
        .map(|i: usize| format!("{}{}",
            (b'a' + (i / 26) as u8) as char,
            (b'a' + (i % 26) as u8) as char))
        .collect();
    let kr: Vec<&str> = keys.iter().map(|s| s.as_str()).collect();

    let mut a = mk(&kr);
    let b = mk(&["a"]);
    {
        let sz = b.read_zipper();
        let mut wz = a.write_zipper();
        wz.subtract_into(&sz, false);
    }
    emit("algebra/subtract_dense_val_absent", dump(&a));

    let mut a = mk(&kr);
    let b = mk(&["a"]);
    {
        let sz = b.read_zipper();
        let mut wz = a.write_zipper();
        wz.meet_into(&sz, false);
    }
    emit("algebra/meet_dense_val_absent", dump(&a));

    // ---- prefix ops ----------------------------------------------------------
    // The shape that made pathmap_prefix_ops.jl assert the wrong path: an insert
    // through write_zipper_at_path(b"foo:") lands the prefix INSIDE that subtree.
    let mut m = mk(&["foo:bar"]);
    {
        let mut wz = m.write_zipper_at_path(b"foo:");
        wz.insert_prefix(b"ns:");
    }
    emit("prefix/insert_prefix_at_foo", dump(&m));

    let mut m = mk(&["foo:bar", "foo:baz"]);
    {
        let mut wz = m.write_zipper_at_path(b"foo:");
        wz.remove_prefix(1);
    }
    emit("prefix/remove_prefix_at_foo", dump(&m));

    // remove_prefix is a faithful 3-liner upstream (write_zipper.rs:1866): capture the focus
    // subtrie, `ascend(n)`, graft it back. The map is UNCHANGED above only because
    // `WriteZipperCore::ascend` CLAMPS at the zipper's own root — `at_root()` is
    // `prefix_buf.len() <= origin_path.len()` (:1002), and a write zipper created AT `foo:`
    // is already at its origin. The RETURN VALUE is the direct observable of that clamp.
    let mut m = mk(&["foo:bar", "foo:baz"]);
    let ret_at_origin = {
        let mut wz = m.write_zipper_at_path(b"foo:");
        wz.remove_prefix(1)
    };
    emit("prefix/remove_prefix_ret_at_origin", format!("{}", ret_at_origin));

    // CONTROL: the same removal from a zipper rooted at the MAP root, descended to `foo:`,
    // is BELOW its origin — so ascend may move and the removal must actually happen.
    // This is what stops a clamp fix from over-correcting into "ascend never moves".
    let mut m = mk(&["foo:bar", "foo:baz"]);
    let ret_below_origin = {
        let mut wz = m.write_zipper();
        wz.descend_to(b"foo:");
        wz.remove_prefix(1)
    };
    emit("prefix/remove_prefix_below_origin", dump(&m));
    emit("prefix/remove_prefix_below_origin_ret", format!("{}", ret_below_origin));

    // MORK's test/integration/pathmap_prefix_ops.jl "remove_prefix — full ascent to root"
    // asserts that stripping the WHOLE origin from a zipper rooted at `pre:` succeeds and
    // returns true. That is the at-origin case again, just with n == origin length. Pinned
    // here rather than argued by analogy with the n=1 case above.
    let mut m = mk(&["pre:alpha", "pre:beta"]);
    let ret_full_ascent = {
        let mut wz = m.write_zipper_at_path(b"pre:");
        wz.remove_prefix(4)
    };
    emit("prefix/remove_prefix_full_ascent_at_origin", dump(&m));
    emit("prefix/remove_prefix_full_ascent_at_origin_ret", format!("{}", ret_full_ascent));

    // OVER-ASCENT. `at_root()` alone does not bound a single step: upstream caps each jump with
    // `excess_key_len()` (write_zipper.rs:1048), whose fallback is `origin_path.len()`
    // (:2666-2667) — "the number of chars that can be LEGALLY ascended". `node_key_start()`
    // (:2650) falls back to `root_key_start` instead, so capping by `node_key().len()` lets a
    // SINGLE jump truncate straight past the origin even when the at_root check is correct.
    // Here the focus sits 3 bytes below a 4-byte origin and we ask for 5: upstream clamps to the
    // origin and returns false, so the subsequent write lands AT `foo:`.
    let mut m = mk(&["foo:bar"]);
    let ret_over = {
        let mut wz = m.write_zipper_at_path(b"foo:");
        wz.descend_to(b"bar");
        let r = wz.ascend(5);
        wz.set_val(());
        r
    };
    emit("ascend/over_ascend_ret", format!("{}", ret_over));
    emit("ascend/over_ascend_then_setval", dump(&m));

    // ---- deep / shared structure --------------------------------------------
    let deep: Vec<String> = (0..8).map(|i| format!("{}{}", "d".repeat(12), i)).collect();
    let refs: Vec<&str> = deep.iter().map(|s| s.as_str()).collect();
    emit("deep/long_common_prefix", dump(&mk(&refs)));

    let mut a = mk(&["s:1", "s:2"]);
    let snapshot = a.clone();
    a.set_val_at(b"s:3", ());
    emit("cow/source_after_clone_write", dump(&snapshot));
    emit("cow/target_after_clone_write", dump(&a));
}
