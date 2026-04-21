# Arkiv Node — Status & Architecture

## Current State

The Rust workspace comprises five crates that together form a complete chain indexing pipeline:

```
EntityRegistry (Solidity)
       |
       v  [genesis predeploy]
arkiv-genesis ──> revm deployment ──> chain spec
       |
       v
arkiv-node ──> reth ExEx ──> filters registry txs ──> arkiv-store
       |                                                    |
       v                                                    v
  CLI (arkiv-cli)                                  LoggingStore (debug)
  submits operations                               future: JSON-RPC store
  queries state
```

### Crate Summary

| Crate | Purpose | LOC | Status |
|-------|---------|-----|--------|
| **arkiv-bindings** | Solidity ABI types via `sol!` macro | 243 | Stable |
| **arkiv-store** | Storage trait + decode utilities + LoggingStore | 272 | Stable |
| **arkiv-genesis** | Genesis generation with revm-deployed EntityRegistry | 243 | Stable |
| **arkiv-node** | Reth node + ExEx thin filter | 135 | Functional |
| **arkiv-cli** | Transaction submission + queries + history | 353 | Feature-complete |

### What Works End-to-End

1. `just node-dev` boots a reth dev node with EntityRegistry predeployed at `0x4200...0042`
2. The ExEx starts and subscribes to chain notifications
3. `just cli create` submits an entity operation, gets back tx hash + entity key + entity hash
4. `just cli query --key <key>` reads the on-chain commitment
5. `just cli hash` returns the current changeset hash
6. `just cli history` walks the block linked list printing the changeset hash chain
7. `just spam 10` loops entity creates for load testing
8. LoggingStore logs decoded operations when the ExEx forwards matching transactions

---

## ExEx Architecture

### How reth ExEx Works

An Execution Extension (ExEx) is reth's plugin system for deriving custom state from the canonical chain. The lifecycle:

1. **Registration** — `builder.install_exex("name", |ctx| ...)` during node setup
2. **Launch** — The ExEx Manager spawns each ExEx as a background task after the node boots
3. **Notification stream** — As the engine finalizes blocks, it produces `ExExNotification` variants:
   - `ChainCommitted { new }` — New canonical blocks
   - `ChainReorged { old, new }` — Reorg: undo `old`, apply `new`
   - `ChainReverted { old }` — Rollback
4. **Backpressure** — The manager tracks each ExEx's progress via `FinishedHeight` events. Data isn't pruned until all ExExes have acknowledged it
5. **WAL** — Notifications are persisted to a write-ahead log. On crash recovery, unacknowledged notifications are replayed

### Arkiv ExEx Design: Thin Filter

The arkiv ExEx does minimal work — it's a filter, not a decoder:

```
Chain notification
  → iterate blocks + receipts
  → for each tx: is tx.to == ENTITY_REGISTRY_ADDRESS?
    → yes: extract calldata + filtered logs → RegistryTransaction
    → no: skip
  → if any found: wrap in RegistryBlock → store.handle_commit()
  → signal FinishedHeight
```

The ExEx passes raw calldata and logs to the Storage backend. Each store decides how much to decode:

- **LoggingStore** calls `decode_registry_transaction()` to fully parse operations, entity records, MIME types, and attributes — then logs everything via tracing
- **JSON-RPC store** (future) would serialize the raw `RegistryBlock` and forward it to an external database service, offloading all decode compute

This separation means the ExEx stays fast regardless of how expensive downstream processing becomes.

### Key Types

```rust
// What the ExEx produces (minimal, raw)
pub struct RegistryBlock {
    pub block_number: u64,
    pub transactions: Vec<RegistryTransaction>,
}

pub struct RegistryTransaction {
    pub tx_hash: B256,
    pub calldata: Bytes,
    pub logs: Vec<Log>,
    pub success: bool,
}

// What the Storage trait receives
pub trait Storage: Send + Sync + 'static {
    fn handle_commit(&self, block: &RegistryBlock) -> Result<()>;
    fn handle_revert(&self, block_number: u64) -> Result<()>;
}
```

### Generic Bound

The ExEx function is bound to `EthPrimitives` concretely rather than being fully generic:

```rust
pub async fn arkiv_exex<
    Node: FullNodeComponents<Types: NodeTypes<Primitives = EthPrimitives>>,
>
```

This matches reth's own examples and avoids trait bound gymnastics. Since this is an Ethereum-specific indexer, full generic flexibility isn't needed. If the project moves to op-reth (Optimism), the bound changes to `OpPrimitives`.

---

## Genesis System

`arkiv-genesis` bridges Foundry and reth:

1. **Build time** (`build.rs`): Runs `forge build` if Solidity sources changed, extracts creation bytecode from the Foundry artifact, embeds it as a Rust const
2. **Runtime** (`deploy.rs`): Spins up revm with the target chain_id, executes the creation bytecode, extracts runtime bytecode with correctly populated immutables (GENESIS_BLOCK=0, EIP-712 domain separator for the target chain)
3. **Genesis assembly** (`lib.rs`): Combines runtime bytecode + prefunded accounts + all-forks-active chain config into an `alloy_genesis::Genesis`
4. **Node integration** (`main.rs`): Converts Genesis to ChainSpec, overrides the builder's chain config before launch

The genesis is generated in-memory — no file on disk needed. `just print-genesis` writes it to stdout for inspection.

### Immutable Note

The EntityRegistry has 8 immutable values baked into bytecode by the constructor (EIP-712 fields, GENESIS_BLOCK). The revm deployment handles most correctly, but `_cachedThis` will be the revm deploy address, not `0x4200...0042`. OZ's EIP-712 implementation has a runtime fallback that recomputes the domain separator when `address(this) != _cachedThis`, so this is functionally correct at a small gas overhead.

---

## Potential Improvements

### Short Term

- **Verify block production** — The `launch_with_debug_capabilities()` fix for dev mode mining hasn't been confirmed end-to-end yet
- **ExEx error resilience** — Currently if `store.handle_commit()` fails, the ExEx stops. Consider whether failures should be logged and skipped to avoid blocking the node
- **Storage trait async** — When the JSON-RPC store is implemented, the trait may need to become async. For now sync is simpler and the ExEx context is async so `spawn_blocking` is available

### Medium Term

- **JSON-RPC Storage backend** — Implement a store that forwards `RegistryBlock` to an external database service via JSON-RPC. The DB service handles all decoding and persistence. This is the production architecture
- **Solidity interface (IEntityRegistry.sol)** — Extract a Solidity interface from EntityRegistry.sol. Use it as the single source of truth for both Solidity consumers and Rust bindings (via `sol!` with file path)
- **ExEx state checkpoint** — Persist the last processed block number so the ExEx can resume from where it left off after restart, rather than replaying from genesis. The reth WAL handles crash recovery, but a checkpoint avoids reprocessing on clean restart
- **Batch decode optimization** — The LoggingStore currently decodes each transaction independently. For high throughput, batch decoding could amortize allocation overhead

### Longer Term

- **op-reth migration** — The plan targets Optimism L2 eventually. This requires:
  - Changing `EthereumNode` to the OP node type
  - Updating the `EthPrimitives` bound to `OpPrimitives`
  - Adjusting genesis for L2 chain config (system transactions, L1 data fees)
  - The crate separation (arkiv-store has no reth deps) means most code stays unchanged
- **Off-chain verification** — Tooling to replay the changeset hash chain from indexed data and verify it matches the on-chain `changeSetHash()`. This is the core value proposition of the system
- **Multi-contract support** — The ExEx filter currently hardcodes `ENTITY_REGISTRY_ADDRESS`. If additional contracts are added (e.g., governance, access control), the filter should become configurable
- **Metrics and monitoring** — Add Prometheus metrics to the ExEx: blocks processed, transactions filtered, decode errors, processing latency. Reth already has a metrics infrastructure that ExExes can hook into

---

## Development Workflow

```bash
# Dev environment
direnv allow                    # Load nix dev shell

# Solidity
just build                      # Compile contracts
just test                       # Run Solidity tests
just lint                       # Lint contracts

# Rust
cargo check --workspace         # Type check all crates
cargo test --workspace          # Run all Rust tests

# Integration
just node-dev                   # Boot dev node (terminal 1)
just cli create --expires-in 1h # Submit operation (terminal 2)
just cli history                # Inspect changeset chain
just spam 20                    # Load test

# Utilities
just print-genesis              # Inspect genesis JSON
just cli balance                # Check dev account
just cli hash                   # Current changeset hash
```
