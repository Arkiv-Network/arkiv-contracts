# Arkiv Entity Registry

Smart contracts for the Arkiv entity registry — a verifiable commitment
layer for an off-chain database. Entities are created and mutated on-chain;
full content lives in calldata and is indexed off-chain by database nodes.
A rolling changeset hash lets any node verify its local state against the
canonical chain.

See [docs/architecture.md](docs/architecture.md) for the full system design.

## Contracts

| Contract | Description |
|---|---|
| `EntityRegistry` | Stateful registry — executes operations, stores commitments, maintains the changeset hash chain |
| `Entity` | Pure library — encoding, hashing, validation, and type definitions |
| `BlockNumber` | uint32 block number type with operator overloads |
| `Ident32` | Validated identifier type (a-z, 0-9, ., -, _, max 32 bytes) |
| `Mime128` | Fixed 128-byte MIME type with RFC 2045 validation |

## Development

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```shell
forge build          # compile
forge test           # run tests (default profile)
forge lint           # static analysis
forge fmt --check    # formatting check
```

### Profiles

| Profile | Activation | Purpose |
|---|---|---|
| `default` | (default) | Fast local dev — optimizer 200 runs, 256 fuzz runs |
| `ci` | `FOUNDRY_PROFILE=ci` | Thorough — optimizer 10k runs, via_ir, 5k fuzz runs |
| `prod` | `FOUNDRY_PROFILE=prod` | Deployment — matches on-chain verified bytecode |

### Project Structure

```
src/
  EntityRegistry.sol       Stateful registry contract
  Entity.sol               Pure encoding/hashing library
  types/
    BlockNumber.sol        Block number type
    Ident32.sol            Identifier type + validation
    Mime128.sol            MIME type + RFC 2045 validation

test/
  unit/                    Per-function unit tests
  integration/             Cross-operation interaction tests
  e2e/                     Full pipeline through execute()

docs/
  architecture.md          System architecture overview
```
