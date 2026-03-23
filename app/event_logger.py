from web3 import Web3
import time

# instantiate Web3 instance
w3 = Web3(Web3.HTTPProvider("http://127.0.0.1:8545"))

def handle_event(block):
    print(block)

def log_loop(poll_interval):
    last_block = w3.eth.block_number
    while True:
        current_block = w3.eth.block_number
        for block_num in range(last_block + 1, current_block + 1):
            handle_event(w3.eth.get_block(block_num))
        last_block = current_block
        time.sleep(poll_interval)

def main():
    log_loop(2)

if __name__ == '__main__':
    main()
