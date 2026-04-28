use std::{env, fs, path::Path, process::Command};

fn main() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let project_root = Path::new(&manifest_dir);

    let src_dir = project_root.join("contracts");
    let registry_artifact = project_root.join("out/EntityRegistry.sol/EntityRegistry.json");
    let interface_artifact = project_root.join("out/IEntityRegistry.sol/IEntityRegistry.json");

    println!("cargo:rerun-if-changed={}", src_dir.display());
    println!("cargo:rerun-if-changed={}", registry_artifact.display());
    println!("cargo:rerun-if-changed={}", interface_artifact.display());

    // Run forge build if artifacts are missing or stale
    let needs_build = !registry_artifact.exists() || !interface_artifact.exists() || {
        let artifact_modified = fs::metadata(&registry_artifact)
            .and_then(|m| m.modified())
            .ok();
        let src_modified = newest_modified(&src_dir);
        match (artifact_modified, src_modified) {
            (Some(a), Some(s)) => s > a,
            _ => true,
        }
    };

    if needs_build {
        eprintln!("arkiv-bindings: running forge build...");
        let status = Command::new("forge")
            .arg("build")
            .current_dir(project_root)
            .status()
            .expect("failed to run `forge build` — is Foundry installed?");
        assert!(status.success(), "forge build failed");
    }

    let out_dir = env::var("OUT_DIR").unwrap();

    // --- Generate inline sol! from IEntityRegistry ABI ---
    let interface_json = fs::read_to_string(&interface_artifact)
        .unwrap_or_else(|e| panic!("failed to read {}: {}", interface_artifact.display(), e));
    let interface: serde_json::Value = serde_json::from_str(&interface_json)
        .expect("failed to parse IEntityRegistry artifact JSON");
    let abi = &interface["abi"];

    let sol_code = generate_sol_from_abi(abi);
    let sol_path = Path::new(&out_dir).join("sol.rs");
    fs::write(&sol_path, sol_code).expect("failed to write sol.rs");

    // --- Extract creation bytecode from EntityRegistry artifact ---
    let registry_json = fs::read_to_string(&registry_artifact)
        .unwrap_or_else(|e| panic!("failed to read {}: {}", registry_artifact.display(), e));
    let registry: serde_json::Value =
        serde_json::from_str(&registry_json).expect("failed to parse EntityRegistry artifact JSON");

    let bytecode_hex = registry["bytecode"]["object"]
        .as_str()
        .expect("missing bytecode.object in artifact")
        .strip_prefix("0x")
        .expect("bytecode should start with 0x");

    let bytecode_path = Path::new(&out_dir).join("bytecode.rs");
    fs::write(
        &bytecode_path,
        format!(
            "/// EntityRegistry creation bytecode from Foundry artifact.\n\
             pub const ENTITY_REGISTRY_CREATION_CODE: &str = \"{}\";\n",
            bytecode_hex,
        ),
    )
    .expect("failed to write bytecode.rs");
}

/// Generate a Rust file containing `sol!` with inline Solidity
/// derived from the Foundry ABI JSON.
fn generate_sol_from_abi(abi: &serde_json::Value) -> String {
    let items = abi.as_array().expect("ABI should be an array");

    // Collect struct definitions from function inputs/outputs
    let mut structs = Vec::new();
    let mut seen_structs = std::collections::HashSet::new();

    for item in items {
        collect_structs(item, &mut structs, &mut seen_structs);
    }

    // Generate the sol! block
    let mut sol = String::new();
    sol.push_str("alloy_sol_types::sol! {\n");

    // Emit struct definitions first
    for s in &structs {
        sol.push_str("    #[derive(Debug, Default, PartialEq, Eq)]\n");
        sol.push_str(&format!("    struct {} {{\n", s.name));
        for field in &s.fields {
            sol.push_str(&format!("        {} {};\n", field.sol_type, field.name));
        }
        sol.push_str("    }\n\n");
    }

    // Emit interface with #[sol(rpc)]
    sol.push_str("    #[sol(rpc)]\n");
    sol.push_str("    interface IEntityRegistry {\n");

    for item in items {
        match item["type"].as_str() {
            Some("function") => {
                let name = item["name"].as_str().unwrap();
                let mutability = item["stateMutability"].as_str().unwrap_or("nonpayable");
                let inputs = render_params(&item["inputs"]);
                let outputs = render_params(&item["outputs"]);

                let mut sig = format!("        function {}({}) external", name, inputs);
                if mutability == "view" || mutability == "pure" {
                    sig.push_str(&format!(" {}", mutability));
                }
                if !outputs.is_empty() {
                    sig.push_str(&format!(" returns ({})", outputs));
                }
                sig.push_str(";\n");
                sol.push_str(&sig);
            }
            Some("event") => {
                let name = item["name"].as_str().unwrap();
                let params = render_event_params(&item["inputs"]);
                sol.push_str(&format!("        event {}({});\n", name, params));
            }
            Some("error") => {
                let name = item["name"].as_str().unwrap();
                let params = render_params(&item["inputs"]);
                sol.push_str(&format!("        error {}({});\n", name, params));
            }
            _ => {}
        }
    }

    sol.push_str("    }\n");
    sol.push_str("}\n");

    format!(
        "// Auto-generated from IEntityRegistry.sol ABI — do not edit.\n\
         {}\n",
        sol
    )
}

struct SolStruct {
    name: String,
    fields: Vec<SolField>,
}

struct SolField {
    name: String,
    sol_type: String,
}

fn collect_structs(
    value: &serde_json::Value,
    structs: &mut Vec<SolStruct>,
    seen: &mut std::collections::HashSet<String>,
) {
    // Check inputs and outputs
    for key in &["inputs", "outputs", "components"] {
        if let Some(params) = value.get(key).and_then(|v| v.as_array()) {
            for param in params {
                if param["type"].as_str() == Some("tuple")
                    || param["type"].as_str() == Some("tuple[]")
                {
                    if let Some(internal) = param["internalType"].as_str() {
                        let struct_name = extract_struct_name(internal);
                        if !struct_name.is_empty() && seen.insert(struct_name.clone()) {
                            if let Some(components) = param["components"].as_array() {
                                // Recurse into nested structs first
                                for comp in components {
                                    collect_structs(comp, structs, seen);
                                }

                                let fields: Vec<SolField> = components
                                    .iter()
                                    .map(|c| SolField {
                                        name: c["name"].as_str().unwrap_or("_").to_string(),
                                        sol_type: param_to_sol_type(c),
                                    })
                                    .collect();

                                structs.push(SolStruct {
                                    name: struct_name,
                                    fields,
                                });
                            }
                        }
                    }
                }
                // Recurse
                collect_structs(param, structs, seen);
            }
        }
    }
}

/// Extract a clean struct name from internalType like "struct Entity.Operation[]" → "Operation"
fn extract_struct_name(internal_type: &str) -> String {
    let s = internal_type
        .trim_start_matches("struct ")
        .trim_end_matches("[]");
    // Take the part after the last dot (strips library prefix)
    s.rsplit('.').next().unwrap_or(s).to_string()
}

/// Convert an ABI parameter to a Solidity type string.
fn param_to_sol_type(param: &serde_json::Value) -> String {
    let base_type = param["type"].as_str().unwrap_or("uint256");

    if base_type == "tuple" || base_type == "tuple[]" {
        if let Some(internal) = param["internalType"].as_str() {
            let name = extract_struct_name(internal);
            if base_type.ends_with("[]") {
                format!("{}[]", name)
            } else {
                name
            }
        } else {
            base_type.to_string()
        }
    } else {
        base_type.to_string()
    }
}

/// Render function parameters as a Solidity parameter list.
fn render_params(params: &serde_json::Value) -> String {
    let arr = match params.as_array() {
        Some(a) => a,
        None => return String::new(),
    };

    arr.iter()
        .map(|p| {
            let sol_type = param_to_sol_type(p);
            let name = p["name"].as_str().unwrap_or("");
            if name.is_empty() {
                sol_type
            } else {
                format!("{} {}", sol_type, name)
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// Render event parameters (with indexed keyword).
fn render_event_params(params: &serde_json::Value) -> String {
    let arr = match params.as_array() {
        Some(a) => a,
        None => return String::new(),
    };

    arr.iter()
        .map(|p| {
            let sol_type = param_to_sol_type(p);
            let name = p["name"].as_str().unwrap_or("");
            let indexed = if p["indexed"].as_bool() == Some(true) {
                " indexed"
            } else {
                ""
            };
            format!("{}{} {}", sol_type, indexed, name)
        })
        .collect::<Vec<_>>()
        .join(", ")
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
