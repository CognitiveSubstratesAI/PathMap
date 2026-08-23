// Does upstream's iter()/to_next_val yield the ROOT VALUE (the empty key)? val_count() explicitly
// counts it; the zipper walk descends first. Settles whether our port diverges or matches.
use pathmap::PathMap;
use pathmap::zipper::*;
fn main() {
    let mut m = PathMap::<()>::new();
    m.set_val_at(b"", ());
    println!("only-empty-key: val_count={}", m.val_count());
    println!("only-empty-key: iter_count={}", m.iter().count());
    let mut z = m.read_zipper();
    let mut n = 0; while z.to_next_val() { n += 1; }
    println!("only-empty-key: to_next_val_count={}", n);

    let mut m2 = PathMap::<()>::new();
    m2.set_val_at(b"", ());
    m2.set_val_at(b"ab", ());
    println!("empty-plus-ab : val_count={}", m2.val_count());
    println!("empty-plus-ab : iter_count={}", m2.iter().count());
    let keys: Vec<String> = m2.iter().map(|(k, ())| String::from_utf8_lossy(&k).to_string()).collect();
    println!("empty-plus-ab : iter_keys={keys:?}");
}
