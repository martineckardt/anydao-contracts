// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.0 <0.9.0;

import "interfaces/ILayerZeroEndpoint.sol";
import "interfaces/ILayerZeroReceiver.sol";

// The contract for the parent governor where the proposal is created and propragated to the child chains.
// After the voting period has ended the proposal results from the child chains are aggregated and the proposal
// is either accepted or rejected.
contract ParentGovernor is ILayerZeroReceiver {
    /**
     * @notice Holds information about a proposal
     *
     * @param id - Unique id for looking up a proposal
     * @param proposer - Creator of the proposal
     * @param eta - The timestamp that the proposal will be available for execution, set once the vote succeeds
     * @param targets - the ordered list of target addresses for calls to be made
     * @param values - The ordered list of values (i.e. msg.value) to be passed to the calls to be made
     * @param signatures - The ordered list of function signatures to be called
     * @param calldatas - The ordered list of calldata to be passed to each call
     * @param startBlock - The block at which voting begins: holders must delegate their votes prior to this block
     * @param endBlock - The block at which voting ends: votes must be cast prior to this block
     * @param forVotes - Current number of votes in favor of this proposal
     * @param againstVotes - Current number of votes in opposition to this proposal
     * @param childAggregated - Current number of ChildGovernors aggregated
     * @param canceled - Flag marking whether the proposal has been canceled
     * @param executed - Flag marking whether the proposal has been executed
     * @param receipts - Receipts of ballots for the entire set of voters
     */
    struct Proposal {
        uint256 id;
        address proposer;
        uint256 eta;
        address[] targets;
        uint256[] values;
        string[] signatures;
        bytes[] calldatas;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 quorumVotes;
        uint256 childAggregated;
        bool canceled;
        bool executed;
        mapping(address => Receipt) receipts;
    }

    /**
     * @notice Ballot receipt record for a voter
     *
     * @param hasVoted - Whether or not a vote has been cast
     * @param support - Whether or not the voter supports the proposal
     * @param votes - The number of votes the voter had, which were cast
     */
    struct Receipt {
        bool hasVoted;
        bool support;
        uint96 votes;
    }

    /// @notice Possible states that a proposal may be in
    enum ProposalState {
        Pending,
        Active,
        Aggregating,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    /// @notice The name of this contract
    string public constant name = "anyDAO Governor Alpha";

    /// @notice The maximum number of actions that can be included in a proposal
    uint256 public constant proposalMaxOperations = 10; // 10 actions

    uint256 public quorum = 25; // 4% of total voting power
    uint256 public proposerPower = 100; // 1% of total voting power
    /// @notice The duration of voting on a proposal, in blocks
    uint256 public votingPeriod = 40_320; // ~7 days in blocks (assuming 15s blocks)
    /// @notice The delay, in blocks, before voting on a proposal may take place, once proposed
    uint256 public votingDelay = 1;
    /// @notice The total number of proposals
    uint256 public proposalCount;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,uint256 chainId,address verifyingContract)"
        );

    /// @notice The EIP-712 typehash for the ballot struct used by the contract
    bytes32 public constant BALLOT_TYPEHASH =
        keccak256("Ballot(uint256 proposalId,bool support)");

    /// @notice The LayerZero endpoint
    ILayerZeroEndpoint public endpoint;

    /// @notice The address of the Protocol Timelock
    TimelockInterface public timelock;

    /// @notice The address of the governance token
    IGovToken public token;

    /// @notice Array of chain IDs
    uint16[] public childChains;

    /// @notice Token addresses of the ChildGovernor to each chain IDs
    mapping(uint16 => address) public childGovernors;

    /// @notice The official record of all proposals ever proposed
    mapping(uint256 => Proposal) public proposals;

    /// @notice The latest proposal for each proposer
    mapping(address => uint256) public latestProposalIds;

    /// @notice An event emitted when a new proposal is created
    event ProposalCreated(
        uint256 id,
        address proposer,
        address[] targets,
        uint256[] values,
        string[] signatures,
        bytes[] calldatas,
        uint256 startBlock,
        uint256 endBlock,
        string description
    );

    /// @notice An event emitted when a vote has been cast on a proposal
    event VoteCast(
        address voter,
        uint256 proposalId,
        bool support,
        uint256 votes
    );

    /// @notice An event emitted when a proposal has been canceled
    event ProposalCanceled(uint256 id);

    /// @notice An event emitted when a proposal has been queued in the Timelock
    event ProposalQueued(uint256 id, uint256 eta);

    /// @notice An event emitted when a proposal has been executed in the Timelock
    event ProposalExecuted(uint256 id);

    /// @notice An event emitted when the required amount of votes for a proposal to be accepted changes
    event NewQuorum(uint256 divisor);

    /// @notice An event emitted when the required amount of voting power required to make a proposal changes
    event NewProposer(uint256 divisor);

    /// @notice An event emitted when the time a proposal stays in voting time in blocks changes
    event NewVotingPeriod(uint256 period);

    /// @notice An event emitted when the delay before voting on a proposal may take place changes
    event NewVotingDelay(uint256 period);

    /**
     * @notice The admin of this contract is the timelock that is owned by this contract, thus
     *         this contract can be modified by itself through the timelock that it controls
     */
    modifier onlyOwner() {
        require(address(timelock) == msg.sender, "ERR_NOT_CONTROLLER");
        _;
    }

    /**
     * @param timelock_ - Contract responsible for queuing and executing governance decisions
     * @param endpoint_ - LayerZero endpoint address on parent chain
     * @param token_ - Contract with voting power logic
     */
    constructor(
        address timelock_,
        address endpoint_,
        address token_
    ) {
        require(
            timelock_ != address(0) || token_ != address(0),
            "ERR_ZERO_ADDRESS"
        );
        timelock = TimelockInterface(timelock_);
        endpoint = ILayerZeroEndpoint(endpoint_);
        token = IGovToken(token_);
    }

    /**
     * @notice Change the required amount of votes for a proposal to be accepted
     *
     * @dev This is the divisor of the total amount of votes, so 4% requires this to be 25
     *
     * @param divisor - divisor of total amount of votes
     */
    function setQuorum(uint256 divisor) external onlyOwner {
        require(divisor > 0, "ERR_INVALID_QUORUM");
        quorum = divisor;
        emit NewQuorum(quorum);
    }

    /**
     * @notice Change the required amount of voting power required to make a proposal
     *
     * @dev This is the divisor of the total amount of votes, so 4% requires this to be 25
     *
     * @param divisor - divisor of total amount of votes
     */
    function setProposer(uint256 divisor) external onlyOwner {
        require(divisor > 0, "ERR_INVALID_PROPOSER");
        proposerPower = divisor;
        emit NewProposer(proposerPower);
    }

    /**
     * @notice Change the time a proposal stays in voting time in blocks
     *
     * @param period - Time voting stays open in blocks
     */
    function setVotingPeriod(uint256 period) external onlyOwner {
        require(period > 11_520, "ERR_MIN_TWO_DAYS");
        votingPeriod = period;
        emit NewVotingPeriod(votingPeriod);
    }

    /**
     * @notice Change the delay, in blocks, before voting on a proposal may take place, once proposed
     *
     * @param period - Time proposal will stay stale before voting starts in blocks
     */
    function setVotingDelay(uint256 period) external onlyOwner {
        require(period > 0, "ERR_MIN_ONE_BLOCK");
        votingDelay = period;
        emit NewVotingDelay(votingDelay);
    }

    /**
     * @notice Change the contract that holds the voting power logic
     *
     * @param contractAddr - Address of new contract
     */
    function setStakingPools(address contractAddr) external onlyOwner {
        require(contractAddr != address(0), "ERR_ZERO_ADDRESS");
        token = IGovToken(contractAddr);
    }

    /**
     * @notice Change the contract that holds the proposals for execution
     *
     * @param contractAddr - Address of new contract
     */
    function setTimelock(address contractAddr) external onlyOwner {
        require(contractAddr != address(0), "ERR_ZERO_ADDRESS");
        timelock = TimelockInterface(contractAddr);
    }

    /**
     * @notice Add new child chain to the parent governor
     * @dev This should be an onlyOwner function, but I kept it open to test it
     *
     * @param chainId - Chain ID to be added
     * @param childGovernor - ChildGovernor address on the chain to be added
     */
    function addChain(uint16 chainId, address childGovernor) external {
        childChains.push(chainId);
        childGovernors[chainId] = childGovernor;
    }

    /**
     * @notice Make a new proposal
     *
     * @param targets - Contracts that will have a function called
     * @param values - Send amount of wei for payable functions defined in `signatures`
     * @param signatures - Functions that will be called from the contract in `targets`
     * @param calldatas - Parameters of the functions in `signatures`
     * @param description - Proposal description, this is what is shown in the governance screen
     *
     * @return Proposal ID
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        string memory description
    ) public returns (uint256) {
        require(
            token.getPriorVotes(msg.sender, block.number - 1) >
                proposalThreshold(),
            "ERR_NOT_ENOUGH_VOTING_POWER"
        );
        require(
            targets.length == values.length &&
                targets.length == signatures.length &&
                targets.length == calldatas.length,
            "ERR_ARITY_MISMATCH"
        );
        require(targets.length != 0, "ERR_NO_ACTIONS");
        require(
            targets.length <= proposalMaxOperations,
            "ERR_TOO_MANY_ACTIONS"
        );

        uint256 latestProposalId = latestProposalIds[msg.sender];
        if (latestProposalId != 0) {
            ProposalState proposersLatestProposalState = state(
                latestProposalId
            );
            require(
                proposersLatestProposalState != ProposalState.Active,
                "ERR_HAS_ACTIVE_PROPOSAL"
            );
            require(
                proposersLatestProposalState != ProposalState.Pending,
                "ERR_HAS_PENDING_PROPOSAL"
            );
        }

        uint256 startBlock = block.number + votingDelay;
        uint256 endBlock = startBlock + votingPeriod;

        proposalCount++;
        Proposal storage newProposal = proposals[proposalCount];
        newProposal.id = proposalCount;
        newProposal.proposer = msg.sender;
        newProposal.eta = 0;
        newProposal.targets = targets;
        newProposal.values = values;
        newProposal.signatures = signatures;
        newProposal.calldatas = calldatas;
        newProposal.startBlock = startBlock;
        newProposal.endBlock = endBlock;
        newProposal.forVotes = 0;
        newProposal.againstVotes = 0;
        newProposal.childAggregated = 0;
        newProposal.canceled = false;
        newProposal.executed = false;
        newProposal.quorumVotes = quorumVotes();

        latestProposalIds[newProposal.proposer] = newProposal.id;

        // create child proposals
        for (uint256 i = 0; i <= childChains.length; i++) {
            uint16 chainId = childChains[i];
            _createChildPoll(newProposal.id, chainId);
        }

        emit ProposalCreated(
            newProposal.id,
            msg.sender,
            targets,
            values,
            signatures,
            calldatas,
            startBlock,
            endBlock,
            description
        );
        return newProposal.id;
    }

    /**
     * @notice Queue a succeded proposal for execution
     *
     * @param proposalId - ID of the proposal to be queued
     */
    function queue(uint256 proposalId) public {
        require(
            state(proposalId) == ProposalState.Succeeded,
            "ERR_NOT_SUCCEEDED"
        );
        Proposal storage proposal = proposals[proposalId];
        uint256 eta = block.timestamp + timelock.delay();
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            bytes32 expectedHash = keccak256(
                abi.encode(
                    proposalId,
                    proposal.targets[i],
                    proposal.values[i],
                    proposal.signatures[i],
                    proposal.calldatas[i],
                    eta
                )
            );
            require(
                !timelock.queuedTransactions(expectedHash),
                "ERR_ACTION_ALREADY_QUEUED_AT_ETA"
            );
            bytes32 txHash = timelock.queueTransaction(
                proposalId,
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                eta
            );
            require(txHash == expectedHash, "ERR_TX_HASH_NOT_MATCHING");
        }
        proposal.eta = eta;
        emit ProposalQueued(proposalId, eta);
    }

    /**
     * @notice Executes a succeded proposal that has already been queued
     */
    function execute(uint256 proposalId) public payable {
        require(state(proposalId) == ProposalState.Queued, "ERR_NOT_QUEUED");
        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            bytes memory returnData = timelock.executeTransaction{
                value: proposal.values[i]
            }(
                proposalId,
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                proposal.eta
            );
            require(returnData.length > 0, "ERR_VOID_TX_DATA");
        }
        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancel a proposal that is not yet executed
     *         The proposer needs to have more vote power than the threshold for it to be cancelled
     *
     * @param proposalId - Proposal to be cancelled
     */
    function cancel(uint256 proposalId) public {
        ProposalState curState = state(proposalId);
        require(curState != ProposalState.Executed, "ERR_ALREADY_EXECUTED");
        require(curState != ProposalState.Canceled, "ERR_ALREADY_CANCELED");

        Proposal storage proposal = proposals[proposalId];

        require(proposal.proposer == msg.sender, "ERR_NOT_PROPOSER");
        require(
            token.getPriorVotes(proposal.proposer, block.number - 1) >
                proposalThreshold(),
            "ERR_NOT_ABOVE_THRESHOLD"
        );

        proposal.canceled = true;
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            timelock.cancelTransaction(
                proposalId,
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                proposal.eta
            );
        }

        emit ProposalCanceled(proposalId);
    }

    /**
     * @notice Vote for a proposal
     *
     * @param proposalId - ID of proposal to cast a vote to
     * @param support - True for accepting, False for rejecting
     */
    function castVote(uint256 proposalId, bool support) public {
        return _castVote(msg.sender, proposalId, support);
    }

    /**
     * @notice Vote for a proposal with a delegated vote
     *
     * @param proposalId - ID of proposal to cast a vote to
     * @param support - True for accepting, False for rejecting
     * @param v - The recovery byte of the signature
     * @param r - Half of the ECDSA signature pair
     * @param s - Half of the ECDSA signature pair
     */
    function castVoteBySig(
        uint256 proposalId,
        bool support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                block.chainid,
                address(this)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(BALLOT_TYPEHASH, proposalId, support)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "ERR_INVALID_SIGNATURE");
        return _castVote(signatory, proposalId, support);
    }

    /**
     * @notice Close all child polls to aggregate votes
     *
     * @param proposalId - ID of proposal to cast a vote to
     */
    function aggregateChildPolls(uint256 proposalId) public {
        ProposalState curState = state(proposalId);
        require(curState == ProposalState.Aggregating, "ERR_NOT_AGGREGATING");

        for (uint256 i = 0; i <= childChains.length; i++) {
            uint16 chainId = childChains[i];
            _closeChildPoll(proposalId, chainId);
        }
    }

    /// @notice Receives messages from LayerZero
    function lzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64,
        bytes memory _payload
    ) external override {
        require(msg.sender == address(endpoint));

        // use assembly to extract the address from the bytes memory parameter
        address fromAddress;
        assembly {
            fromAddress := mload(add(_srcAddress, 20))
        }
        require(fromAddress == childGovernors[_srcChainId]);

        (uint256 proposalId, uint256 forVotes, uint256 againstVotes) = abi
            .decode(_payload, (uint256, uint256, uint256));

        // TO DO: create childGovernor receipts to store votes
        Proposal storage proposal = proposals[proposalId];
        proposal.forVotes = proposal.forVotes + forVotes;
        proposal.againstVotes = proposal.againstVotes + againstVotes;
        proposal.childAggregated += 1;
    }

    /**
     * @notice Get the list of actions a proposal will execute if it succedes
     *
     * @param proposalId - ID of the proposal
     *
     * @return targets - Contracts that will have a function called
     * @return values - Send amount of wei for payable functions defined in `signatures`
     * @return signatures - Functions that will be called from the contract in `targets`
     * @return calldatas - Parameters of the functions in `signatures`
     */
    function getActions(uint256 proposalId)
        public
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            string[] memory signatures,
            bytes[] memory calldatas
        )
    {
        Proposal storage p = proposals[proposalId];
        return (p.targets, p.values, p.signatures, p.calldatas);
    }

    /**
     * @notice Get a ballot receipt about a voter
     *
     * @param proposalId - proposal being checked
     * @param voter - Address of the voter being checked
     *
     * @return A Receipt struct with the information about the vote cast
     */
    function getReceipt(uint256 proposalId, address voter)
        public
        view
        returns (Receipt memory)
    {
        return proposals[proposalId].receipts[voter];
    }

    /**
     * @notice Get the current state of a proposal
     *
     * @param proposalId - ID of the proposal
     *
     * @return ProposalState enum (uint) with state of the proposal
     */
    function state(uint256 proposalId) public view returns (ProposalState) {
        require(
            proposalCount >= proposalId && proposalId > 0,
            "ERR_INVALID_PROPOSAL_ID"
        );
        Proposal storage proposal = proposals[proposalId];
        if (proposal.canceled) {
            return ProposalState.Canceled;
        } else if (block.number <= proposal.startBlock) {
            return ProposalState.Pending;
        } else if (block.number <= proposal.endBlock) {
            return ProposalState.Active;
        } else if (proposal.childAggregated < childChains.length) {
            return ProposalState.Aggregating;
        } else if (
            proposal.forVotes <= proposal.againstVotes ||
            proposal.forVotes < proposal.quorumVotes
        ) {
            return ProposalState.Defeated;
        } else if (proposal.eta == 0) {
            return ProposalState.Succeeded;
        } else if (proposal.executed) {
            return ProposalState.Executed;
        } else if (
            block.timestamp >= (proposal.eta + timelock.GRACE_PERIOD())
        ) {
            return ProposalState.Expired;
        } else {
            return ProposalState.Queued;
        }
    }

    /**
     * @notice The number of votes in support of a proposal required in order
     *         for a quorum to be reached and for a vote to succeed
     *
     * @return Amount of votes required for quorum
     */
    function quorumVotes() public view returns (uint256) {
        return 400000e18; // 400,000 = 4% of Any Token
    }

    /**
     * @notice The number of votes required in order for a voter to become a proposer
     *
     * @return Amount of votes required for proposing
     */
    function proposalThreshold() public view returns (uint256) {
        return 100000e18; // 100,000 = 1% of Any Token
    }

    /**
     * @dev Function that really casts a vote
     *
     * @param voter - Voter wallet/contract address
     * @param proposalId - Proposal receiving a vote
     * @param support - The vote
     */
    function _castVote(
        address voter,
        uint256 proposalId,
        bool support
    ) internal {
        require(state(proposalId) == ProposalState.Active, "ERR_VOTING_CLOSED");
        Proposal storage proposal = proposals[proposalId];
        Receipt storage receipt = proposal.receipts[voter];
        require(receipt.hasVoted == false, "ERR_ALREADY_VOTED");
        uint96 votes = token.getPriorVotes(voter, proposal.startBlock);

        if (support) {
            proposal.forVotes = proposal.forVotes + votes;
        } else {
            proposal.againstVotes = proposal.againstVotes + votes;
        }

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;

        emit VoteCast(voter, proposalId, support, votes);
    }

    function _createChildPoll(uint256 proposalId, uint16 chainId) internal {
        address childGovernor = childGovernors[chainId];
        bytes memory payload = abi.encode(proposalId, "_createPoll");
        _crosschainMessage(chainId, childGovernor, payload);
    }

    function _closeChildPoll(uint256 proposalId, uint16 chainId) internal {
        address childGovernor = childGovernors[chainId];
        bytes memory payload = abi.encode(proposalId, "_closePoll");
        _crosschainMessage(chainId, childGovernor, payload);
    }

    function _crosschainMessage(
        uint16 chainId,
        address targetAddress,
        bytes memory payload
    ) internal {
        // get the fees we need to pay to LayerZero + Relayer to cover message delivery
        // see Communicator.sol's .estimateFees() function for more details.
        (uint256 messageFee, ) = endpoint.estimateFees(
            chainId,
            address(this),
            payload,
            false,
            bytes("")
        );
        require(address(this).balance >= messageFee, "ERR_NOT_ENOUGH_GAS");

        // send LayerZero message
        endpoint.send{value: messageFee}( // {value: messageFee} will be paid out of this contract!
            chainId, // destination chainId
            abi.encodePacked(targetAddress), // destination address of PingPong
            payload, // abi.encode()'ed bytes
            payable(msg.sender), // refund address (LayerZero will refund any extra gas back to caller of send())
            address(0x0), // 'zroPaymentAddress'
            bytes("") // 'txParameters'
        );
    }

    receive() external payable {}
}

/* solhint-disable ordering, func-name-mixedcase */

interface TimelockInterface {
    function delay() external view returns (uint256);

    function GRACE_PERIOD() external view returns (uint256);

    function acceptAdmin() external;

    function queuedTransactions(bytes32 hash) external view returns (bool);

    function queueTransaction(
        uint256 proposalId,
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external returns (bytes32);

    function cancelTransaction(
        uint256 proposalId,
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external;

    function executeTransaction(
        uint256 proposalId,
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external payable returns (bytes memory);
}

interface IGovToken {
    function getPriorVotes(address account, uint256 blockNumber)
        external
        view
        returns (uint96);
}
