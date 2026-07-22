# Arkiv Stages — Journey to the Target Architecture

Status: **draft — for discussion**.

Target architecture (sponsor decision): option B of
`arkiv-state-accounts.md` — Golem DB manages the unified state
(entities, indexes, **and accounts**), with the corresponding changes
to RPC API, block building, and tx-pool management. This document lays
out the staged journey from the current state to that target.

## Principles

- **Freeze the surface first, migrate storage behind it.** The ABI/SDK
  surface (ops, types, views, events, errors — *and their semantics*)
  freezes as early as possible; every later stage swaps storage
  underneath without observable change.
- **Resets instead of migrations.** Testnets reset at stage
  boundaries; state layout is not a promise, so no live-migration
  code is ever written. The ABI is the promise.
- **Conformance anchor.** Golden test vectors generated against the
  stage-1 surface are the acceptance gate for every later stage: same
  vectors, same results ⇒ the storage swap moved no semantics.
- **B before mainnet.** Stage transitions are cheap only while resets
  are available. Mainnet launches on the target architecture (stage 3
  or later); launching earlier would turn the remaining journey into a
  hard fork with live state migration.

## Stages

| stage | net / target date | content |
|---|---|---|
| 0 | testnet-0 (July 2026, current) | everything in reth world state — entities, indexes, accounts; old attribute types and entity ops |
| 1 | testnet-1 (mid-August 2026) | **ABI/SDK freeze**: new attribute types and entity ops (`create(expiresAt, minLifetime, creationFlags, …)`, `extend_to`, tombstone rules) and the new expiry *semantics* — still entirely on reth world state (pre option A). Expiry purging via training wheels (below) |
| 2 | public testnet (~Sept 2026) | Golem DB enters the data plane: entities + indexes behind the storage interface, ideally accounts as well (option B), if time permits. Fallback: accounts stay in reth (option A), `GetDBHash()` anchor write; Orthogonal: purge training wheels replaced by protocol purge functionality |
| 3 | testnet reset | **B cutover at genesis**: Golem DB authoritative for accounts; reth account-state provider swapped (tx pool, pool maintenance, reorg revalidation, account RPCs); `mint` becomes an engine entry point behind the gateway (deposits only) |
| 4 | later | withdrawals (`burn`), shadow machinery removed, optional `stateRoot = GetDBHash()` header flip |

Stage-1 freeze scope: signatures **and semantics**. In particular the
expiry contract is final from stage 1 on: expired entities are
invisible to every query and reject every op from the expiry block on;
there is no expiry or purge event; apps track the indexed `$expiresAt`
(SDK-synthesized notifications). Later stages change only *who removes
the bytes*.

## Training wheels: operator GC bot (stage 1 only)

Protocol-managed purge (system call, dedicated budget — see
`arkiv-engine.md` §5) unlikely to be ready by mid-August. Interim: physical
removal by a **permissioned operator bot**. This is possible without
breaking the freeze because purge is *unobservable by design* — the
frozen surface never promises who deletes expired data.

| aspect | rule |
|---|---|
| semantics | the expiry predicate ships in stage 1 regardless — the bot substitutes only the mechanical half (physical removal) |
| write path | `purgeExpired(keys[])` — permissioned (operator key only), **off the frozen ABI** (not an `execute()` op, not in the SDK), emits **no events** (in particular not `EntityDeleted` — offchain replicas replay that as user deletion) |
| validation | per-key: engine revalidates `expiresAt <= current`, skips nonexistent/non-expired keys, never reverts the batch — bot-list staleness is harmless (wasted gas, never wrong state) |
| discovery | node-side `getExpired(limit)` reading the `$expiresAt` index (node RPC namespace or client view; not in the SDK). No-resurrection makes the expired set monotone per chain, so results only go stale by being already purged |
| rehearsal | bot processes in canonical purge order (ascending `$expiresAt`, key order within) with a self-imposed per-tx budget — its selection logic migrates into the engine's purge, and its operational data feeds the open purge-budget calibration |
| sunset | removed at the stage-2 reset, once protocol purge is live; both functions carry a "training wheels" comment. Deliberately **not** the superseded GC-bot model (deletable-by-anyone as permanent design) — this is scaffolding behind final semantics, agreed with the sponsor as a named transition step |

Known interim costs: bot txs consume user block gas (the
dedicated purge budget arrives with protocol purge); liveness depends
on the operator (backlog growth is semantically harmless — the
predicate holds); the consensus-purge hard parts remain unbuilt until
stage 2 — the wheels buy schedule, not progress on those.

## Parallel workstreams (start now, none block stage 1)

- Golem DB: nested shallow copies + parent-copy writes between
  children (state-manager track — longest pole, external dependency)
- reth: account-state **provider abstraction** (trait with trie-backed
  and Golem-DB-backed implementations) — turns the stage-3 cutover
  into a provider swap instead of a pool/RPC rewrite
- engine: settlement entry points (`charge` / `refund` / `mint`)
- changed-accounts payload for pool maintenance
