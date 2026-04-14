use crate::artifact::Artifact;
use crate::scenario::Scenario;
use alloy_primitives::{Address, TxKind, U256};
use eyre::{Result, WrapErr};
use revm::context::TxEnv;
use revm::context_interface::cfg::gas_params::{GasId, GasParams};
use revm::context_interface::result::{ExecutionResult, Output};
use revm::database::InMemoryDB;
use revm::state::AccountInfo;
use revm::{Context, ExecuteCommitEvm, InspectCommitEvm, MainBuilder, MainContext};
use revm_inspectors::opcode::OpcodeGasInspector;
use std::collections::HashMap;
use std::sync::Arc;

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

const DEPLOYER: Address = Address::new([0x01; 20]);
const CALLER: Address = Address::new([0x02; 20]);

// ---------------------------------------------------------------------------
// Gas schedule configuration
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct GasSchedule {
    pub name: String,
    /// Overrides applied to the default GasParams table.
    pub overrides: Vec<(GasId, u64)>,
}

impl GasSchedule {
    pub fn mainnet() -> Self {
        Self {
            name: "Mainnet (default)".to_string(),
            overrides: vec![],
        }
    }

    pub fn optimised() -> Self {
        Self {
            name: "Optimised (custom chain)".to_string(),
            overrides: vec![
                // Calldata: 1 gas per non-zero byte (was 16)
                (GasId::tx_token_non_zero_byte_multiplier(), 1),
                (GasId::tx_token_cost(), 1),
                // Disable EIP-7623 calldata floor
                (GasId::tx_floor_cost_per_token(), 0),
                (GasId::tx_floor_cost_base_gas(), 0),
                // Intrinsic tx cost: 1000 (was 21000)
                (GasId::tx_base_stipend(), 1000),
                // Linear memory only (disable quadratic term)
                (GasId::memory_quadratic_reduction(), u64::MAX),
                // Keccak: 1 gas per word (was 6)
                (GasId::keccak256_per_word(), 1),
            ],
        }
    }

    fn apply(&self, base: &GasParams) -> GasParams {
        if self.overrides.is_empty() {
            return base.clone();
        }
        let mut table = *base.table();
        for &(id, value) in &self.overrides {
            table[id.as_usize()] = value;
        }
        GasParams::new(Arc::new(table))
    }
}

impl std::fmt::Display for GasSchedule {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.name)?;
        if !self.overrides.is_empty() {
            write!(f, " [")?;
            for (i, (id, val)) in self.overrides.iter().enumerate() {
                if i > 0 {
                    write!(f, ", ")?;
                }
                write!(f, "{}={}", id.name(), val)?;
            }
            write!(f, "]")?;
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

#[derive(Clone, serde::Serialize)]
pub struct ProfileResult {
    pub label: String,
    pub scenario: String,
    pub schedule: String,
    /// Total transaction gas: max(overhead + execution, floor).
    pub total_gas: u64,
    /// Execution gas only (sum of all opcode costs tracked by inspector).
    pub execution_gas: u64,
    /// Non-execution overhead (intrinsic tx cost + calldata gas).
    pub overhead_gas: u64,
    /// EIP-7623 floor gas (0 if disabled).
    pub floor_gas: u64,
    pub opcode_gas: HashMap<String, OpcodeStats>,
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

pub fn run(
    artifact: &Artifact,
    scenario: &Scenario,
    schedule: &GasSchedule,
) -> Result<ProfileResult> {
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
    let result = execute_with_inspector(&mut db, contract_addr, scenario, schedule)?;

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
    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| cfg.tx_gas_limit_cap = Some(u64::MAX))
        .with_db(db)
        .build_mainnet();

    let tx = TxEnv {
        caller: DEPLOYER,
        kind: TxKind::Create,
        data: artifact.bytecode.clone(),
        gas_limit: u64::MAX,
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
    schedule: &GasSchedule,
) -> Result<ProfileResult> {
    let inspector = OpcodeGasInspector::new();
    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| {
            cfg.tx_gas_limit_cap = Some(u64::MAX);
            cfg.gas_params = schedule.apply(&cfg.gas_params);
        })
        .with_db(db)
        .build_mainnet_with_inspector(inspector);

    let tx = TxEnv {
        caller: CALLER,
        kind: TxKind::Call(contract),
        data: scenario.calldata.clone(),
        gas_limit: u64::MAX,
        value: U256::ZERO,
        gas_price: 0,
        ..Default::default()
    };

    // Compute initial gas (intrinsic + calldata) from the gas schedule.
    let initial = evm.ctx.cfg.gas_params
        .initial_tx_gas(&scenario.calldata, false, 0, 0, 0);
    let overhead_gas = initial.initial_total_gas;
    let floor_gas = initial.floor_gas;

    let result = evm
        .inspect_tx_commit(tx)
        .wrap_err("profiled tx failed")?;

    match &result {
        ExecutionResult::Revert { gas, output, .. } => {
            eprintln!("  WARN: tx reverted (gas={}, output={})", gas.tx_gas_used(), output);
        }
        ExecutionResult::Halt { gas, reason, .. } => {
            eprintln!("  WARN: tx halted ({:?}, gas={})", reason, gas.tx_gas_used());
        }
        _ => {}
    }

    // Extract per-opcode gas from the inspector.
    let inspector = evm.into_inspector();
    let execution_gas: u64 = inspector.opcode_gas().values().sum();
    let total_gas = overhead_gas + execution_gas;
    // If EIP-7623 floor applies, the transaction costs at least floor_gas.
    let total_gas = total_gas.max(floor_gas);

    let mut opcode_gas = HashMap::new();
    for (opcode, (count, gas)) in inspector.opcode_iter() {
        let pct = if execution_gas > 0 {
            (gas as f64 / execution_gas as f64) * 100.0
        } else {
            0.0
        };
        opcode_gas.insert(
            format!("{}", opcode),
            OpcodeStats { count, gas, pct },
        );
    }

    Ok(ProfileResult {
        label: scenario.label.clone(),
        scenario: scenario.to_string(),
        schedule: schedule.to_string(),
        total_gas,
        execution_gas,
        overhead_gas,
        floor_gas,
        opcode_gas,
    })
}
