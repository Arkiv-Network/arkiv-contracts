use alloy::primitives::{Address, Bytes, FixedBytes, U256, keccak256};

use crate::abi::EntityRegistry;
use crate::config::Profile;

/// Represents a pre-built transaction payload for a single execute() call.
pub struct WorkloadTx {
    /// Index into the wallets vec for the sender
    pub wallet_idx: usize,
    /// ABI-encoded calldata for execute(Op[])
    pub ops: Vec<EntityRegistry::Op>,
}

/// Per-wallet state for tracking contract nonces (for entity key prediction).
pub struct WalletState {
    pub address: Address,
    /// Next contract-level nonce (EntityRegistry.nonces mapping)
    pub contract_nonce: u32,
    /// Next transaction-level nonce
    pub tx_nonce: u64,
}

/// Build the workload transactions for a given profile.
pub fn build_workload(
    profile: &Profile,
    wallet_states: &mut [WalletState],
    total_ops: u64,
    batch_size: u32,
    chain_id: u64,
    contract_addr: Address,
    current_block: u32,
) -> Vec<WorkloadTx> {
    match profile {
        Profile::CreateMinimal => build_creates(
            wallet_states,
            total_ops,
            batch_size,
            0,
            0,
            current_block,
        ),
        Profile::CreateSmall => build_creates(
            wallet_states,
            total_ops,
            batch_size,
            1024,
            5,
            current_block,
        ),
        Profile::CreateBatched => build_creates(
            wallet_states,
            total_ops,
            batch_size.max(100),
            0,
            0,
            current_block,
        ),
        Profile::Update => build_updates(
            wallet_states,
            total_ops,
            chain_id,
            contract_addr,
            current_block,
        ),
        Profile::Extend => build_extends(
            wallet_states,
            total_ops,
            chain_id,
            contract_addr,
            current_block,
        ),
        Profile::Mixed => build_mixed(
            wallet_states,
            total_ops,
            batch_size,
            chain_id,
            contract_addr,
            current_block,
        ),
    }
}

/// Build a seed phase: one CREATE per entity needed, returns predicted entity keys per wallet.
pub fn build_seed_creates(
    wallet_states: &mut [WalletState],
    entities_per_wallet: u64,
    current_block: u32,
) -> (Vec<WorkloadTx>, Vec<Vec<FixedBytes<32>>>) {
    let expires_at = current_block + 1_000_000;
    let mut txs = Vec::new();
    let keys_per_wallet: Vec<Vec<FixedBytes<32>>> = vec![Vec::new(); wallet_states.len()];

    for (w_idx, ws) in wallet_states.iter_mut().enumerate() {
        for _ in 0..entities_per_wallet {
            let op = make_create_op(0, 0, expires_at);
            // Predict the entity key: keccak256(chainId, contractAddr, owner, nonce)
            // We don't use it here but track nonces for the key prediction
            ws.contract_nonce += 1;
            txs.push(WorkloadTx {
                wallet_idx: w_idx,
                ops: vec![op],
            });
        }
    }

    // Recompute keys after seed is mined (contract nonces will match)
    // For now, we'll predict keys based on the starting nonce
    // The runner will fill these in after the seed phase executes
    (txs, keys_per_wallet)
}

fn build_creates(
    wallet_states: &mut [WalletState],
    total_ops: u64,
    batch_size: u32,
    payload_size: usize,
    num_attrs: usize,
    current_block: u32,
) -> Vec<WorkloadTx> {
    let expires_at = current_block + 1_000_000;
    let batch_size = batch_size.max(1) as u64;
    let num_txs = (total_ops + batch_size - 1) / batch_size;
    let num_wallets = wallet_states.len();
    let mut txs = Vec::with_capacity(num_txs as usize);

    for i in 0..num_txs {
        let w_idx = (i as usize) % num_wallets;
        let ops_in_batch = if i == num_txs - 1 {
            let remaining = total_ops - i * batch_size;
            remaining.min(batch_size) as u32
        } else {
            batch_size as u32
        };

        let mut ops = Vec::with_capacity(ops_in_batch as usize);
        for _ in 0..ops_in_batch {
            ops.push(make_create_op(payload_size, num_attrs, expires_at));
            wallet_states[w_idx].contract_nonce += 1;
        }

        txs.push(WorkloadTx {
            wallet_idx: w_idx,
            ops,
        });
    }

    txs
}

fn build_updates(
    wallet_states: &mut [WalletState],
    total_ops: u64,
    chain_id: u64,
    contract_addr: Address,
    _current_block: u32,
) -> Vec<WorkloadTx> {
    // For updates, we first need entities to exist.
    // The runner handles the seed phase separately.
    // Here we build UPDATE ops targeting predicted entity keys.
    let num_wallets = wallet_states.len();
    let mut txs = Vec::with_capacity(total_ops as usize);

    for i in 0..total_ops {
        let w_idx = (i as usize) % num_wallets;
        let ws = &wallet_states[w_idx];

        // Target entity key: use the nonce that corresponds to this entity
        // Entities were created in the seed phase with nonces 0..entities_per_wallet
        let entity_nonce = (i / num_wallets as u64) as u32;
        let entity_key = predict_entity_key(chain_id, contract_addr, ws.address, entity_nonce);

        let op = make_update_op(entity_key, 1024, 5);
        txs.push(WorkloadTx {
            wallet_idx: w_idx,
            ops: vec![op],
        });
    }

    txs
}

fn build_extends(
    wallet_states: &mut [WalletState],
    total_ops: u64,
    chain_id: u64,
    contract_addr: Address,
    current_block: u32,
) -> Vec<WorkloadTx> {
    let num_wallets = wallet_states.len();
    let mut txs = Vec::with_capacity(total_ops as usize);

    for i in 0..total_ops {
        let w_idx = (i as usize) % num_wallets;
        let ws = &wallet_states[w_idx];

        let entity_nonce = (i / num_wallets as u64) as u32;
        let entity_key = predict_entity_key(chain_id, contract_addr, ws.address, entity_nonce);

        // Each extend must push expiresAt further than the last
        let new_expires_at = current_block + 2_000_000 + (i as u32);
        let op = make_extend_op(entity_key, new_expires_at);
        txs.push(WorkloadTx {
            wallet_idx: w_idx,
            ops: vec![op],
        });
    }

    txs
}

fn build_mixed(
    wallet_states: &mut [WalletState],
    total_ops: u64,
    batch_size: u32,
    chain_id: u64,
    contract_addr: Address,
    current_block: u32,
) -> Vec<WorkloadTx> {
    // Mix: 50% CREATE, 25% UPDATE, 25% EXTEND
    let num_creates = total_ops / 2;
    let num_updates = total_ops / 4;
    let num_extends = total_ops - num_creates - num_updates;

    let mut all_txs = Vec::new();

    // CREATEs
    all_txs.extend(build_creates(
        wallet_states,
        num_creates,
        batch_size,
        512,
        3,
        current_block,
    ));

    // UPDATEs (target seed entities)
    all_txs.extend(build_updates(
        wallet_states,
        num_updates,
        chain_id,
        contract_addr,
        current_block,
    ));

    // EXTENDs (target seed entities)
    all_txs.extend(build_extends(
        wallet_states,
        num_extends,
        chain_id,
        contract_addr,
        current_block,
    ));

    all_txs
}

/// Predict entity key: keccak256(abi.encodePacked(chainId, contractAddr, owner, nonce))
pub fn predict_entity_key(
    chain_id: u64,
    contract_addr: Address,
    owner: Address,
    nonce: u32,
) -> FixedBytes<32> {
    let mut buf = Vec::with_capacity(64);
    buf.extend_from_slice(&U256::from(chain_id).to_be_bytes::<32>());
    buf.extend_from_slice(contract_addr.as_slice());
    buf.extend_from_slice(owner.as_slice());
    buf.extend_from_slice(&nonce.to_be_bytes());
    keccak256(&buf)
}

fn make_create_op(
    payload_size: usize,
    num_attrs: usize,
    expires_at: u32,
) -> EntityRegistry::Op {
    let payload = if payload_size > 0 {
        vec![0xABu8; payload_size]
    } else {
        vec![]
    };

    let attributes = make_attributes(num_attrs);

    EntityRegistry::Op {
        opType: 0, // CREATE
        entityKey: FixedBytes::ZERO,
        payload: Bytes::from(payload),
        contentType: "application/json".to_string(),
        attributes,
        expiresAt: expires_at,
    }
}

fn make_update_op(
    entity_key: FixedBytes<32>,
    payload_size: usize,
    num_attrs: usize,
) -> EntityRegistry::Op {
    let payload = vec![0xCDu8; payload_size];
    let attributes = make_attributes(num_attrs);

    EntityRegistry::Op {
        opType: 1, // UPDATE
        entityKey: entity_key,
        payload: Bytes::from(payload),
        contentType: "application/json".to_string(),
        attributes,
        expiresAt: 0, // unused for UPDATE
    }
}

fn make_extend_op(entity_key: FixedBytes<32>, new_expires_at: u32) -> EntityRegistry::Op {
    EntityRegistry::Op {
        opType: 2, // EXTEND
        entityKey: entity_key,
        payload: Bytes::new(),
        contentType: String::new(),
        attributes: vec![],
        expiresAt: new_expires_at,
    }
}

/// Generate sorted UINT attributes named "attr_00", "attr_01", etc.
fn make_attributes(count: usize) -> Vec<EntityRegistry::Attribute> {
    let mut attrs = Vec::with_capacity(count);
    for i in 0..count {
        let name = format!("attr_{i:02}");
        // Pad name to bytes32 (ShortString encoding: length in last byte, content left-aligned)
        let mut name_bytes = [0u8; 32];
        let name_raw = name.as_bytes();
        name_bytes[..name_raw.len()].copy_from_slice(name_raw);
        // ShortString stores length in the last byte
        name_bytes[31] = (name_raw.len() * 2) as u8;

        attrs.push(EntityRegistry::Attribute {
            name: FixedBytes::from(name_bytes),
            valueType: 0, // UINT
            fixedValue: FixedBytes::from(U256::from(i + 1).to_be_bytes::<32>()),
            stringValue: String::new(),
        });
    }
    attrs
}
