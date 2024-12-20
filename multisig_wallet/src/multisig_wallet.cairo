#[starknet::contract]
mod MultisigWallet {
    use starknet::event::EventEmitter;
    use multisig_wallet::interfaces::imultisig_wallet::IMultisigWallet;
    use multisig_wallet::interfaces::ierc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{ContractAddress, contract_address_const, get_caller_address, get_contract_address, get_block_timestamp};
    use core::starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, 
        Map, StoragePathEntry,
        MutableVecTrait, Vec
    };

    #[storage]
    struct Storage {
        quorum: u256,
        no_of_valid_signers: u256,
        tx_count: u256,
        is_valid_signer: Map<ContractAddress, bool>,
        transactions: Map<u256, Transaction>,
        has_signed: Map<(ContractAddress, u256), bool>,
        transaction_signers: Map<u256, Vec<ContractAddress>>
    }

    #[derive(Copy, Drop, Serde, starknet::Store)]
    pub struct Transaction {
        pub id: u256,
        pub amount: u256,
        pub initiator: ContractAddress,
        pub recipient: ContractAddress,
        pub is_completed: bool,
        pub timestamp: u256,
        pub no_of_approvals: u256,
        pub token_address: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        TransferInitiated: TransferInitiated,
        TransactionApproved: TransactionApproved,
    }

    #[derive(Drop, starknet::Event)]
    struct TransferInitiated {
        pub initiator: ContractAddress,
        pub token: ContractAddress,
        pub recipient: ContractAddress,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct TransactionApproved {
        pub id: u256,
        pub approver: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, quorum: u256, valid_signers: Array<ContractAddress>) {
        assert!(quorum > 1, "few quorum");
        assert!(valid_signers.len().try_into().unwrap() >= quorum, "valid signers less than quorum");

        for i in 0..valid_signers.len() {
            let signer = *valid_signers.at(i);

            assert!(signer != self.zero_address(), "zero address not allowed");

            self.is_valid_signer.entry(signer).write(true);
        };

        self.quorum.write(quorum);
        self.no_of_valid_signers.write(valid_signers.len().try_into().unwrap());
    }

    #[abi(embed_v0)]
    impl MultisigWalletImpl of IMultisigWallet<ContractState> {
        fn init_transfer(ref self: ContractState, token_address: ContractAddress, recipient: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            let this_contract = get_contract_address();

            assert!(self.is_valid_signer.entry(caller).read(), "invalid signer");
            assert!(amount > 0, "can't transfer zero value");
            assert!(token_address != self.zero_address(), "token can't be zero address");

            let token = IERC20Dispatcher{contract_address: token_address};
            assert!(token.balance_of(this_contract) >= amount, "insufiicient funds");

            let tx_id = self.tx_count.read() + 1;

            let transaction = Transaction {
                id: tx_id,
                amount,
                initiator: caller,
                recipient,
                is_completed: false,
                timestamp: get_block_timestamp().try_into().unwrap(),
                no_of_approvals: 1,
                token_address,
            };

            self.transactions.entry(tx_id).write(transaction);
            self.has_signed.entry((caller, tx_id)).write(true);
            self.transaction_signers.entry(tx_id).append().write(caller);

            let prev_tx_count = self.tx_count.read();
            self.tx_count.write(prev_tx_count + 1);

            self.emit(
                TransferInitiated {
                    initiator: caller,
                    token: token_address,
                    recipient,
                    amount,
                }
            );
        }

        fn approve_transaction(ref self: ContractState, tx_id: u256) {
            let caller = get_caller_address();

            assert!(self.is_valid_signer.entry(caller).read(), "invalid signer");
            assert!(self.has_signed.entry((caller, tx_id)).read() == false, "can't sign tiwce");
            assert!(self.transactions.entry(tx_id).is_completed.read() == false, "transaction already completed");

            self.has_signed.entry((caller, tx_id)).write(true);

            let transaction = self.transactions.entry(tx_id).read();

            self.transactions.entry(tx_id).no_of_approvals.write(transaction.no_of_approvals + 1);
            self.transaction_signers.entry(tx_id).append().write(caller);

            let current_no_of_approvals = self.transactions.entry(tx_id).no_of_approvals.read();

            if current_no_of_approvals == self.quorum.read() {
                self.transactions.entry(tx_id).is_completed.write(true);
                IERC20Dispatcher {contract_address: transaction.token_address}.transfer(transaction.recipient, transaction.amount);
            }

            self.emit(
                TransactionApproved {
                    id: tx_id,
                    approver: caller
                }
            );
        }

        fn quorum(self: @ContractState) -> u256 {
            self.quorum.read()
        }

        fn no_of_valid_signers(self: @ContractState) -> u256 {
            self.no_of_valid_signers.read()
        }

        fn tx_count(self: @ContractState) -> u256 {
            self.tx_count.read()
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn zero_address(self: @ContractState) -> ContractAddress {
            contract_address_const::<0>()
        }
    }
}