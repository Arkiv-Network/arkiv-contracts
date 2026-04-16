use alloy_primitives::{hex, Bytes};
use eyre::{Result, WrapErr, eyre};
use serde::Deserialize;

#[derive(Deserialize)]
struct ForgeArtifact {
    bytecode: BytecodeObject,
}

#[derive(Deserialize)]
struct BytecodeObject {
    object: String,
}

fn parse_hex_bytes(s: &str) -> Result<Bytes> {
    let raw = hex::decode(s).wrap_err("invalid hex in bytecode")?;
    Ok(Bytes::from(raw))
}

/// Default artifact path relative to the project root.
const DEFAULT_PATH: &str = "out/EntityRegistry.sol/EntityRegistry.json";

/// Load the contract init bytecode from the forge artifact.
pub fn load_init_code() -> Result<Bytes> {
    let project_root = find_project_root()?;
    let path = project_root.join(DEFAULT_PATH);
    let data = std::fs::read_to_string(&path)
        .wrap_err_with(|| format!("failed to read artifact at {}", path.display()))?;
    let fa: ForgeArtifact =
        serde_json::from_str(&data).wrap_err("failed to parse forge artifact JSON")?;
    parse_hex_bytes(&fa.bytecode.object)
}

fn find_project_root() -> Result<std::path::PathBuf> {
    let mut dir = std::env::current_dir()?;
    loop {
        if dir.join("foundry.toml").exists() {
            return Ok(dir);
        }
        if !dir.pop() {
            return Err(eyre!(
                "could not find foundry.toml in any parent directory"
            ));
        }
    }
}
