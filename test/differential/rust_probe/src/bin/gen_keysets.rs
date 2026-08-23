// Dumps the KEY SETS that upstream's pathmap_algebra_differential.rs generators produce, so the
// Julia port of those generators can be checked against them rather than assumed equal.
use std::collections::BTreeSet;
type KeySet = BTreeSet<Vec<u8>>;
const FIXED_WIDTH_KEYS: u64 = 72;

fn next_u64(state: &mut u64) -> u64 {
    *state = state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
    *state
}
fn fixed_width_set(seed: u64, salt: u64) -> KeySet {
    let mut state = seed ^ salt;
    let mut keys = KeySet::new();
    for ordinal in 0..FIXED_WIDTH_KEYS {
        let mut key = vec![0_u8; 8];
        for byte in &mut key { *byte = (next_u64(&mut state) >> 32) as u8; }
        key[0] ^= ordinal as u8;
        keys.insert(key);
    }
    keys
}
fn prefix_heavy_set(seed: u64, salt: u64) -> KeySet {
    let mut state = seed ^ salt;
    let mut keys = KeySet::new();
    if next_u64(&mut state) & 7 == 0 { keys.insert(Vec::new()); }
    for index in 0..48_u8 {
        let length = (next_u64(&mut state) % 9) as usize;
        let mut key = Vec::with_capacity(length);
        for position in 0..length {
            let selector = next_u64(&mut state);
            key.push(match selector % 5 {
                0 => index,
                1 => position as u8,
                2 => (selector >> 32) as u8,
                3 => b'a' + (selector % 7) as u8,
                _ => 0xff_u8.wrapping_sub(index),
            });
        }
        keys.insert(key.clone());
        if key.len() > 1 && index % 3 == 0 { keys.insert(key[..key.len()-1].to_vec()); }
        if index % 7 == 0 { let mut k = key.clone(); k.extend_from_slice(&[0, index]); keys.insert(k); }
    }
    keys
}
fn dump(name: &str, ks: &KeySet) {
    let mut hex: Vec<String> = ks.iter().map(|k| k.iter().map(|b| format!("{b:02x}")).collect::<String>()).collect();
    hex.sort();
    println!("{name}\t{}\t{}", ks.len(), hex.join(","));
}
fn main() {
    for seed in [0u64, 10, 44, 77, 287] {
        dump(&format!("fixed/{seed}"),  &fixed_width_set(seed, 0x243f_6a88_85a3_08d3));
        dump(&format!("heavy/{seed}"),  &prefix_heavy_set(seed, 0x082e_fa98_ec4e_6c89));
        dump(&format!("heavyA/{seed}"), &prefix_heavy_set(seed, 0x243f_6a88_85a3_08d3));
    }
}
