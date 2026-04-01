use alloy::sol;

sol! {
    #[sol(rpc)]
    contract EntityRegistry {
        struct Attribute {
            bytes32 name;
            uint8 valueType;
            bytes32 fixedValue;
            string stringValue;
        }

        struct Op {
            uint8 opType;
            bytes32 entityKey;
            bytes payload;
            string contentType;
            Attribute[] attributes;
            uint32 expiresAt;
        }

        function execute(Op[] calldata ops) external;
        function expireEntities(bytes32[] calldata keys) external;
        function changeSetHash() public view returns (bytes32);
        function entityKey(address owner, uint32 nonce) public view returns (bytes32);
        function nonces(address owner) public view returns (uint32);

        event EntityCreated(bytes32 indexed entityKey, address indexed owner, bytes32 entityHash, uint32 expiresAt);
        event EntityUpdated(bytes32 indexed entityKey, address indexed owner, bytes32 entityHash);
        event EntityExtended(bytes32 indexed entityKey, address indexed owner, bytes32 entityHash, uint32 previousExpiresAt, uint32 newExpiresAt);
        event EntityDeleted(bytes32 indexed entityKey, address indexed owner, bytes32 entityHash);
        event EntityExpired(bytes32 indexed entityKey, address indexed owner, bytes32 entityHash, uint32 expiresAt);
    }
}
