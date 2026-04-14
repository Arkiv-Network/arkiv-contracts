use alloy_primitives::{Address, Bytes, FixedBytes, U256};
use alloy_sol_macro::sol;
use alloy_sol_types::SolValue;
use std::fmt;

// ---------------------------------------------------------------------------
// ABI type bindings (mirrors EntityHashing.sol structs)
// ---------------------------------------------------------------------------

sol! {
    struct Attribute {
        bytes32 name;
        uint8 valueType;
        bytes32[4] value;
    }

    struct Op {
        uint8 opType;
        bytes32 entityKey;
        bytes payload;
        bytes32[4] contentType;  // Mime128
        Attribute[] attributes;
        uint32 expiresAt;        // BlockNumber
        address newOwner;
    }
}

// Op type constants (from EntityHashing.sol).
pub const CREATE: u8 = 0;
pub const UPDATE: u8 = 1;
pub const EXTEND: u8 = 2;
pub const TRANSFER: u8 = 3;
pub const DELETE: u8 = 4;
pub const EXPIRE: u8 = 5;

// ---------------------------------------------------------------------------
// Scenario descriptor
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct Scenario {
    pub label: String,
    pub op_type: u8,
    pub payload_size: usize,
    pub attr_count: usize,
    pub batch_size: usize,
    pub new_block: bool,
    pub keccak_pct: u8, // 0..=100, percentage of mainnet keccak cost
    /// Pre-encoded calldata for `execute(Op[])`.
    pub calldata: Bytes,
}

impl fmt::Display for Scenario {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{:<8} | payload={:>5}B | attrs={:>2} | batch={:>2} | {} | keccak={}%",
            op_name(self.op_type),
            self.payload_size,
            self.attr_count,
            self.batch_size,
            if self.new_block { "new_block" } else { "same_blk " },
            self.keccak_pct,
        )
    }
}

fn op_name(t: u8) -> &'static str {
    match t {
        CREATE => "CREATE",
        UPDATE => "UPDATE",
        EXTEND => "EXTEND",
        TRANSFER => "TRANSFER",
        DELETE => "DELETE",
        EXPIRE => "EXPIRE",
        _ => "UNKNOWN",
    }
}

// ---------------------------------------------------------------------------
// Scenario construction
// ---------------------------------------------------------------------------

/// Build the full matrix of scenarios to profile.
pub fn build_all() -> Vec<Scenario> {
    let payload_sizes = [0, 32, 256, 1024, 4096, 16384];
    let attr_counts = [0, 1, 8, 16, 32];
    let batch_sizes = [1, 10, 50];

    let mut scenarios = Vec::new();

    // CREATE × payload × attrs × batch (keccak=100%, new_block=true)
    for &ps in &payload_sizes {
        for &ac in &attr_counts {
            for &bs in &batch_sizes {
                scenarios.push(build_create_scenario(ps, ac, bs, true, 100));
            }
        }
    }

    // UPDATE × payload × attrs (batch=1)
    for &ps in &payload_sizes {
        for &ac in &attr_counts {
            scenarios.push(build_update_scenario(ps, ac, 1, true, 100));
        }
    }

    // Fixed-cost ops (batch=1)
    for &op in &[EXTEND, TRANSFER, DELETE, EXPIRE] {
        scenarios.push(build_fixed_op_scenario(op, 1, true, 100));
    }

    // Keccak sensitivity: worst-case CREATE at different keccak costs
    for &kp in &[100, 75, 50, 25, 0] {
        scenarios.push(build_create_scenario(16384, 32, 1, true, kp));
    }

    scenarios
}

fn build_create_scenario(
    payload_size: usize,
    attr_count: usize,
    batch_size: usize,
    new_block: bool,
    keccak_pct: u8,
) -> Scenario {
    let op = make_create_op(payload_size, attr_count);
    let ops: Vec<Op> = vec![op; batch_size];
    let calldata = encode_execute(&ops);

    Scenario {
        label: format!(
            "create_p{}_a{}_b{}",
            payload_size, attr_count, batch_size
        ),
        op_type: CREATE,
        payload_size,
        attr_count,
        batch_size,
        new_block,
        keccak_pct,
        calldata,
    }
}

fn build_update_scenario(
    payload_size: usize,
    attr_count: usize,
    batch_size: usize,
    new_block: bool,
    keccak_pct: u8,
) -> Scenario {
    // UPDATE requires an existing entityKey — the profiler must CREATE first,
    // then replay with this calldata. We use a placeholder key here; the
    // profiler fills it in after deployment + creation.
    let op = make_update_op(FixedBytes::ZERO, payload_size, attr_count);
    let ops: Vec<Op> = vec![op; batch_size];
    let calldata = encode_execute(&ops);

    Scenario {
        label: format!(
            "update_p{}_a{}_b{}",
            payload_size, attr_count, batch_size
        ),
        op_type: UPDATE,
        payload_size,
        attr_count,
        batch_size,
        new_block,
        keccak_pct,
        calldata,
    }
}

fn build_fixed_op_scenario(
    op_type: u8,
    batch_size: usize,
    new_block: bool,
    keccak_pct: u8,
) -> Scenario {
    let op = make_fixed_op(op_type, FixedBytes::ZERO);
    let ops: Vec<Op> = vec![op; batch_size];
    let calldata = encode_execute(&ops);

    Scenario {
        label: format!("{}_{}", op_name(op_type).to_lowercase(), batch_size),
        op_type,
        payload_size: 0,
        attr_count: 0,
        batch_size,
        new_block,
        keccak_pct,
        calldata,
    }
}

// ---------------------------------------------------------------------------
// Op construction helpers
// ---------------------------------------------------------------------------

fn make_create_op(payload_size: usize, attr_count: usize) -> Op {
    Op {
        opType: CREATE,
        entityKey: FixedBytes::ZERO,
        payload: Bytes::from(vec![0xAB; payload_size]),
        contentType: make_mime128(),
        attributes: make_attributes(attr_count),
        expiresAt: u32::MAX, // far future
        newOwner: Address::ZERO,
    }
}

fn make_update_op(
    entity_key: FixedBytes<32>,
    payload_size: usize,
    attr_count: usize,
) -> Op {
    Op {
        opType: UPDATE,
        entityKey: entity_key,
        payload: Bytes::from(vec![0xCD; payload_size]),
        contentType: make_mime128(),
        attributes: make_attributes(attr_count),
        expiresAt: 0,
        newOwner: Address::ZERO,
    }
}

fn make_fixed_op(op_type: u8, entity_key: FixedBytes<32>) -> Op {
    Op {
        opType: op_type,
        entityKey: entity_key,
        payload: Bytes::new(),
        contentType: [FixedBytes::ZERO; 4],
        attributes: vec![],
        expiresAt: if op_type == EXTEND { u32::MAX } else { 0 },
        newOwner: if op_type == TRANSFER {
            Address::from([0x02; 20])
        } else {
            Address::ZERO
        },
    }
}

/// Encode a valid Mime128: "application/json" padded into bytes32[4].
fn make_mime128() -> [FixedBytes<32>; 4] {
    let mut slots = [FixedBytes::ZERO; 4];
    let mime = b"application/json";
    // First byte of slot 0 is the length, followed by the ASCII bytes.
    let mut buf = [0u8; 32];
    buf[0] = mime.len() as u8;
    buf[1..1 + mime.len()].copy_from_slice(mime);
    slots[0] = FixedBytes::from(buf);
    slots
}

/// Build `count` valid attributes with deterministic sorted Ident32 names.
fn make_attributes(count: usize) -> Vec<Attribute> {
    (0..count)
        .map(|i| {
            // Name: left-aligned ASCII identifier, sorted by construction.
            // "a00\0...", "a01\0...", ... "a31\0..."
            let mut name_bytes = [0u8; 32];
            let label = format!("a{:02}", i);
            name_bytes[..label.len()].copy_from_slice(label.as_bytes());
            let name = FixedBytes::from(name_bytes);

            // Value: ATTR_UINT (type 0), value is the index as uint256 in slot 0.
            let mut value = [FixedBytes::ZERO; 4];
            value[0] = FixedBytes::from(U256::from(i).to_be_bytes::<32>());

            Attribute {
                name,
                valueType: 0, // ATTR_UINT
                value,
            }
        })
        .collect()
}

// ---------------------------------------------------------------------------
// ABI encoding
// ---------------------------------------------------------------------------

/// ABI-encode `execute(Op[])` calldata.
fn encode_execute(ops: &[Op]) -> Bytes {
    // function selector: keccak256("execute((uint8,bytes32,bytes,bytes32[4],(bytes32,uint8,bytes32[4])[],uint32,address)[])")
    // We compute it at build time from the ABI. For now, use a placeholder
    // that the profiler can override if needed.
    //
    // TODO: derive selector from the artifact ABI or hardcode after computing.
    let encoded_args = ops.abi_encode();

    // Selector for execute(Op[]) — compute from artifact at runtime.
    // Placeholder: first 4 bytes will be patched by the profiler.
    let mut calldata = vec![0u8; 4];
    calldata.extend_from_slice(&encoded_args);
    Bytes::from(calldata)
}
