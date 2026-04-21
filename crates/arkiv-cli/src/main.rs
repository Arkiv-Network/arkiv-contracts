use alloy_network::EthereumWallet;
use alloy_primitives::{Address, Bytes, FixedBytes, B256, U256};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_rpc_types::Log as RpcLog;
use alloy_signer_local::PrivateKeySigner;
use alloy_sol_types::SolEvent;
use arkiv_bindings::*;
use clap::{Parser, Subcommand};
use eyre::Result;
use rand::Rng;

/// CLI for submitting EntityRegistry operations.
#[derive(Parser)]
#[command(name = "arkiv-cli")]
struct Cli {
    /// RPC endpoint URL.
    #[arg(long, default_value = "http://localhost:8545")]
    rpc_url: String,

    /// Private key for signing transactions (hex, with or without 0x prefix).
    /// Defaults to the first test mnemonic account.
    #[arg(long, default_value = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")]
    private_key: String,

    /// EntityRegistry contract address.
    #[arg(long, default_value = "0x4200000000000000000000000000000000000042")]
    registry: Address,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Create an entity with a random payload.
    Create {
        /// Content type MIME string.
        #[arg(long, default_value = "application/octet-stream")]
        content_type: String,

        /// Payload size in bytes (random data).
        #[arg(long, default_value = "256")]
        size: usize,

        /// Block number at which the entity expires (must be in the future).
        #[arg(long, default_value = "1000000")]
        expires_at: u32,
    },

    /// Update an existing entity with a new random payload.
    Update {
        /// Entity key to update.
        #[arg(long)]
        key: B256,

        /// Content type MIME string.
        #[arg(long, default_value = "application/octet-stream")]
        content_type: String,

        /// Payload size in bytes (random data).
        #[arg(long, default_value = "256")]
        size: usize,
    },

    /// Extend an entity's expiration.
    Extend {
        /// Entity key to extend.
        #[arg(long)]
        key: B256,

        /// New expiration block number.
        #[arg(long)]
        expires_at: u32,
    },

    /// Transfer entity ownership.
    Transfer {
        /// Entity key to transfer.
        #[arg(long)]
        key: B256,

        /// New owner address.
        #[arg(long)]
        new_owner: Address,
    },

    /// Delete an entity.
    Delete {
        /// Entity key to delete.
        #[arg(long)]
        key: B256,
    },

    /// Expire an entity (must be past its expiration block).
    Expire {
        /// Entity key to expire.
        #[arg(long)]
        key: B256,
    },

    /// Query an entity's on-chain commitment.
    Query {
        /// Entity key to query.
        #[arg(long)]
        key: B256,
    },

    /// Read the current changeset hash.
    Hash,

    /// Check an account's ETH balance.
    Balance {
        /// Address to check. Defaults to the signer's address.
        #[arg(long)]
        address: Option<Address>,
    },
}

fn encode_mime128(mime: &str) -> Mime128 {
    let bytes = mime.as_bytes();
    let mut data = [FixedBytes::ZERO; 4];
    for (i, chunk) in bytes.chunks(32).enumerate() {
        if i >= 4 {
            break;
        }
        let mut buf = [0u8; 32];
        buf[..chunk.len()].copy_from_slice(chunk);
        data[i] = FixedBytes::from(buf);
    }
    Mime128 { data }
}

fn random_payload(size: usize) -> Bytes {
    let mut rng = rand::rng();
    let mut buf = vec![0u8; size];
    rng.fill(&mut buf[..]);
    Bytes::from(buf)
}

fn build_operation(op_type: u8, key: B256) -> Operation {
    Operation {
        operationType: op_type,
        entityKey: key,
        ..Default::default()
    }
}

const OP_NAMES: [&str; 7] = ["UNKNOWN", "CREATE", "UPDATE", "EXTEND", "TRANSFER", "DELETE", "EXPIRE"];

fn op_name(op_type: u8) -> &'static str {
    OP_NAMES.get(op_type as usize).unwrap_or(&"UNKNOWN")
}

fn print_events(logs: &[RpcLog]) {
    for log in logs {
        if let Ok(event) = EntityOperation::decode_log(&log.inner) {
            let e = event.data;
            println!("---");
            println!("  op:          {}", op_name(e.operationType));
            println!("  entity_key:  {}", e.entityKey);
            println!("  owner:       {}", e.owner);
            println!("  expires_at:  {}", e.expiresAt);
            println!("  entity_hash: {}", e.entityHash);
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    let signer: PrivateKeySigner = cli.private_key.parse()?;
    let signer_address = signer.address();
    let wallet = EthereumWallet::from(signer);

    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .connect_http(cli.rpc_url.parse()?);

    let registry = IEntityRegistry::new(cli.registry, &provider);

    match cli.command {
        Command::Create {
            content_type,
            size,
            expires_at,
        } => {
            let op = Operation {
                operationType: OP_CREATE,
                entityKey: B256::ZERO,
                payload: random_payload(size),
                contentType: encode_mime128(&content_type),
                attributes: vec![],
                expiresAt: expires_at,
                newOwner: Address::ZERO,
            };

            let receipt = registry.execute(vec![op]).send().await?.get_receipt().await?;
            println!("tx: {}", receipt.transaction_hash);
            print_events(receipt.inner.logs());
        }

        Command::Update {
            key,
            content_type,
            size,
        } => {
            let op = Operation {
                operationType: OP_UPDATE,
                entityKey: key,
                payload: random_payload(size),
                contentType: encode_mime128(&content_type),
                attributes: vec![],
                ..Default::default()
            };

            let receipt = registry.execute(vec![op]).send().await?.get_receipt().await?;
            println!("tx: {}", receipt.transaction_hash);
            print_events(receipt.inner.logs());
        }

        Command::Extend { key, expires_at } => {
            let mut op = build_operation(OP_EXTEND, key);
            op.expiresAt = expires_at;

            let receipt = registry.execute(vec![op]).send().await?.get_receipt().await?;
            println!("tx: {}", receipt.transaction_hash);
            print_events(receipt.inner.logs());
        }

        Command::Transfer { key, new_owner } => {
            let mut op = build_operation(OP_TRANSFER, key);
            op.newOwner = new_owner;

            let receipt = registry.execute(vec![op]).send().await?.get_receipt().await?;
            println!("tx: {}", receipt.transaction_hash);
            print_events(receipt.inner.logs());
        }

        Command::Delete { key } => {
            let op = build_operation(OP_DELETE, key);

            let receipt = registry.execute(vec![op]).send().await?.get_receipt().await?;
            println!("tx: {}", receipt.transaction_hash);
            print_events(receipt.inner.logs());
        }

        Command::Expire { key } => {
            let op = build_operation(OP_EXPIRE, key);

            let receipt = registry.execute(vec![op]).send().await?.get_receipt().await?;
            println!("tx: {}", receipt.transaction_hash);
            print_events(receipt.inner.logs());
        }

        Command::Query { key } => {
            let result = registry.commitment(key).call().await?;
            let c = result;
            println!("creator:    {}", c.creator);
            println!("owner:      {}", c.owner);
            println!("created_at: {}", c.createdAt);
            println!("updated_at: {}", c.updatedAt);
            println!("expires_at: {}", c.expiresAt);
            println!("core_hash:  {}", c.coreHash);
        }

        Command::Hash => {
            let result = registry.changeSetHash().call().await?;
            println!("{}", B256::from(result.0));
        }

        Command::Balance { address } => {
            let addr = address.unwrap_or(signer_address);
            let balance = provider.get_balance(addr).await?;
            let eth = balance / U256::from(10u64).pow(U256::from(18));
            let remainder = balance % U256::from(10u64).pow(U256::from(18));
            println!("{addr}");
            println!("{eth}.{remainder:018} ETH");
        }
    }

    Ok(())
}
