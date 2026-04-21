use std::{env, fs, path::Path, process::Command};

fn main() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let project_root = Path::new(&manifest_dir).parent().unwrap().parent().unwrap();

    let src_dir = project_root.join("src");
    let artifact_path =
        project_root.join("out/EntityRegistry.sol/EntityRegistry.json");

    // Rerun if Solidity sources change
    println!("cargo:rerun-if-changed={}", src_dir.display());
    println!("cargo:rerun-if-changed={}", artifact_path.display());

    // Run forge build if artifact is missing or stale
    let needs_build = !artifact_path.exists() || {
        let artifact_modified = fs::metadata(&artifact_path)
            .and_then(|m| m.modified())
            .ok();
        let src_modified = newest_modified(&src_dir);
        match (artifact_modified, src_modified) {
            (Some(a), Some(s)) => s > a,
            _ => true,
        }
    };

    if needs_build {
        eprintln!("arkiv-genesis: running forge build...");
        let status = Command::new("forge")
            .arg("build")
            .current_dir(project_root)
            .status()
            .expect("failed to run `forge build` — is Foundry installed?");
        assert!(status.success(), "forge build failed");
    }

    // Read the artifact and extract creation bytecode
    let artifact = fs::read_to_string(&artifact_path)
        .unwrap_or_else(|e| panic!("failed to read {}: {}", artifact_path.display(), e));

    let json: serde_json::Value = serde_json::from_str(&artifact)
        .expect("failed to parse EntityRegistry artifact JSON");

    let bytecode_hex = json["bytecode"]["object"]
        .as_str()
        .expect("missing bytecode.object in artifact")
        .strip_prefix("0x")
        .expect("bytecode should start with 0x");

    // Write embedded bytecode as a Rust const
    let out_dir = env::var("OUT_DIR").unwrap();
    let out_path = Path::new(&out_dir).join("bytecode.rs");
    fs::write(
        &out_path,
        format!(
            "/// EntityRegistry creation bytecode from Foundry artifact.\n\
             pub const ENTITY_REGISTRY_CREATION_CODE: &str = \"{}\";\n",
            bytecode_hex,
        ),
    )
    .expect("failed to write bytecode.rs");
}

/// Find the newest modification time in a directory tree.
fn newest_modified(dir: &Path) -> Option<std::time::SystemTime> {
    let mut newest = None;
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let modified = if path.is_dir() {
                newest_modified(&path)
            } else {
                fs::metadata(&path).and_then(|m| m.modified()).ok()
            };
            if let Some(m) = modified {
                newest = Some(match newest {
                    Some(n) if n > m => n,
                    _ => m,
                });
            }
        }
    }
    newest
}
