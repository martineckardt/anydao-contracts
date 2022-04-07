// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.0 <0.9.0;

import "interfaces/ILayerZeroEndpoint.sol";
import "interfaces/ILayerZeroReceiver.sol";

// Contract for the child govenor that allows the parent govenore to create a proposal and request the results
// at the end of the voting period.
contract ChildGovernor is ILayerZeroReceiver {
    /**
     * @notice Holds information about a child poll
     *
     * @param pollId - Poll unique id
     * @param chainId - Chain id of the parent proposal
     * @param parentId - Unique id for looking up a proposal in the parent chain
     * @param startBlock - The block at which voting begins: holders must delegate their votes prior to this block
     * @param forVotes - Current number of votes in favor of this poll
     * @param againstVotes - Current number of votes in opposition to this poll
     * @param closed - Flag marking whether the poll has been closed
     * @param receipts - Receipts of ballots for the entire set of voters
     */
    struct Poll {
        uint256 pollId;
        uint256 chainId;
        uint256 parentId;
        uint256 startBlock;
        uint256 forVotes;
        uint256 againstVotes;
        bool closed;
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

    /// @notice Possible states that a Poll may be in
    enum PollState {
        Open,
        Closed
    }

    /// @notice The name of this contract
    string public constant name = "AnyDAO Child Governor";

    /// @notice The total number of polls
    uint256 public pollCount;

    /// @notice The address of the contract owner
    address public owner;

    /// @notice The address of the ParentGovernor contract
    address public parentGovernor;

    /// @notice The chain ID of the ParentGovernor
    uint16 public parentChain;

    /// @notice The LayerZero endpoint
    ILayerZeroEndpoint public endpoint;

    /// @notice The address of the governance token
    IGovToken public token;

    /// @notice The official record of all polls ever proposed
    mapping(uint256 => Poll) public polls;

    /// @notice An event emitted when a new poll is created
    event PollCreated(uint256 pollId, uint256 chainId, uint256 parentId);

    /// @notice An event emitted when a vote has been cast on a poll
    event VoteCast(address voter, uint256 pollId, bool support, uint256 votes);

    /// @notice An event emitted when a poll has been closed
    event PollClosed(uint256 pollId);

    /**
     * @notice The admin of this contract
     */
    modifier onlyOwner() {
        require((owner) == msg.sender, "ERR_NOT_CONTROLLER");
        _;
    }

    /**
     * @param endpoint_ - Contract responsible for queuing and executing governance decisions
     * @param token_ - Contract with voting power logic
     */
    constructor(
        address owner_,
        address endpoint_,
        address token_,
        address parentGovernor_,
        uint16 parentChain_
    ) {
        owner = owner_;
        endpoint = ILayerZeroEndpoint(endpoint_);
        token = IGovToken(token_);
        parentGovernor = parentGovernor_;
        parentChain = parentChain_;
    }

    /**
     * @notice Change the contract owner
     *
     * @param owner_ - Address of new owner
     */
    function setOwner(address owner_) external onlyOwner {
        require(owner_ != address(0), "ERR_ZERO_ADDRESS");
        owner = owner_;
    }

    /**
     * @notice Change the contract that holds the voting power logic
     *
     * @param contractAddr - Address of new contract
     */
    function setGovToken(address contractAddr) external onlyOwner {
        require(contractAddr != address(0), "ERR_ZERO_ADDRESS");
        token = IGovToken(contractAddr);
    }

    /**
     * @dev Function that casts a vote
     *
     * @param pollId - Poll receiving a vote
     * @param support - The vote
     */
    function castVote(uint256 pollId, bool support) external {
        require(state(pollId) == PollState.Open, "ERR_VOTING_CLOSED");
        address voter = msg.sender;
        Poll storage poll = polls[pollId];
        Receipt storage receipt = poll.receipts[voter];
        require(receipt.hasVoted == false, "ERR_ALREADY_VOTED");
        uint96 votes = token.getPriorVotes(voter, poll.startBlock);

        if (support) {
            poll.forVotes = poll.forVotes + votes;
        } else {
            poll.againstVotes = poll.againstVotes + votes;
        }

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;

        emit VoteCast(voter, pollId, support, votes);
    }

    /**
     * @notice Get a ballot receipt about a voter
     *
     * @param pollId - poll being checked
     * @param voter - Address of the voter being checked
     *
     * @return A Receipt struct with the information about the vote cast
     */
    function getReceipt(uint256 pollId, address voter)
        public
        view
        returns (Receipt memory)
    {
        return polls[pollId].receipts[voter];
    }

    /**
     * @notice Get the current state of a poll
     *
     * @param pollId - ID of the poll
     *
     * @return PollState enum (uint) with state of the poll
     */
    function state(uint256 pollId) public view returns (PollState) {
        require(pollCount >= pollId && pollId > 0, "ERR_INVALID_PROPOSAL_ID");
        Poll storage poll = polls[pollId];
        if (poll.closed) {
            return PollState.Closed;
        } else {
            return PollState.Open;
        }
    }

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
        require(fromAddress == parentGovernor);

        (uint256 parentId, string memory function_name) = abi.decode(
            _payload,
            (uint256, string)
        );

        if (
            keccak256(_payload) ==
            keccak256(abi.encodePacked(parentId, "_createPoll"))
        ) {
            _createPoll(_srcChainId, parentId);
        }

        if (
            keccak256(_payload) ==
            keccak256(abi.encodePacked(parentId, "_closePoll"))
        ) {
            _closePoll(parentId);
        }
    }

    /**
     * @notice Make a new poll
     *
     * @param chainId - Chain id of the parent proposal
     * @param parentId - Unique id for looking up a proposal in the parent chain
     *
     * @return Poll ID
     */
    function _createPoll(uint256 chainId, uint256 parentId)
        internal
        returns (uint256)
    {
        pollCount++;
        Poll storage newPoll = polls[pollCount];
        newPoll.pollId = pollCount;
        newPoll.chainId = chainId;
        newPoll.parentId = parentId;
        newPoll.startBlock = block.number;
        newPoll.forVotes = 0;
        newPoll.againstVotes = 0;
        newPoll.closed = false;

        emit PollCreated(newPoll.pollId, newPoll.chainId, newPoll.parentId);
        return newPoll.pollId;
    }

    /**
     * @notice Sends the poll results to the parent chain
     */
    function _closePoll(uint256 pollId) internal {
        Poll storage poll = polls[pollId];

        bytes memory payload = abi.encode(
            poll.parentId,
            poll.forVotes,
            poll.againstVotes
        );

        (uint256 messageFee, ) = endpoint.estimateFees(
            parentChain,
            address(this),
            payload,
            false,
            bytes("")
        );
        require(address(this).balance >= messageFee, "ERR_NOT_ENOUGH_GAS");

        // send LayerZero message
        endpoint.send{value: messageFee}( // {value: messageFee} will be paid out of this contract!
            parentChain, // destination chain ID
            abi.encodePacked(parentGovernor), // destination address of the message
            payload, // abi.encode()'ed bytes
            payable(msg.sender), // (msg.sender will be this contract) refund address (LayerZero will refund any extra gas back to caller of send()
            address(0x0), // 'zroPaymentAddress'
            bytes("") // 'txParameters'
        );

        poll.closed = true;
    }
}

interface IGovToken {
    function getPriorVotes(address account, uint256 blockNumber)
        external
        view
        returns (uint96);
}
