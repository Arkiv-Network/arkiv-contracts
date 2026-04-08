# Test Suite

## Organisation

```
test/
├── utils/                         Shared infrastructure
│   ├── EntityRegistryHarness.sol  Exposes internal functions for direct testing
│   ├── Base.t.sol                 Common setUp (deploys harness, defines actors)
│   └── Lib.sol                    Pure builder helpers for test data
├── unit/                          One file per internal function
│   └── AttributeHash.t.sol
├── e2e/                           End-to-end flows through public entry points (future)
└── invariant/                     Stateful fuzz / invariant tests (future)
```

## Approach

### Harness pattern

Internal functions are tested via `EntityRegistryHarness`, which inherits
`EntityRegistry` and exposes each internal as a public `exposed_*` wrapper.
This allows unit-level testing without routing through `execute()`.

### Lib.sol

A library of pure builder functions (`uintAttr`, `stringAttr`, `entityKeyAttr`,
`payload`) used across all test files. Keeps test bodies focused on assertions
rather than struct construction.

### Base.t.sol

Every test contract inherits `Base`, which deploys the harness in `setUp()`
and defines common actors (`alice`, `bob`). Override `setUp()` with
`super.setUp()` for additional fixture setup.

## Conventions

- **Given / When / Then** comments structure every test.
- **One file per concern** in `unit/` — named after the function under test.
- Test function names follow `test_<function>_<scenario>`.
- All tests must pass `forge fmt --check && forge build && forge test`.
