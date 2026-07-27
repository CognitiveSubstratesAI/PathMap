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
