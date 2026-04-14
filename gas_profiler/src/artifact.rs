use alloy_primitives::{hex, Bytes};
use eyre::{Result, WrapErr, eyre};
use serde::Deserialize;
use std::path::Path;

/// Minimal representation of a forge compilation artifact.
pub struct Artifact {
    /// Init bytecode (constructor + deployment code).
    pub bytecode: Bytes,
    /// Runtime bytecode (what ends up on-chain).
    pub deployed_bytecode: Bytes,
    /// Contract ABI (raw JSON value, for reference).
    pub abi: serde_json::Value,
}

#[derive(Deserialize)]
struct ForgeArtifact {
    abi: serde_json::Value,
    bytecode: BytecodeObject,
    #[serde(rename = "deployedBytecode")]
    deployed_bytecode: BytecodeObject,
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

pub fn load_artifact() -> Result<Artifact> {
    // Walk up from the binary / cwd to find the project root (contains foundry.toml).
    let project_root = find_project_root()?;
    let path = project_root.join(DEFAULT_PATH);
    load_artifact_from(&path)
}

pub fn load_artifact_from(path: &Path) -> Result<Artifact> {
    let data = std::fs::read_to_string(path)
        .wrap_err_with(|| format!("failed to read artifact at {}", path.display()))?;
    let fa: ForgeArtifact =
        serde_json::from_str(&data).wrap_err("failed to parse forge artifact JSON")?;

    Ok(Artifact {
        bytecode: parse_hex_bytes(&fa.bytecode.object)?,
        deployed_bytecode: parse_hex_bytes(&fa.deployed_bytecode.object)?,
        abi: fa.abi,
    })
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
