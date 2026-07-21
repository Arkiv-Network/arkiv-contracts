# Arkiv State — Where Do Accounts Live?

Status: **open — for discussion**. 

Scope: placement of account state (address → balance, tx nonce). Entities, indexes, and `$entityNonce` live in Golem DB in every option.

Deadline: decide now for the testnet cycle (public testnet target ~2026-09-01).


Core constraints: 
- Entity and index data must only change when a tx succeeds.
- Fee settlement and tx-nonce consumption must survive tx failure.

Every option must answer these.

## Option A — accounts in reth native state (split state)

Balances and tx nonces stay in the reth account trie; reth's native nonce *is* the tx nonce (no `$txNonce` cell — no duplicated counter). Engine meters cost, reth settles — survives failure for free.

Reth standard: 
- tx validation
- mempool
- account RPC endpoints

Reth modifications:
- end-of-block system write anchoring `GetDBHash()` into a designated storage slot (EIP-4788 pattern), so the stock MPT `stateRoot` transitively commits to Golem DB. 
- Proofs: standard `eth_getProof` to the anchor, then Golem DB proof to the record.

Pros
- least work
- stock wallet/tooling compatibility
- no new Golem DB requirements

Cons
- two state definitions
- design welded to reth

## Option B — accounts in unified Golem DB state

`$balance` + `$txNonce` cells on the account record; `GetDBHash()` is the full state root.

New Arkiv engine requirements:
- multi-phase tx lifecycle pipeline
    1. **1st call to Arkiv engine**: initial account modifications: nonce +1, debit max fee
    2. create checkpoint
    3. **2nd call to Arkiv engine**: execute entity ops
    4. on success: calculate refund amount
    5. on failure: rollback to checkpoint, calculate refund
    6. **3rd call to Arkiv engine**: process refunds
    7. commit new state

New Golem DB requirements:
- provide changed-accounts notifications on commit (needed for pool maintenance).

Reth modifications
- txpool validator: needs to read `$balance`/`$txNonce` from Golem DB
- pool maintenance: on new blocks and reorgs, consume Golem DB's changed-accounts notification to evict stale-nonce txs and demote unaffordable ones
- `eth_getBalance` / `eth_getTransactionCount` redirected
- cost→token price enters env and pool config

Pros
- single commitment and proof system
- Golem DB self-contained → execution client swappable

Cons
- large modified-reth work package

## Option C — start with option A, move on to B

Testnet in September ships A, later testnet-2 ships B via a testnet reset (no migration). 

Pros
- earlier public testnet
- provides pros of option B
- only sequencing of work

Cons over B
- 1-2 days for Golem DBHash integration in MPT (not needed for B)
- comms (and some coordination) overhead for testnet-2
