import logging
from typing import Any, Union

from eth_account import Account
from eth_account.hdaccount import ETHEREUM_DEFAULT_PATH
from eth_account.signers.local import LocalAccount
from eth_account.types import Language

from web3 import Web3
from web3.exceptions import TimeExhausted, Web3RPCError

from util.password import generate_password


class Wallet:
    """Simple class for wallet creation."""

    VALID_NUM_WORDS = [12, 15, 18, 21, 24]  # noqa: RUF012
    WORDS_DEFAULT = 12

    LANGUAGE_DEFAULT = Language.ENGLISH
    PATH_PARTS = 6
    INDEX_DEFAULT = 0
    TX_TIMEOUT_SECONDS = 120

    password: str | None
    vault: dict[str, Any]
    mnemonic: str | None
    address: str
    account: LocalAccount | None
    language: Language | None
    path: str | None
    index: int | None
    w3: Web3 | None

    def __init__(self) -> None:
        """Create a new wallet.

        Do not use this function to create a new wallet.
        Use the static creator funcitons instead.
        """
        Account.enable_unaudited_hdwallet_features()

        self.w3 = None
        self.password = ""
        self.vault = {}
        self.mnemonic = None
        self.address = ""
        self.account = None
        self.language = None
        self.path = ETHEREUM_DEFAULT_PATH
        self.index = Wallet.INDEX_DEFAULT


    def nonce(self) -> int:
        if not self.w3:
            raise ValueError("Web3 instance not provided")

        return self.w3.eth.get_transaction_count(self.address)


    def balance(self) -> int:
        if not self.w3:
            raise ValueError("Web3 instance not provided")

        return self.w3.eth.get_balance(self.address)


    def transfer(self, to: Union [str, "Wallet"], amount: int, gas_price: int = None, sign_and_send:bool=True) -> str:
        if not self.w3:
            raise ValueError("Web3 instance not provided")
        
        if isinstance(to, Wallet):
            to = to.address

        nonce = self.nonce()
        gas = 21000
        gas_price = gas_price or self.w3.eth.gas_price

        tx = {
            "to": to,
            "value": amount,
            "nonce": nonce,
            "gas": gas,
            "gasPrice": gas_price,
        }

        # return unsigned tx is needed if signing and sending not required
        if not sign_and_send:
            return tx

        tx_signed = self.sign(tx)
        return self.send(tx_signed)


    def sign(self, tx: dict[str, Any], nonce=None):
        # provided nonce overrides tx nonce
        if nonce is not None:
            tx['nonce'] = nonce
        # use wallet nonce if tx does not provide nonce
        elif tx.get('nonce') is None:
            tx['nonce'] = self.nonce()

        private_key = bytes(self.account.key)
        return self.w3.eth.account.sign_transaction(tx, private_key=private_key)


    def send(self, signed_tx, timeout:int|None=None):
        # send signed transaction
        try:
            tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)
            tx_hasx_0x = f'0x{tx_hash.hex()}'
            logging.info(f"Transaction sent: {tx_hasx_0x}")

        except Web3RPCError as e:
            logging.error(f"Transaction error {e}")
            raise e

        if not timeout:
            timeout = self.TX_TIMEOUT_SECONDS

        # wait for tx to complete
        try:
            receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=timeout)

        except TimeExhausted:
            logging.warning(f"Transaction timeout after {timeout} seconds.")
            return tx_hasx_0x

        if receipt['status'] == 1:
            logging.info(f"Transaction successful: {receipt}")
        else:
            logging.warning(f"Transaction failed: {receipt}")

        return tx_hasx_0x


    @classmethod
    def create(
        cls,
        w3: Web3,
        words: int = WORDS_DEFAULT,
        language: Language = LANGUAGE_DEFAULT,
        index: int = INDEX_DEFAULT,
        password: str | None = None,
        print_address: bool = True,  # noqa: FBT001, FBT002
    ) -> "Wallet":
        """Create a new wallet."""
        Wallet.validate_index(index)
        Wallet.validate_num_words(words)

        wallet = Wallet()
        wallet.w3 = w3
        wallet.language = language
        wallet.index = index

        if index > 0:
            wallet.path = ETHEREUM_DEFAULT_PATH[:-1] + str(index)

        (wallet.account, wallet.mnemonic) = Account.create_with_mnemonic(
            "", words, language, wallet.path
        )

        wallet.address = wallet.account.address  # type: ignore  # noqa: PGH003

        if print_address:
            print(wallet.address)  # noqa: T201

        # generate random password when not provided
        if not password or len(password) == 0:
            password = generate_password()

        wallet.password = password
        wallet.vault = wallet.account.encrypt(password)  # type: ignore  # noqa: PGH003

        return wallet


    @staticmethod
    def from_address(
        w3: Web3,
        address:str
    ) -> "Wallet":
        """Create a new wallet from a provided address."""
        wallet = Wallet()
        wallet.w3 = w3
        wallet.address = Web3.to_checksum_address(address)
        return wallet


    @staticmethod
    def from_mnemonic(
        w3: Web3,
        mnemonic: str,
        index: int = INDEX_DEFAULT,
        password: str | None = None,
        path: str = ETHEREUM_DEFAULT_PATH,
    ) -> "Wallet":
        """Create a new wallet from a provided mnemonic."""
        Wallet.validate_mnemonic(mnemonic)
        Wallet.validate_index(index)

        wallet = Wallet()
        wallet.w3 = w3
        wallet.mnemonic = mnemonic
        wallet.index = index
        wallet.path = path

        # modify path if index is provided
        if index:
            wallet.path = "/".join(path.split("/")[:-1]) + f"/{index}"

        if not password:
            password = generate_password()

        wallet.password = password
        wallet.account = Account.from_mnemonic(mnemonic, account_path=wallet.path)
        wallet.vault = wallet.account.encrypt(password)  # type: ignore  # noqa: PGH003
        wallet.address = wallet.account.address  # type: ignore  # noqa: PGH003

        return wallet


    @staticmethod
    def from_vault(
        w3: Web3,
        vault: dict[str, Any], 
        password: str
    ) -> "Wallet":
        """Create a new wallet from a vault dict."""
        wallet = Wallet()
        wallet.w3 = w3
        wallet.password = password
        wallet.vault = vault
        wallet.account = Account.from_key(Account.decrypt(vault, password=password))
        wallet.address = wallet.account.address  # type: ignore  # noqa: PGH003

        return wallet


    @staticmethod
    def index_from_path(path: str) -> int:
        """Extract index from provided path string."""
        Wallet.validate_path(path)
        return int(path.split("/")[-1])


    @staticmethod
    def validate_path(path: str) -> None:
        """Perform basic sanity checks.

        Raise an error if provided path is invalid.
        """
        if not isinstance(path, str):
            msg = "Provided path is not of type str"
            raise TypeError(msg)

        parts = len(path.split("/"))
        if parts != Wallet.PATH_PARTS:
            msg = (
                f"Path format invalid, {Wallet.PATH_PARTS} parts expected, got {parts}"
            )
            raise ValueError(msg)


    @staticmethod
    def validate_mnemonic(mnemonic: str) -> None:
        """Perform basic sanity checks.

        Raise an error if provided mnemonic is invalid.
        """
        if not isinstance(mnemonic, str):
            msg = "Provided mnemonic is not of type str"
            raise TypeError(msg)

        Wallet.validate_num_words(len(mnemonic.split()))


    @staticmethod
    def validate_num_words(words: int) -> None:
        """Check that provided number of words is valid.

        Raise an error if provided number of words is invalid.
        """
        if not isinstance(words, int):
            msg = "Provided number of words is not of type int"
            raise TypeError(msg)

        if words not in Wallet.VALID_NUM_WORDS:
            msg = f"Provided number of words is not in {Wallet.VALID_NUM_WORDS}"
            raise ValueError(msg)


    @staticmethod
    def validate_index(index: int) -> None:
        """Perform basic sanity checks.

        Raise an error if provided index is undefined or invalid.
        """
        if not isinstance(index, int):
            msg = "Provided index is not of type int"
            raise TypeError(msg)

        if index < 0:
            msg = "Provided index is negative"
            raise ValueError(msg)
