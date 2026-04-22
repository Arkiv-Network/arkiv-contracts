pub mod decode;
pub mod types;

// Generated from IEntityRegistry.sol ABI by build.rs.
// Contains struct definitions (Operation, Attribute, Mime128, Commitment, BlockNode)
// and the IEntityRegistry interface with all functions, events, and errors.
include!(concat!(env!("OUT_DIR"), "/sol.rs"));

// EntityRegistry creation bytecode embedded at build time.
include!(concat!(env!("OUT_DIR"), "/bytecode.rs"));

/// Operation type constants (mirrors Entity.sol).
pub const OP_CREATE: u8 = 1;
pub const OP_UPDATE: u8 = 2;
pub const OP_EXTEND: u8 = 3;
pub const OP_TRANSFER: u8 = 4;
pub const OP_DELETE: u8 = 5;
pub const OP_EXPIRE: u8 = 6;

/// Attribute value type constants (mirrors Entity.sol).
pub const ATTR_UINT: u8 = 1;
pub const ATTR_STRING: u8 = 2;
pub const ATTR_ENTITY_KEY: u8 = 3;
