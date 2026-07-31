//! DIFFERENTIAL FUZZER — ground-truth generator.
//!
//! WHY THIS EXISTS. The hand-written scenarios in `gen_expected.rs` found 9 real divergences,
//! but they only find what someone thought to write down: 12 scenarios added on 2026-07-27/28
//! yielded 4 defects, a hit rate that says the remaining population is nowhere near drained.
//! Hand-authoring cannot finish. This generates random operation programs instead.
//!
//! HOW IT STAYS HONEST. The program is generated ONCE, here, and SERIALIZED to a script. Both
//! engines then *interpret the same script*. Nothing depends on Julia and Rust sharing a PRNG,
//! an iteration order, or a hash — reproducing a random sequence on two runtimes is exactly the
//! kind of assumption that has burned this project before, so it is designed out rather than
//! tested for.
//!
//! VALUE TYPE IS `()`, DELIBERATELY. PathMap's Julia port carries a DOCUMENTED, intentional
//! divergence on integer lattices (src/core/Ring.jl, audit 2026-06-02): upstream tags
//! `impl Lattice for u64` and friends `//GOAT trash` (pjoin/pmeet just return Identity(SELF)),
//! and our port implements the *intended* max/min algebra instead. Fuzzing with u64 values would
//! therefore report a by-design divergence on essentially every value merge and bury real
//! findings. `impl Lattice for ()` is bit-exact across both, so unit values keep the signal clean.
//! LIMITATION, stated rather than hidden: this fuzzer exercises value PRESENCE/ABSENCE (which is
//! what the whole `graft_root_vals` family turns on) but NOT value-payload algebra.
//!
//! Regenerate:
//!   export PATH="$HOME/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin:$PATH"
//!   cargo run --release --bin gen_fuzz -- <n_cases> <seed>
//! ⚠️ `/usr/bin/cargo` (1.75) CANNOT build this — upstream needs edition2024 + rustc >= 1.89, and
//! `/usr/bin/rustc` shadows the rustup toolchain unless PATH is set as above.
use pathmap::PathMap;
use pathmap::zipper::*;
use std::fmt::Write as _;

/// xorshift64*. Self-contained so the generator needs no rand dep and is reproducible forever.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545F4914F6CDD1D)
    }
    fn below(&mut self, n: usize) -> usize { (self.next() % (n as u64)) as usize }
    fn chance(&mut self, pct: usize) -> bool { self.below(100) < pct }
}

/// Tiny alphabet on purpose: short keys over few symbols maximise shared prefixes, mid-edge
/// splits and sibling collisions — the structures where trie ports actually break. `:` is
/// included because MORK's real paths are colon-delimited.
const ALPHABET: &[u8] = b"ab:";

fn rand_key(r: &mut Rng) -> String {
    let len = 1 + r.below(4);
    (0..len).map(|_| ALPHABET[r.below(ALPHABET.len())] as char).collect()
}

fn rand_keys(r: &mut Rng, max: usize) -> Vec<String> {
    let n = r.below(max + 1);
    let mut v: Vec<String> = (0..n).map(|_| rand_key(r)).collect();
    v.sort();
    v.dedup();
    v
}

/// One generated program. Serialised verbatim into the case file so the Julia side reads
/// exactly what Rust executed.
struct Case {
    a_keys: Vec<String>,
    a_rootval: bool,
    s_keys: Vec<String>,
    s_rootval: bool,
    origin: String, // "-" = map root
    ops: Vec<String>,
}

fn gen_case(r: &mut Rng) -> Case {
    let a_keys = rand_keys(r, 5);
    let s_keys = rand_keys(r, 3);
    // Bias the origin toward a prefix of an existing key — a zipper rooted mid-trie is where
    // the origin/at_root/excess_key_len family of bugs lives.
    let origin = if r.chance(30) || a_keys.is_empty() {
        "-".to_string()
    } else {
        let k = &a_keys[r.below(a_keys.len())];
        let cut = 1 + r.below(k.len());
        k[..cut].to_string()
    };
    let n_ops = 1 + r.below(6);
    let mut ops = Vec::new();
    for _ in 0..n_ops {
        let op = match r.below(13) {
            0 => format!("DESCEND {}", rand_key(r)),
            1 => format!("ASCEND {}", r.below(5)),
            2 => "SETVAL".to_string(),
            3 => format!("REMOVEVAL {}", r.below(2)),
            4 => "GRAFTMAP".to_string(),
            5 => "JOINMAP".to_string(),
            6 => format!("MEET {}", r.below(2)),
            7 => format!("SUB {}", r.below(2)),
            8 => format!("TAKEMAP {}", r.below(2)),
            9 => format!("INSPREFIX {}", rand_key(r)),
            10 => format!("REMPREFIX {}", r.below(4)),
            11 => "RESET".to_string(),
            _ => format!("DESCEND {}", rand_key(r)),
        };
        ops.push(op);
    }
    Case { a_keys, a_rootval: r.chance(25), s_keys, s_rootval: r.chance(35), origin, ops }
}

fn script(c: &Case) -> String {
    let mut s = String::new();
    let _ = writeln!(s, "A {}", c.a_keys.join(" "));
    let _ = writeln!(s, "AROOTVAL {}", c.a_rootval as u8);
    let _ = writeln!(s, "S {}", c.s_keys.join(" "));
    let _ = writeln!(s, "SROOTVAL {}", c.s_rootval as u8);
    let _ = writeln!(s, "ORIGIN {}", c.origin);
    for op in &c.ops {
        let _ = writeln!(s, "OP {}", op);
    }
    s
}

fn mk(keys: &[String], rootval: bool) -> PathMap<()> {
    let mut m = PathMap::<()>::new();
    for k in keys {
        m.set_val_at(k.as_bytes(), ());
    }
    if rootval {
        m.set_val_at(b"", ());
    }
    m
}

/// Canonical rendering — MUST match `_dump` in run_fuzz.jl exactly.
fn dump(m: &PathMap<()>) -> String {
    let mut z = m.read_zipper();
    let mut v: Vec<String> = vec![];
    while z.to_next_val() {
        v.push(String::from_utf8_lossy(z.path()).to_string());
    }
    v.sort();
    format!("[{}] vc={}", v.join(","), m.val_count())
}

/// Execute a case, returning `trace|dump`. The TRACE matters as much as the dump: `ascend` and
/// `remove_prefix` return a bool that is the only direct observable of the origin clamp, and the
/// algebra ops return an AlgebraicStatus that callers branch on.
fn run(c: &Case) -> String {
    let mut a = mk(&c.a_keys, c.a_rootval);
    let mut trace = String::new();
    {
        let mut wz = if c.origin == "-" {
            a.write_zipper()
        } else {
            a.write_zipper_at_path(c.origin.as_bytes())
        };
        for op in &c.ops {
            let mut it = op.split(' ');
            let name = it.next().unwrap();
            let arg = it.next().unwrap_or("");
            let out: String = match name {
                "DESCEND" => { wz.descend_to(arg.as_bytes()); "-".into() }
                "ASCEND" => format!("{}", wz.ascend(arg.parse().unwrap())),
                "SETVAL" => format!("{}", wz.set_val(()).is_some()),
                "REMOVEVAL" => format!("{}", wz.remove_val(arg == "1").is_some()),
                "GRAFTMAP" => { wz.graft_map(mk(&c.s_keys, c.s_rootval)); "-".into() }
                "JOINMAP" => format!("{:?}", wz.join_map_into(mk(&c.s_keys, c.s_rootval))),
                "MEET" => {
                    let s = mk(&c.s_keys, c.s_rootval);
                    format!("{:?}", wz.meet_into(&s.read_zipper(), arg == "1"))
                }
                "SUB" => {
                    let s = mk(&c.s_keys, c.s_rootval);
                    format!("{:?}", wz.subtract_into(&s.read_zipper(), arg == "1"))
                }
                // RESTRICT is NOT emitted by the random generator (see `script()`), so adding it
                // here does not perturb the 3000-case corpus or its ratchet. It exists so that
                // `--exec` can drive hand-written scripts: `restrict` was the one full algebra op
                // with ZERO differential coverage, and it turned out to diverge.
                "RESTRICT" => {
                    let s = mk(&c.s_keys, c.s_rootval);
                    format!("{:?}", wz.restrict(&s.read_zipper()))
                }
                "TAKEMAP" => match wz.take_map(arg == "1") {
                    Some(m) => dump(&m),
                    None => "None".into(),
                },
                "INSPREFIX" => format!("{}", wz.insert_prefix(arg.as_bytes())),
                "REMPREFIX" => format!("{}", wz.remove_prefix(arg.parse().unwrap())),
                "RESET" => { wz.reset(); "-".into() }
                _ => "?".into(),
            };
            let _ = write!(trace, "{};", out);
        }
    }
    format!("{}|{}", trace, dump(&a))
}

/// Inverse of `script()` — lets this binary act as an ORACLE FOR ARBITRARY SCRIPTS, not just ones
/// it generated. That is what makes SHRINKING possible: a minimiser proposes a reduced program and
/// must be able to ask upstream what it does. Without this you can only ever diff whole random
/// cases, and a 6-op failure stays a 6-op failure.
fn parse(text: &str) -> Case {
    let mut c = Case {
        a_keys: vec![], a_rootval: false, s_keys: vec![], s_rootval: false,
        origin: "-".into(), ops: vec![],
    };
    for line in text.lines() {
        if line.is_empty() { continue }
        let mut it = line.splitn(2, ' ');
        let tag = it.next().unwrap_or("");
        let rest = it.next().unwrap_or("").trim();
        let words = || -> Vec<String> {
            rest.split(' ').filter(|s| !s.is_empty()).map(|s| s.to_string()).collect()
        };
        match tag {
            "A" => c.a_keys = words(),
            "S" => c.s_keys = words(),
            "AROOTVAL" => c.a_rootval = rest == "1",
            "SROOTVAL" => c.s_rootval = rest == "1",
            "ORIGIN" => c.origin = if rest.is_empty() { "-".into() } else { rest.to_string() },
            "OP" => c.ops.push(rest.to_string()),
            _ => {}
        }
    }
    c
}

/// `--exec <dir>`: execute every `*.txt` in <dir> and print `stem<TAB>result`. Batched over a
/// directory rather than one script per process — a shrink pass issues thousands of queries and
/// process spawn would dominate.
fn exec_dir(dir: &str) {
    let mut names: Vec<_> = std::fs::read_dir(dir)
        .expect("read exec dir")
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().map(|x| x == "txt").unwrap_or(false))
        .collect();
    names.sort();
    let mut out = String::new();
    for p in names {
        let text = std::fs::read_to_string(&p).expect("read script");
        let c = parse(&text);
        let stem = p.file_stem().unwrap().to_string_lossy().to_string();
        let _ = writeln!(out, "{}\t{}", stem, run(&c));
    }
    print!("{}", out);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(|s| s == "--exec").unwrap_or(false) {
        exec_dir(args.get(2).expect("--exec needs a directory"));
        return;
    }
    let n: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(2000);
    let seed: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(0x9E3779B97F4A7C15);

    // ONE file, not one file per case. At 3000 cases the per-file layout was 3000 git blobs and
    // 12 MB of 4 KB-block overhead for 278 KB of actual content; as a single file it is one blob,
    // which is what makes scaling the corpus again cheap.
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../fuzz");
    std::fs::create_dir_all(&dir).expect("mkdir fuzz");
    let _ = std::fs::remove_dir_all(dir.join("cases")); // drop the old per-case layout if present

    let mut r = Rng(seed);
    let mut out = String::new();
    let mut cases = String::new();
    for i in 0..n {
        let c = gen_case(&mut r);
        let _ = write!(cases, "### {:05}\n{}", i, script(&c));
        let _ = writeln!(out, "{:05}\t{}", i, run(&c));
    }
    std::fs::write(dir.join("cases.txt"), cases).expect("write cases.txt");
    print!("{}", out);
}
