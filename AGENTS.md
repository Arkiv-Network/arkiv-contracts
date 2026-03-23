# Agent Instructions

## Purpose of this Repository

This is a Foundry-based Solidity development template with batteries included.
It provides sample contracts, tests, deploy scripts, and a Python app for interacting
with deployed contracts. The goal is to minimize initial setup pain for Solidity development.

Do not extend the scope of this repository beyond that purpose without explicit instruction.

## Before Changing Any Files

Clarify before acting. If the task is ambiguous or the scope of changes is unclear,
ask for clarification before modifying any files. Only proceed when the intent is unambiguous.

## Forge Pipeline

Run the following pipeline in order after every change. Only claim work is done when
all three pass without errors:

```shell
forge fmt --check
forge build
forge test
```

## Test Coverage

When adding new functionality, check test coverage and explicitly flag any areas
that are not adequately covered. Follow the Given/When/Then structure used in existing tests.

## Python

Always run Python via `uv` from the `app/` directory:

```shell
cd app
uv run python <script>
```

Never run Python commands from the repo root — the `pyproject.toml` and dependencies
live in `app/`.

## Conventions

- **Upgradeable contracts**: always follow the namespace storage layout pattern.
  New state variables must use a dedicated storage struct at a `keccak`-derived slot.
  Never append state variables directly to an upgradeable contract.
- **Tests**: follow the Given/When/Then structure used in existing test files.
- **Solidity formatting**: `forge fmt` is authoritative. Run it before checking formatting.
- **Custom errors**: use custom errors instead of `require` with string messages. Custom errors
  are cheaper and carry typed parameters for debugging.
- **Code ordering**: follow the solhint `ordering` rule within every contract:
  1. Type declarations (enum, struct)
  2. Errors
  3. Constants
  4. State variables
  5. Constructor
  6. Functions ordered by visibility (external → public → internal → private),
     then by mutability (pure → view → non-payable → payable) within each visibility level.

## Sharp Edges

- `test/ERC20StorageInspector.sol` is a dev utility for `forge inspect` only.
  It is not a deployable contract and lives in `test/`, not `src/`.
- `forge inspect` for upgradeable contracts requires the workaround path:
  `forge inspect test/ERC20StorageInspector.sol:ERC20StorageInspector storage`
- `.env` contains private keys for local Anvil development only.
  Never fund these accounts on mainnet or any public network.
