use crate::artifact::Artifact;
use crate::scenario::Scenario;
use alloy_primitives::{Address, TxKind, U256};
use eyre::{Result, WrapErr};
use revm::context::TxEnv;
use revm::context_interface::result::{ExecutionResult, Output};
use revm::database::InMemoryDB;
use revm::state::AccountInfo;
use revm::{Context, ExecuteCommitEvm, InspectCommitEvm, MainBuilder, MainContext};
use revm_inspectors::opcode::OpcodeGasInspector;
use std::collections::HashMap;

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

const DEPLOYER: Address = Address::new([0x01; 20]);
const CALLER: Address = Address::new([0x02; 20]);

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

#[derive(Clone, serde::Serialize)]
pub struct ProfileResult {
    pub label: String,
    pub scenario: String,
    pub total_gas: u64,
    pub opcode_gas: HashMap<String, OpcodeStats>,
    pub keccak_pct_config: u8,
}

#[derive(Clone, serde::Serialize)]
pub struct OpcodeStats {
    pub count: u64,
    pub gas: u64,
    pub pct: f64,
}

// ---------------------------------------------------------------------------
// Profiler
// ---------------------------------------------------------------------------

pub fn run(artifact: &Artifact, scenario: &Scenario) -> Result<ProfileResult> {
    // 1. Set up in-memory state and deploy the contract.
    let mut db = InMemoryDB::default();
    fund_account(&mut db, DEPLOYER);
    fund_account(&mut db, CALLER);

    let contract_addr = deploy(&mut db, artifact)?;

    // 2. If the scenario needs pre-existing entities (UPDATE, EXTEND, etc.),
    //    create them first in a setup transaction.
    if scenario.op_type != crate::scenario::CREATE {
        setup_entities(&mut db, contract_addr, scenario)?;
    }

    // 3. Execute the profiled transaction with OpcodeGasInspector.
    let result = execute_with_inspector(&mut db, contract_addr, scenario)?;

    Ok(result)
}

fn fund_account(db: &mut InMemoryDB, addr: Address) {
    let info = AccountInfo {
        balance: U256::from(1_000_000u64) * U256::from(10u64).pow(U256::from(18)),
        nonce: 0,
        ..Default::default()
    };
    db.insert_account_info(addr, info);
}

fn deploy(db: &mut InMemoryDB, artifact: &Artifact) -> Result<Address> {
    let mut evm = Context::mainnet().with_db(db).build_mainnet();

    let tx = TxEnv {
        caller: DEPLOYER,
        kind: TxKind::Create,
        data: artifact.bytecode.clone(),
        gas_limit: 30_000_000,
        value: U256::ZERO,
        gas_price: 0,
        ..Default::default()
    };

    let result = evm
        .transact_commit(tx)
        .wrap_err("deploy transaction failed")?;

    match result {
        ExecutionResult::Success {
            output: Output::Create(_, Some(addr)),
            ..
        } => Ok(addr),
        other => Err(eyre::eyre!("deploy did not return an address: {:?}", other)),
    }
}

fn setup_entities(
    _db: &mut InMemoryDB,
    _contract: Address,
    _scenario: &Scenario,
) -> Result<()> {
    // TODO: For UPDATE/EXTEND/TRANSFER/DELETE/EXPIRE scenarios, execute a
    // CREATE transaction first so the entity exists in storage. Then patch
    // the scenario's calldata with the real entityKey.
    Ok(())
}

fn execute_with_inspector(
    db: &mut InMemoryDB,
    contract: Address,
    scenario: &Scenario,
) -> Result<ProfileResult> {
    let inspector = OpcodeGasInspector::new();
    let mut evm = Context::mainnet()
        .with_db(db)
        .build_mainnet_with_inspector(inspector);

    let tx = TxEnv {
        caller: CALLER,
        kind: TxKind::Call(contract),
        data: scenario.calldata.clone(),
        gas_limit: 30_000_000,
        value: U256::ZERO,
        gas_price: 0,
        ..Default::default()
    };

    let result = evm
        .inspect_tx_commit(tx)
        .wrap_err("profiled tx failed")?;

    let total_gas = match &result {
        ExecutionResult::Success { gas, .. } => gas.tx_gas_used(),
        ExecutionResult::Revert {
            gas, output, ..
        } => {
            eprintln!("  WARN: tx reverted (gas={}, output={})", gas.tx_gas_used(), output);
            gas.tx_gas_used()
        }
        ExecutionResult::Halt {
            gas, reason, ..
        } => {
            eprintln!("  WARN: tx halted ({:?}, gas={})", reason, gas.tx_gas_used());
            gas.tx_gas_used()
        }
    };

    // Extract per-opcode gas from the inspector.
    let inspector = evm.into_inspector();
    let mut opcode_gas = HashMap::new();
    for (opcode, (count, gas)) in inspector.opcode_iter() {
        let pct = if total_gas > 0 {
            (gas as f64 / total_gas as f64) * 100.0
        } else {
            0.0
        };
        opcode_gas.insert(
            format!("{:?}", opcode),
            OpcodeStats { count, gas, pct },
        );
    }

    Ok(ProfileResult {
        label: scenario.label.clone(),
        scenario: scenario.to_string(),
        total_gas,
        opcode_gas,
        keccak_pct_config: scenario.keccak_pct,
    })
}
