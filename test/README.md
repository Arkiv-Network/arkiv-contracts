# Test Suite

## Organisation

```
test/
├── utils/                         Shared infrastructure
│   └── Lib.sol                    Pure builder helpers for test data
├── unit/                          One file per concern
│   ├── ops/                       Per-operation tests (Create, Update, etc.)
│   ├── guards/                    Validation guard tests (RequireExists, etc.)
│   ├── hashing/                   Hash function tests (CoreHash, AttributeHash, etc.)
│   ├── types/                     Type tests (Ident32, Mime128)
│   ├── Execute.t.sol              Hash chaining, linked list, snapshots
│   ├── Dispatch.t.sol             Operation routing
│   └── Views.t.sol                Public view function coverage
├── e2e/                           End-to-end flows through public entry points (future)
└── invariant/                     Stateful fuzz / invariant tests (future)
```

## Approach

### Test isolation

Tests inherit `EntityRegistry` directly and override internal functions
to stub behaviour. This allows unit-level testing of individual concerns
without routing through `execute()`.

### Lib.sol

A library of pure builder functions (`createOp`, `updateOp`, `deleteOp`,
`transferOp`, `extendOp`, `expireOp`, `uintAttr`, `stringAttr`,
`entityKeyAttr`) used across all test files. Keeps test bodies focused
on assertions rather than struct construction.

## Conventions

- **One file per concern** in `unit/` — named after the function under test.
- Test function names follow `test_<function>_<scenario>`.
- Event assertions use `vm.recordLogs()` with explicit topic/data checks.
- All tests must pass `forge fmt --check && forge build && forge test`.
