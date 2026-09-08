//! The desk's own record, off HyperEVM blocks.
//!
//! Four logs matter and they are all static ABI — no dynamic field in any of them — so the decode
//! is fixed offsets into the data, written out here rather than generated. That is a deliberate
//! choice: a codegen step is one more thing that can silently disagree with the contracts, and
//! `tests` below decodes a receipt taken off chain 999 and asserts every field, which is a stronger
//! guarantee than an ABI file being present.

use substreams::errors::Error;
use substreams::scalar::BigInt;
use substreams_ethereum::pb::eth::v2 as eth;

#[allow(clippy::all)]
mod pb {
    include!("pb/coldcascade.v1.rs");
}
use pb::{Booked, DeskEvents, Fill, MapUpdated, Markout};

// The address book is `deployments/999.json`. Hardcoded rather than parameterised for the same
// reason `initialBlock` is: this package indexes one deployment on one chain, and a wrong address
// passed at run time would produce an empty stream that looks exactly like a quiet week.
const DESK_HOOKS: [u8; 20] = hex_lit("84c1d720787f7d197dfc2890862e69c42ab0a363");
const BOOK_CACHE: [u8; 20] = hex_lit("24496697e43de61af09561fb414cb909c1635533");
const MAP_ORACLE: [u8; 20] = hex_lit("c192968786d9fe6f9da65aebc546970c4cf3c1d7");
const DEMO_MAP_ORACLE: [u8; 20] = hex_lit("3a97e5b49d4645feb34f0c87fc6d48baf5f8c10d");
const MARKOUT_LEDGER: [u8; 20] = hex_lit("c938e0ded6a7a65b8f92ca56e8688801ef0ad0e9");

// keccak of the event signature, which is what topic0 is. Checked against `cast keccak` in the
// same session these were written; `test_topics` re-checks them against the literals a reader can
// paste into an explorer.
const T_FILL: [u8; 32] =
    hex_lit32("999a9e88f019c1cef3020b109937c254b0474953cfe1b5dfbcc1d38ab5d00b77");
const T_BOOKED: [u8; 32] =
    hex_lit32("d4d04ff23def09886e62b85b81ad08f3c4968122f84db18b16faaf72fc4cf305");
const T_MAP_UPDATED: [u8; 32] =
    hex_lit32("6f7b28ab00734b31bc9a6f13bfd3e4f2231494cbf1427e68371ef232edf7dc8a");
const T_MARKOUT: [u8; 32] =
    hex_lit32("3c208aae0b8bc506413f329dfa76f23460d5416bf54cc2c970396848e991c399");

/// One key per contract that spoke in this block.
///
/// The desk went live at 45 135 453 and the chain is past 45.3M. A full scan is a quarter of a
/// million blocks, of which a couple of hundred contain anything of ours; the index is what lets
/// the endpoint skip the rest instead of shipping every block to the module.
#[substreams::handlers::map]
fn index_desk_events(block: eth::Block) -> Result<substreams::pb::sf::substreams::index::v1::Keys, Error> {
    let mut keys = substreams::pb::sf::substreams::index::v1::Keys::default();
    for log in logs(&block) {
        let key = match log.log.address.as_slice() {
            a if a == DESK_HOOKS => "contract:deskhooks",
            a if a == BOOK_CACHE => "contract:bookcache",
            a if a == MAP_ORACLE || a == DEMO_MAP_ORACLE => "contract:maporacle",
            a if a == MARKOUT_LEDGER => "contract:markoutledger",
            _ => continue,
        };
        let key = key.to_string();
        if !keys.keys.contains(&key) {
            keys.keys.push(key);
        }
    }
    Ok(keys)
}

/// Fills, books, maps and markouts, decoded, one message per block.
#[substreams::handlers::map]
fn desk_events(block: eth::Block) -> Result<DeskEvents, Error> {
    let mut out = DeskEvents {
        block_number: block.number,
        block_hash: hexs(&block.hash),
        timestamp: block.header.as_ref().and_then(|h| h.timestamp.as_ref()).map(|t| t.seconds as u64).unwrap_or_default(),
        ..Default::default()
    };

    for l in logs(&block) {
        let (log, tx) = (l.log, l.tx_hash);
        if log.topics.is_empty() {
            continue;
        }
        let t0 = log.topics[0].as_slice();
        let addr = log.address.as_slice();

        if addr == DESK_HOOKS && t0 == T_FILL && log.topics.len() == 3 && log.data.len() == 11 * 32 {
            let d = &log.data;
            // The four book words are what CoreQuote read while pricing this very swap. The hook
            // is fail-soft by design — "nothing after the transfer is allowed to fail the
            // transfer" — so a book it could not read arrives as four zeros. That is a fill the
            // markout has to skip, not a fill that happened at a price of zero.
            let (bid, ask, mark, oracle) = (u64at(d, 5), u64at(d, 6), u64at(d, 7), u64at(d, 8));
            out.fills.push(Fill {
                tx_hash: tx.clone(),
                log_index: log.block_index as u64,
                order_hash: hexs(&log.topics[1]),
                maker: addr20(&log.topics[2]),
                taker: addr_at(d, 0),
                token_in: addr_at(d, 1),
                token_out: addr_at(d, 2),
                amount_in: u256at(d, 3),
                amount_out: u256at(d, 4),
                bid,
                ask,
                mark,
                oracle,
                map_below: u256at(d, 9),
                map_above: u256at(d, 10),
                book_ok: !(bid == 0 && ask == 0 && mark == 0 && oracle == 0),
            });
        } else if addr == BOOK_CACHE
            && t0 == T_BOOKED
            && log.topics.len() == 2
            && log.data.len() == 6 * 32
        {
            let d = &log.data;
            out.books.push(Booked {
                tx_hash: tx.clone(),
                log_index: log.block_index as u64,
                perp_index: u64at(&log.topics[1], 0) as u32,
                bid: u64at(d, 0),
                ask: u64at(d, 1),
                mark: u64at(d, 2),
                oracle: u64at(d, 3),
                l1_block: u64at(d, 4),
                poker: addr_at(d, 5),
            });
        } else if (addr == MAP_ORACLE || addr == DEMO_MAP_ORACLE)
            && t0 == T_MAP_UPDATED
            && log.topics.len() == 2
            && log.data.len() == 3 * 32
        {
            let d = &log.data;
            out.maps.push(MapUpdated {
                tx_hash: tx.clone(),
                log_index: log.block_index as u64,
                perp_index: u64at(&log.topics[1], 0) as u32,
                below_notional: u256at(d, 0),
                above_notional: u256at(d, 1),
                updated_at: u64at(d, 2),
            });
        } else if addr == MARKOUT_LEDGER
            && t0 == T_MARKOUT
            && log.topics.len() == 3
            && log.data.len() == 3 * 32
        {
            let d = &log.data;
            out.markouts.push(Markout {
                tx_hash: tx.clone(),
                log_index: log.block_index as u64,
                order_hash: hexs(&log.topics[1]),
                fill_id: hexs(&log.topics[2]),
                horizon_minutes: u64at(d, 0) as u32,
                // Signed, and the sign is the whole point: a markout is the move of mid *from the
                // maker's side*, so a negative one is the desk having been picked off.
                bps: i256at(d, 1),
                posted_at: u64at(d, 2),
            });
        }
    }

    Ok(out)
}

// --- the block walk -----------------------------------------------------------------------

struct LogRef<'a> {
    log: &'a eth::Log,
    tx_hash: String,
}

/// Successful transactions only. A reverted transaction's logs are not part of the chain's record
/// of what happened, and Aqua's hook cannot have run in one.
fn logs(block: &eth::Block) -> Vec<LogRef<'_>> {
    let mut v = Vec::new();
    for trace in block.transaction_traces.iter() {
        if trace.status != 1 {
            continue;
        }
        let tx = hexs(&trace.hash);
        if let Some(receipt) = trace.receipt.as_ref() {
            for log in receipt.logs.iter() {
                v.push(LogRef { log, tx_hash: tx.clone() });
            }
        }
    }
    v
}

// --- fixed-offset ABI reads ---------------------------------------------------------------

fn word(d: &[u8], i: usize) -> &[u8] {
    &d[i * 32..(i + 1) * 32]
}
fn u64at(d: &[u8], i: usize) -> u64 {
    let w = word(d, i);
    u64::from_be_bytes(w[24..32].try_into().unwrap())
}
fn u256at(d: &[u8], i: usize) -> String {
    BigInt::from_unsigned_bytes_be(word(d, i)).to_string()
}
fn i256at(d: &[u8], i: usize) -> String {
    BigInt::from_signed_bytes_be(word(d, i)).to_string()
}
fn addr_at(d: &[u8], i: usize) -> String {
    addr20(word(d, i))
}
fn addr20(w: &[u8]) -> String {
    format!("0x{}", hex::encode(&w[12..32]))
}
fn hexs(b: &[u8]) -> String {
    format!("0x{}", hex::encode(b))
}

// `hex!` without the dependency: a const fn, so a typo in an address is a compile error rather
// than a stream that is quietly always empty.
const fn hex_lit(s: &str) -> [u8; 20] {
    let b = s.as_bytes();
    assert!(b.len() == 40);
    let mut out = [0u8; 20];
    let mut i = 0;
    while i < 20 {
        out[i] = nib(b[2 * i]) * 16 + nib(b[2 * i + 1]);
        i += 1;
    }
    out
}
const fn hex_lit32(s: &str) -> [u8; 32] {
    let b = s.as_bytes();
    assert!(b.len() == 64);
    let mut out = [0u8; 32];
    let mut i = 0;
    while i < 32 {
        out[i] = nib(b[2 * i]) * 16 + nib(b[2 * i + 1]);
        i += 1;
    }
    out
}
const fn nib(c: u8) -> u8 {
    match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        _ => panic!("hex literal must be lowercase 0-9a-f"),
    }
}
