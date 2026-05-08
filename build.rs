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

    // Run forge build if artifacts are missing or stale.
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

    // --- Generate sol.rs ---
    //
    // Generate a sol! block with inline Solidity rather than a JSON file path.
    // Inline Solidity lets us control declaration order: UDVTs must be defined
    // before any struct or interface member that references them, and structs
    // must be defined before structs that contain them. The JSON file path
    // approach hands ordering to alloy's macro, which processes ABI items
    // sequentially and cannot resolve forward references to UDVTs.
    let interface_json = fs::read_to_string(&interface_artifact)
        .unwrap_or_else(|e| panic!("failed to read {}: {}", interface_artifact.display(), e));
    let interface: serde_json::Value =
        serde_json::from_str(&interface_json).expect("failed to parse IEntityRegistry artifact");
    let abi = &interface["abi"];

    let sol_code = generate_sol_from_abi(abi);
    fs::write(Path::new(&out_dir).join("sol.rs"), sol_code).expect("failed to write sol.rs");

    // --- Embed creation bytecode ---
    let registry_json = fs::read_to_string(&registry_artifact)
        .unwrap_or_else(|e| panic!("failed to read {}: {}", registry_artifact.display(), e));
    let registry: serde_json::Value =
        serde_json::from_str(&registry_json).expect("failed to parse EntityRegistry artifact JSON");

    let bytecode_hex = registry["bytecode"]["object"]
        .as_str()
        .expect("missing bytecode.object in artifact")
        .strip_prefix("0x")
        .expect("bytecode should start with 0x");

    fs::write(
        Path::new(&out_dir).join("bytecode.rs"),
        format!(
            "/// EntityRegistry creation bytecode from Foundry artifact.\n\
             pub const ENTITY_REGISTRY_CREATION_CODE: &str = \"{bytecode_hex}\";\n",
        ),
    )
    .expect("failed to write bytecode.rs");
}

// -----------------------------------------------------------------------------
// sol! code generator
// -----------------------------------------------------------------------------

/// Generate a `sol!` block with inline Solidity from the compiled ABI.
///
/// Declaration order:
///   1. UDVTs (`type X is Y`) — must precede any reference to X
///   2. Structs — inner structs before outer (dependency order via recursion)
///   3. Interface — functions, events, errors
fn generate_sol_from_abi(abi: &serde_json::Value) -> String {
    let items = abi.as_array().expect("ABI is not an array");

    let mut seen_udvts = std::collections::HashSet::<String>::new();
    let mut udvts: Vec<(String, String)> = Vec::new(); // (UDVT name, underlying sol type)
    let mut seen_structs = std::collections::HashSet::<String>::new();
    let mut structs: Vec<(String, Vec<serde_json::Value>)> = Vec::new(); // (name, components)

    for item in items {
        collect_types(item, &mut seen_udvts, &mut udvts, &mut seen_structs, &mut structs);
    }

    let mut out = String::from(
        "// Auto-generated from IEntityRegistry.sol ABI — do not edit.\n\
         alloy_sol_types::sol! {\n",
    );

    // 1. UDVTs
    for (name, underlying) in &udvts {
        out.push_str("    #[derive(Debug, PartialEq, Eq, Hash)]\n");
        out.push_str(&format!("    type {} is {};\n", name, underlying));
    }
    if !udvts.is_empty() {
        out.push('\n');
    }

    // 2. Structs
    for (name, components) in &structs {
        let derives = if name == "Attribute" {
            // Default for Attribute would give valueType=0 (UNINITIALIZED),
            // which the contract rejects. Omit it intentionally.
            "    #[derive(Debug, PartialEq, Eq)]\n"
        } else {
            "    #[derive(Debug, Default, PartialEq, Eq)]\n"
        };
        out.push_str(derives);
        out.push_str(&format!("    struct {} {{\n", name));
        for comp in components {
            let sol_type = param_sol_type(comp);
            let field_name = comp["name"].as_str().unwrap_or("_");
            out.push_str(&format!("        {} {};\n", sol_type, field_name));
        }
        out.push_str("    }\n\n");
    }

    // 3. Interface
    out.push_str("    #[sol(rpc)]\n");
    out.push_str("    interface IEntityRegistry {\n");
    for item in items {
        match item["type"].as_str() {
            Some("function") => out.push_str(&render_function(item)),
            Some("event") => out.push_str(&render_event(item)),
            Some("error") => out.push_str(&render_error(item)),
            _ => {}
        }
    }
    out.push_str("    }\n}\n");

    out
}

/// Recursively collect UDVT and struct definitions from an ABI item.
/// Structs are inserted after their component types (dependency order).
fn collect_types(
    value: &serde_json::Value,
    seen_udvts: &mut std::collections::HashSet<String>,
    udvts: &mut Vec<(String, String)>,
    seen_structs: &mut std::collections::HashSet<String>,
    structs: &mut Vec<(String, Vec<serde_json::Value>)>,
) {
    for key in &["inputs", "outputs", "components"] {
        let Some(params) = value.get(key).and_then(|v| v.as_array()) else {
            continue;
        };
        for param in params {
            let abi_type = param["type"].as_str().unwrap_or("");

            if abi_type == "tuple" || abi_type == "tuple[]" {
                // Recurse into components first — inner structs must be declared before outer.
                collect_types(param, seen_udvts, udvts, seen_structs, structs);

                if let Some(internal) = param["internalType"].as_str() {
                    let name = extract_struct_name(internal);
                    if !name.is_empty() && seen_structs.insert(name.clone()) {
                        if let Some(comps) = param["components"].as_array() {
                            structs.push((name, comps.clone()));
                        }
                    }
                }
            } else {
                if let Some(internal) = param["internalType"].as_str() {
                    // UDVT: internalType differs from the ABI primitive and contains
                    // no spaces (ruling out "struct X" / "enum X").
                    if internal != abi_type
                        && !internal.contains(' ')
                        && seen_udvts.insert(internal.to_string())
                    {
                        udvts.push((internal.to_string(), abi_type.to_string()));
                    }
                }
                collect_types(param, seen_udvts, udvts, seen_structs, structs);
            }
        }
    }
}

/// Convert an ABI parameter to its Solidity type string, preserving UDVT names.
fn param_sol_type(param: &serde_json::Value) -> String {
    let abi_type = param["type"].as_str().unwrap_or("uint256");

    if abi_type == "tuple" || abi_type == "tuple[]" {
        if let Some(internal) = param["internalType"].as_str() {
            let name = extract_struct_name(internal);
            if abi_type.ends_with("[]") {
                format!("{}[]", name)
            } else {
                name
            }
        } else {
            abi_type.to_string()
        }
    } else if let Some(internal) = param["internalType"].as_str() {
        if internal != abi_type && !internal.contains(' ') {
            internal.to_string() // UDVT name
        } else {
            abi_type.to_string()
        }
    } else {
        abi_type.to_string()
    }
}

fn render_function(item: &serde_json::Value) -> String {
    let name = item["name"].as_str().unwrap_or("_");
    let mutability = item["stateMutability"].as_str().unwrap_or("nonpayable");
    let inputs = render_params(&item["inputs"]);
    let outputs = render_params(&item["outputs"]);

    let mut sig = format!("        function {}({}) external", name, inputs);
    if matches!(mutability, "view" | "pure") {
        sig.push_str(&format!(" {}", mutability));
    }
    if !outputs.is_empty() {
        sig.push_str(&format!(" returns ({})", outputs));
    }
    sig.push_str(";\n");
    sig
}

fn render_event(item: &serde_json::Value) -> String {
    let name = item["name"].as_str().unwrap_or("_");
    let params = render_indexed_params(&item["inputs"]);
    format!("        event {}({});\n", name, params)
}

fn render_error(item: &serde_json::Value) -> String {
    let name = item["name"].as_str().unwrap_or("_");
    let params = render_params(&item["inputs"]);
    format!("        error {}({});\n", name, params)
}

fn render_params(params: &serde_json::Value) -> String {
    params
        .as_array()
        .map(|arr| {
            arr.iter()
                .map(|p| {
                    let t = param_sol_type(p);
                    match p["name"].as_str().filter(|n| !n.is_empty()) {
                        Some(name) => format!("{} {}", t, name),
                        None => t,
                    }
                })
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default()
}

fn render_indexed_params(params: &serde_json::Value) -> String {
    params
        .as_array()
        .map(|arr| {
            arr.iter()
                .map(|p| {
                    let t = param_sol_type(p);
                    let idx = if p["indexed"].as_bool() == Some(true) {
                        " indexed"
                    } else {
                        ""
                    };
                    match p["name"].as_str().filter(|n| !n.is_empty()) {
                        Some(name) => format!("{}{} {}", t, idx, name),
                        None => format!("{}{}", t, idx),
                    }
                })
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default()
}

/// Extract a clean struct name from an `internalType` string.
/// `"struct Entity.BlockNode[]"` → `"BlockNode"`
fn extract_struct_name(internal_type: &str) -> String {
    let s = internal_type
        .trim_start_matches("struct ")
        .trim_start_matches("enum ")
        .trim_end_matches("[]");
    s.rsplit('.').next().unwrap_or(s).to_string()
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
