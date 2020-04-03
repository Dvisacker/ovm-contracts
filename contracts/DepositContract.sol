pragma solidity ^0.5.0;
pragma experimental ABIEncoderV2;

/* External Imports */
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/* Internal Imports */
import {DataTypes as types} from "./DataTypes.sol";
import {CommitmentContract} from "./CommitmentContract.sol";
import {
    UniversalAdjudicationContract
} from "./UniversalAdjudicationContract.sol";
import "./Predicate/CompiledPredicate.sol";
import "./Library/Deserializer.sol";

contract DepositContract {
    using SafeMath for uint256;

    /* Events */
    event CheckpointFinalized(
        bytes32 checkpointId,
        types.Checkpoint checkpoint
    );

    event ExitFinalized(bytes32 exitId);

    event DepositedRangeExtended(types.Range newRange);
    event DepositedRangeRemoved(types.Range removedRange);

    /* Public Variables and Mappings*/
    ERC20 public erc20;
    CommitmentContract public commitmentContract;
    UniversalAdjudicationContract public universalAdjudicationContract;
    address public stateUpdatePredicateContract;
    address public exitPredicateAddress;
    address public exitDepositPredicateAddress;

    // totalDeposited is the most right coin id which has been deposited
    uint256 public totalDeposited;
    // depositedRanges are currently deposited ranges
    mapping(uint256 => types.Range) public depositedRanges;
    mapping(bytes32 => bool) public checkpoints;

    constructor(
        address _erc20,
        address _commitmentContract,
        address _universalAdjudicationContract,
        // Fixme: when StateUpdatePredicate is merged
        address _stateUpdatePredicateContract,
        address _exitPredicateAddress,
        address _exitDepositPredicateAddress
    ) public {
        erc20 = ERC20(_erc20);
        commitmentContract = CommitmentContract(_commitmentContract);
        universalAdjudicationContract = UniversalAdjudicationContract(
            _universalAdjudicationContract
        );
        stateUpdatePredicateContract = _stateUpdatePredicateContract;
        exitPredicateAddress = _exitPredicateAddress;
        exitDepositPredicateAddress = _exitDepositPredicateAddress;
    }

    /**
     * @dev deposit ERC20 token to deposit contract with initial state.
     *     following https://docs.plasma.group/projects/spec/en/latest/src/02-contracts/deposit-contract.html#deposit
     * @param _amount to deposit
     * @param _initialState The initial state of deposit
     */
    function deposit(uint256 _amount, types.Property memory _initialState)
        public
    {
        require(
            totalDeposited < 2**256 - 1 - _amount,
            "DepositContract: totalDeposited exceed max uint256"
        );
        require(
            erc20.transferFrom(msg.sender, address(this), _amount),
            "must approved"
        );
        types.Range memory depositRange = types.Range({
            start: totalDeposited,
            end: totalDeposited.add(_amount)
        });
        bytes[] memory inputs = new bytes[](4);
        inputs[0] = abi.encode(address(this));
        inputs[1] = abi.encode(depositRange);
        inputs[2] = abi.encode(getLatestPlasmaBlockNumber());
        inputs[3] = abi.encode(_initialState);
        types.Property memory stateUpdate = types.Property({ // Fixme: when StateUpdatePredicate is merged
            predicateAddress: stateUpdatePredicateContract,
            inputs: inputs
        });
        types.Checkpoint memory checkpoint = types.Checkpoint({
            stateUpdate: stateUpdate
        });
        extendDepositedRanges(_amount);
        bytes32 checkpointId = getCheckpointId(checkpoint);
        // store the checkpoint
        checkpoints[checkpointId] = true;
        emit CheckpointFinalized(checkpointId, checkpoint);
    }

    function extendDepositedRanges(uint256 _amount) public {
        uint256 oldStart = depositedRanges[totalDeposited].start;
        uint256 oldEnd = depositedRanges[totalDeposited].end;
        uint256 newStart;
        if (oldStart == 0 && oldEnd == 0) {
            // Creat a new range when the rightmost range has been removed
            newStart = totalDeposited;
        } else {
            // Delete the old range and make a new one with the total length
            delete depositedRanges[oldEnd];
            newStart = oldStart;
        }
        uint256 newEnd = totalDeposited.add(_amount);
        depositedRanges[newEnd] = types.Range({start: newStart, end: newEnd});
        totalDeposited = totalDeposited.add(_amount);
        emit DepositedRangeExtended(
            types.Range({start: newStart, end: newEnd})
        );
    }

    function removeDepositedRange(
        types.Range memory _range,
        uint256 _depositedRangeId
    ) public {
        require(
            isSubrange(_range, depositedRanges[_depositedRangeId]),
            "range must be of a depostied range (the one that has not been exited)"
        );

        types.Range storage encompasingRange = depositedRanges[_depositedRangeId];
        /*
         * depositedRanges makes O(1) checking existence of certain range.
         * Since _range is subrange of encompasingRange, we only have to check is each start and end are same or not.
         * So, there are 2 patterns for each start and end of _range and encompasingRange.
         * There are nothing todo for _range.start is equal to encompasingRange.start.
         */
        // Check start of range
        if (_range.start != encompasingRange.start) {
            types.Range memory leftSplitRange = types.Range({
                start: encompasingRange.start,
                end: _range.start
            });
            depositedRanges[leftSplitRange.end] = leftSplitRange;
        }
        // Check end of range
        if (_range.end == encompasingRange.end) {
            /*
             * Deposited range Id is end value of the range, we must remove the range from depositedRanges
             *     when range.end is changed.
             */
            delete depositedRanges[encompasingRange.end];
        } else {
            encompasingRange.start = _range.end;
        }

        emit DepositedRangeRemoved(_range);
    }

    /**
     * finalizeCheckpoint
     * @param _checkpointProperty A property which is instance of checkpoint predicate
     * its first input is range to create checkpoint and second input is property for stateObject.
     */
    function finalizeCheckpoint(types.Property memory _checkpointProperty)
        public
    {
        require(
            universalAdjudicationContract.isDecided(_checkpointProperty),
            "Checkpointing claim must be decided"
        );
        types.Property memory property = abi.decode(
            _checkpointProperty.inputs[0],
            (types.Property)
        );
        types.Checkpoint memory checkpoint = types.Checkpoint({
            stateUpdate: property
        });

        bytes32 checkpointId = getCheckpointId(checkpoint);
        // store the checkpoint
        checkpoints[checkpointId] = true;
        emit CheckpointFinalized(checkpointId, checkpoint);
    }

    /**
     * finalizeExit
     * @param _exitProperty A property which is instance of exit predicate and its inputs are range and StateUpdate that exiting account wants to withdraw.
     *     _exitProperty can be a property of ether ExitPredicate or ExitDepositPredicate.
     * @param _depositedRangeId Id of deposited range
     * @return return StateUpdate of exit property which is finalized.
     * @dev The steps of finalizeExit.
     *     1. Serialize exit property
     *     2. check the property is decided by Adjudication Contract.
     *     3. Transfer asset to payout contract corresponding to StateObject.
     *     Please alse see https://docs.plasma.group/projects/spec/en/latest/src/02-contracts/deposit-contract.html#finalizeexit
     */
    function finalizeExit(
        types.Property memory _exitProperty,
        uint256 _depositedRangeId
    ) public returns (types.StateUpdate memory) {
        types.StateUpdate memory stateUpdate = verifyExitProperty(
            _exitProperty
        );
        bytes32 exitId = getExitId(_exitProperty);
        // get payout contract address
        address payout = CompiledPredicate(
            stateUpdate
                .stateObject
                .predicateAddress
        )
            .payoutContractAddress();
        // Check that we are authorized to finalize this exit
        require(
            universalAdjudicationContract.isDecided(_exitProperty),
            "Exit must be decided after this block"
        );
        require(
            payout == msg.sender,
            "finalizeExit must be called from payout contract"
        );
        require(
            stateUpdate.depositContractAddress == address(this),
            "StateUpdate.depositContractAddress must be this contract address"
        );

        // Remove the deposited range
        removeDepositedRange(stateUpdate.range, _depositedRangeId);
        //Transfer tokens to its predicate
        uint256 amount = stateUpdate.range.end - stateUpdate.range.start;
        erc20.transfer(payout, amount);
        emit ExitFinalized(exitId);
        return stateUpdate;
    }

    /**
     * @dev verify StateUpdate in Exit property.
     *     _exitProperty must be instance of ether ExitPredicate or ExitDepositPredicate.
     *     if _exitProperty is instance of ExitDepositPredicate, check _exitProperty.su is subrange of _exitProperty.checkpoint.
     */
    function verifyExitProperty(types.Property memory _exitProperty)
        private
        returns (types.StateUpdate memory)
    {
        if (_exitProperty.predicateAddress == exitPredicateAddress) {
            types.Exit memory exit = Deserializer.deserializeExit(
                _exitProperty
            );
            // TODO: check inclusion proof
            return exit.stateUpdate;
        } else if (
            _exitProperty.predicateAddress == exitDepositPredicateAddress
        ) {
            types.ExitDeposit memory exitDeposit = Deserializer
                .deserializeExitDeposit(_exitProperty);
            types.Checkpoint memory checkpoint = exitDeposit.checkpoint;
            types.StateUpdate memory stateUpdate = Deserializer
                .deserializeStateUpdate(checkpoint.stateUpdate);
            require(
                checkpoints[getCheckpointId(checkpoint)],
                "checkpoint must be finalized"
            );
            require(
                stateUpdate.depositContractAddress ==
                    exitDeposit.stateUpdate.depositContractAddress,
                "depositContractAddress must be same"
            );
            require(
                stateUpdate.blockNumber == exitDeposit.stateUpdate.blockNumber,
                "blockNumber must be same"
            );
            require(
                isSubrange(exitDeposit.stateUpdate.range, stateUpdate.range),
                "range must be subrange of checkpoint"
            );
            return exitDeposit.stateUpdate;
        }
    }

    /* Helpers */
    function getLatestPlasmaBlockNumber() private returns (uint256) {
        return commitmentContract.currentBlock();
    }

    function getCheckpointId(types.Checkpoint memory _checkpoint)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_checkpoint));
    }

    function getExitId(types.Property memory _exit)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_exit));
    }

    function isSubrange(
        types.Range memory _subrange,
        types.Range memory _surroundingRange
    ) public pure returns (bool) {
        return
            _subrange.start >= _surroundingRange.start &&
            _subrange.end <= _surroundingRange.end;
    }
}
