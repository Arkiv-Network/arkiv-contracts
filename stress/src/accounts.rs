use alloy::{
    primitives::{Address, U256},
    providers::Provider,
    signers::local::{
        coins_bip39::English, MnemonicBuilder, PrivateKeySigner,
    },
};
use eyre::Result;

use crate::config;

/// Derive N wallets from the test mnemonic using BIP-44 paths.
/// Starts at index 1 (index 0 is the dev/funder account).
pub fn derive_wallets(count: u32) -> Result<Vec<PrivateKeySigner>> {
    let mut wallets = Vec::with_capacity(count as usize);
    for i in 1..=count {
        let path = format!("m/44'/60'/0'/0/{i}");
        let wallet = MnemonicBuilder::<English>::default()
            .phrase(config::TEST_MNEMONIC)
            .derivation_path(&path)?
            .build()?;
        wallets.push(wallet);
    }
    Ok(wallets)
}

/// Derive the dev wallet (index 0).
pub fn dev_wallet() -> Result<PrivateKeySigner> {
    Ok(MnemonicBuilder::<English>::default()
        .phrase(config::TEST_MNEMONIC)
        .derivation_path("m/44'/60'/0'/0/0")?
        .build()?)
}

/// Fund all test accounts from the dev account.
pub async fn fund_accounts<P: Provider>(
    provider: &P,
    wallets: &[PrivateKeySigner],
    eth_per_account: U256,
    _chain_id: u64,
) -> Result<()> {
    let dev_signer = dev_wallet()?;
    let dev_addr: Address = dev_signer.address();
    let mut nonce = provider.get_transaction_count(dev_addr).await?;

    for wallet in wallets {
        let to_addr: Address = wallet.address();
        let balance = provider.get_balance(to_addr).await?;
        if balance >= eth_per_account {
            nonce += 1;
            continue;
        }

        let tx = alloy::rpc::types::TransactionRequest::default()
            .to(to_addr)
            .value(eth_per_account)
            .nonce(nonce)
            .gas_limit(21_000)
            .max_fee_per_gas(20_000_000_000)
            .max_priority_fee_per_gas(1_000_000_000);

        let pending = provider.send_transaction(tx).await?;
        pending.watch().await?;

        nonce += 1;
    }

    Ok(())
}
