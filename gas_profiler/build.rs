//! build.rs — Extract a clean ABI for the `execute` function from the forge artifact.
//!
//! The full EntityRegistry ABI has issues that prevent direct use with alloy's sol! macro:
//!   - `BlockNumber` UDVT appears as `internalType` in return types (macro can't resolve it)
//!   - `EntityExpired` name collision between an event and an error
//!
//! This build script reads the forge artifact, extracts only the `execute` function
//! (no events/errors/views = no collisions, no BlockNumber in returns), and strips
//! non-struct `internalType` references (UDVTs like `BlockNumber`) while keeping
//! struct references (`struct EntityHashing.Op`) so the macro generates named types.
//!
//! Re-run trigger: the build script watches the artifact file, so `forge build && cargo build`
//! picks up changes automatically.

use std::path::Path;

fn main() {
    let artifact_path = Path::new("../out/EntityRegistry.sol/EntityRegistry.json");

    // Re-run if the artifact changes.
    println!("cargo::rerun-if-changed={}", artifact_path.display());

    let data = std::fs::read_to_string(artifact_path)
        .expect("failed to read forge artifact — run `forge build` first");

    let artifact: serde_json::Value =
        serde_json::from_str(&data).expect("failed to parse artifact JSON");

    let abi = artifact
        .get("abi")
        .expect("artifact has no 'abi' key")
        .as_array()
        .expect("'abi' is not an array");

    // Keep only the `execute` function entry.
    let filtered: Vec<&serde_json::Value> = abi
        .iter()
        .filter(|item| {
            item.get("type").and_then(|v| v.as_str()) == Some("function")
                && item.get("name").and_then(|v| v.as_str()) == Some("execute")
        })
        .collect();

    assert!(
        !filtered.is_empty(),
        "no 'execute' function found in artifact ABI"
    );

    let mut cleaned: Vec<serde_json::Value> = filtered.into_iter().cloned().collect();
    for item in &mut cleaned {
        normalise_internal_types(item);
    }

    // Write next to build.rs (crate root) so sol! can resolve the path
    // relative to CARGO_MANIFEST_DIR.
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let out_path = Path::new(&manifest_dir).join("execute_abi.json");
    let json = serde_json::to_string_pretty(&cleaned).unwrap();
    std::fs::write(&out_path, &json).unwrap();
}

/// Recursively normalise `internalType` fields:
///   - Keep `internalType` when it starts with "struct " (preserves named struct generation)
///   - Remove `internalType` otherwise (strips UDVTs like "BlockNumber" that the macro can't resolve)
fn normalise_internal_types(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(map) => {
            if let Some(it) = map.get("internalType").and_then(|v| v.as_str()) {
                if !it.starts_with("struct ") {
                    map.remove("internalType");
                }
            }
            for v in map.values_mut() {
                normalise_internal_types(v);
            }
        }
        serde_json::Value::Array(arr) => {
            for v in arr {
                normalise_internal_types(v);
            }
        }
        _ => {}
    }
}
