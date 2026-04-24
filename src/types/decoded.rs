use alloy_primitives::{Address, Bytes, B256};

/// A fully decoded entity record combining on-chain commitment data
/// with off-chain content from calldata.
#[derive(Debug, Clone)]
pub struct EntityRecord {
    pub entity_key: B256,
    pub creator: Address,
    pub owner: Address,
    pub created_at: u32,
    pub updated_at: u32,
    pub expires_at: u32,
    pub core_hash: B256,
    pub entity_hash: B256,
    /// Raw payload bytes from calldata. Present only for CREATE/UPDATE.
    pub payload: Option<Bytes>,
    /// Decoded MIME content type string. Present only for CREATE/UPDATE.
    pub content_type: Option<String>,
    /// Decoded attributes from calldata. Present only for CREATE/UPDATE.
    pub attributes: Vec<DecodedAttribute>,
}

/// A decoded attribute from an entity operation's calldata.
#[derive(Debug, Clone)]
pub struct DecodedAttribute {
    /// Decoded Ident32 name (lowercase ASCII, max 32 bytes).
    pub name: String,
    /// 1=UINT, 2=STRING, 3=ENTITY_KEY.
    pub value_type: u8,
    /// Raw bytes32[4] value container.
    pub raw_value: [B256; 4],
}

/// A single decoded operation extracted from a block's transactions.
#[derive(Debug, Clone)]
pub struct DecodedOperation {
    pub block_number: u64,
    pub tx_hash: B256,
    /// Operation type (1=CREATE through 6=EXPIRE).
    pub op_type: u8,
    pub entity_key: B256,
    pub owner: Address,
    pub expires_at: u32,
    pub entity_hash: B256,
    /// Changeset hash after this operation.
    pub changeset_hash: B256,
    /// Full entity data from calldata. Present for CREATE/UPDATE.
    pub entity: Option<EntityRecord>,
}

/// Human-readable label for an operation type.
pub fn op_type_name(op_type: u8) -> &'static str {
    match op_type {
        1 => "CREATE",
        2 => "UPDATE",
        3 => "EXTEND",
        4 => "TRANSFER",
        5 => "DELETE",
        6 => "EXPIRE",
        _ => "UNKNOWN",
    }
}
