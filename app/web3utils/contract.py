import json
import logging

from typing import Any, Dict

from web3 import Web3
from web3.contract import Contract as Web3Contract
from web3.types import FilterParams

from web3utils.wallet import Wallet


class Contract:

    FOUNDRY_OUT = "../out"
    SOLIDITY_EXT = "sol"
    GAS = 1000000
    TX_TIMEOUT_SECONDS = 120

    name:str|None = None
    abi:Dict[str, Any]|None = None
    address:str|None = None
    contract:Web3Contract|None = None
    w3:Web3|None = None

    def __init__(self, w3:Web3, contract_name:str, contract_address:str, out_path:str = FOUNDRY_OUT):
        self.w3 = w3
        self.contract_name = contract_name
        self.abi = self._load_abi(contract_name, out_path, self.SOLIDITY_EXT)
        self.contract = w3.eth.contract(address=contract_address, abi=self.abi)
        self.address = self.contract.address
        self._setup_functions()


    def is_connected(self) -> bool:
        return self.w3.is_connected()


    def get_logs(self, filter_params:FilterParams|None = None) -> Any:
        if not filter_params:
            filter_params = {
                'fromBlock': 'latest',
                'address': self.address
            }

        return self.w3.eth.get_logs(filter_params=filter_params)


    def _setup_functions(self) -> None:
        for func in self.contract.abi:
            if func.get('type') == 'function':
                func_name = func['name']
                mutability = func.get('stateMutability')

                if mutability in ['nonpayable', 'payable']:
                    logging.info(f"creating {func_name}(...) tx")
                    setattr(self, func_name, self._create_write_method(func_name))
                elif mutability in ['view', 'pure']:
                    logging.info(f"creating {func_name}(...) call")
                    setattr(self, func_name, self._create_read_method(func_name))


    def _create_read_method(self, func_name: str):
        def read_method(*args, **kwargs) -> Any:
            try:
                modified_args = [arg.address if isinstance(arg, Wallet) else arg for arg in args]
                return getattr(self.contract.functions, func_name)(*modified_args, **kwargs).call()
            except Exception as e:
                logging.warning(f"Error calling function '{func_name}': {e}")
                return None

        # add docstrings signature and selector
        self._amend_method(read_method, func_name)

        return read_method


    def _create_write_method(self, func_name: str):
        def write_method(*args) -> str:
            tx_params = self._get_tx_params(args)
            function_args = args[:-1]

            # create and return unsigned tx
            if 'nonce' in tx_params:
                return self._build_tx(func_name, function_args, tx_params)

            # create signed tx and send it
            try:
                wallet = tx_params['from']
                tx = self._build_tx(func_name, function_args, tx_params)
                tx_signed = wallet.sign(tx)
                return wallet.send(tx_signed)

            except Exception as e:
                logging.warning(f"Error sending transaction for function '{func_name}': {e}")
                raise

        # add docstrings signature and selector
        self._amend_method(write_method, func_name)

        return write_method


    def _amend_method(self, method, name):
        method.__name__ = name
        method.__doc__ = f"Calls the '{name}' contract function."

        signature = getattr(self.contract.functions, name).signature
        method.signature = signature
        method.argument_names = getattr(self.contract.functions, name).argument_names
        method.inputs = getattr(self.contract.functions, name).abi['inputs']
        method.outputs = getattr(self.contract.functions, name).abi['outputs']
        method.selector = Web3.keccak(text=signature)[:4]
        method.selector_hex = method.selector.hex()


    def _build_tx(self, func_name:str, function_args:tuple, tx_params) -> str:
        # tx properties
        chain_id = self.w3.eth.chain_id
        gas = tx_params.get('gas', self.GAS)
        gas_price = tx_params.get('gasPrice', self.w3.eth.gas_price)
        nonce = self._get_nonce(tx_params)

        # transform wallet args to addresses (str)
        modified_args = [arg.address if isinstance(arg, Wallet) else arg for arg in function_args]

        # create tx
        return getattr(self.contract.functions, func_name)(*modified_args).build_transaction({
            'chainId': chain_id,
            'gas': gas,
            'gasPrice': gas_price,
            'nonce': nonce,
        })


    def _get_tx_params(self, args:tuple) -> Dict[str, Any]:
        if len(args) == 0:
            raise ValueError("No transaction parameters provided.")

        tx_params = args[-1]

        if not isinstance(tx_params, dict):
            raise ValueError("Transaction parameters must be provided as a dictionary.")

        if not ('nonce' in tx_params or 'from' in tx_params):
            raise ValueError("Transaction parameters must either include 'nonce' or 'from' account.")

        if 'from' in tx_params:
            if not isinstance(tx_params['from'], Wallet):
                raise ValueError("Transaction 'from' account must be a Wallet instance.")
        else:
            nonce = tx_params.get('nonce', None)
            if not (nonce is None or (isinstance(nonce, int) and nonce >= 0)):
                raise ValueError("Transaction 'nonce' must must be None or a positive int value.")

        return tx_params


    def _get_nonce(self, tx_params:Dict[str, Any]) -> int:
        if 'nonce' in tx_params:
            return tx_params['nonce']
        else:
            return self.w3.eth.get_transaction_count(tx_params['from'].address)


    def _load_abi(self, contract:str, out_path:str, sol_ext:str) -> Dict[str, Any]:
        try:
            abi_path = f"{out_path}/{contract}.{sol_ext}/{contract}.json"

            with open(abi_path, "r") as abi_file:
                contract_json = json.load(abi_file)
                abi = contract_json.get("abi")

                if abi is None:
                    raise ValueError(f"ABI not found in the JSON file {abi_path}.")

            return abi

        except FileNotFoundError:
            raise ValueError(f"Error: The file {abi_path} does not exist.")

        except json.JSONDecodeError:
            raise ValueError(f"Error: The file {abi_path} is not a valid JSON file.")

        except ValueError as ve:
            raise ValueError(f"Error: {ve}") from ve
