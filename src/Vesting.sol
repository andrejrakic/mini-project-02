// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC20} from "./vendor/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "./vendor/@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "./vendor/@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeCast} from "./vendor/@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title Vesting
 *
 *  token amount
 *       ^
 *       |                           __________________
 *       |                          /
 *       |                         /
 *       |                        /
 *       |                       /
 *       |                      /
 *       | <----- cliff ----->
 *       |
 *       |
 *        --------------------.------.-------------------> time
 *                         vesting duration
 *
 *
 */
contract Vesting is ReentrancyGuard {
  using SafeERC20 for IERC20;

  struct VestingDetails {
    uint256 totalVestedAmount; //
    uint256 releasedAmount; //
    address vestedTokenAddress; // ──╮
    uint48 startTimestamp; //        │
    uint48 cliffTimestamp; // ───────╯
    address revoker; // ─────────────╮
    uint32 totalVestingDuration; // ─╯
  }

  mapping(bytes32 payerToReceiverRelation => VestingDetails) internal s_vestingDetails;

  error Vesting_AlreadyDeposited(address payer, address receiver);
  error Vesting__StartTimestampMustNotBeInThePast();
  error Vesting__InvalidDuration(string description);
  error Vesting__ZeroAddress(string description);
  error Vesting_OnlyRevokerCanCall();
  error Vesting__NothingToRelease();

  event Deposited(
    address indexed payer,
    address indexed receiver,
    address revoker,
    address vestedTokenAddress,
    uint256 totalVestedAmount,
    uint48 startTimestamp,
    uint48 cliffTimestamp,
    uint32 totalVestingDuration
  );
  event Released(address indexed receiver, uint256 releasedAmount);

  function deposit(
    address _receiver,
    address _vestedTokenAddress,
    uint256 _amount,
    address _revoker,
    uint48 _startTimestamp,
    uint32 _cliffDuration,
    uint32 _vestingDuration
  ) external {
    bytes32 payerToReceiverRelation = keccak256(abi.encodePacked(msg.sender, _receiver));

    if (s_vestingDetails[payerToReceiverRelation].revoker != address(0))
      revert Vesting_AlreadyDeposited(msg.sender, _receiver);

    if (_startTimestamp < block.timestamp) revert Vesting__StartTimestampMustNotBeInThePast();
    if (_cliffDuration <= 0) revert Vesting__InvalidDuration("cliff duration");
    if (_vestingDuration <= 0) revert Vesting__InvalidDuration("vesting duration");
    if (_receiver == address(0)) revert Vesting__ZeroAddress("receiver");
    if (_revoker == address(0)) revert Vesting__ZeroAddress("revoker");

    IERC20(_vestedTokenAddress).safeTransferFrom(msg.sender, address(this), _amount);

    uint48 cliffTimestamp = _startTimestamp + SafeCast.toUint48(_cliffDuration);
    uint32 totalVestingDuration = _cliffDuration + _vestingDuration;

    s_vestingDetails[payerToReceiverRelation] = VestingDetails({
      totalVestedAmount: _amount,
      releasedAmount: 0,
      vestedTokenAddress: _vestedTokenAddress,
      startTimestamp: _startTimestamp,
      cliffTimestamp: cliffTimestamp,
      revoker: _revoker,
      totalVestingDuration: totalVestingDuration
    });

    emit Deposited(
      msg.sender,
      _receiver,
      _revoker,
      _vestedTokenAddress,
      _amount,
      _startTimestamp,
      cliffTimestamp,
      totalVestingDuration
    );
  }

  function release(address _payer, address _receiver) external nonReentrant {
    bytes32 payerToReceiverRelation = keccak256(abi.encodePacked(_payer, _receiver));
    VestingDetails memory vestingDetails = s_vestingDetails[payerToReceiverRelation];

    if (vestingDetails.revoker != msg.sender) revert Vesting_OnlyRevokerCanCall();

    uint256 unreleased = calculateVestedAmount(vestingDetails) - vestingDetails.releasedAmount;
    if (unreleased == 0) revert Vesting__NothingToRelease();

    unchecked {
      s_vestingDetails[payerToReceiverRelation].releasedAmount += unreleased;
    }

    IERC20(vestingDetails.vestedTokenAddress).safeTransfer(_receiver, unreleased);

    emit Released(_receiver, unreleased);
  }

  function calculateVestedAmount(VestingDetails memory _vestingDetails) internal view returns (uint256 _vestedAmount) {
    if (block.timestamp < _vestingDetails.cliffTimestamp) {
      _vestedAmount = 0; // @dev reassigning to zero for clarity & better code readability
    } else if (block.timestamp >= _vestingDetails.startTimestamp + _vestingDetails.totalVestingDuration) {
      _vestedAmount = _vestingDetails.totalVestedAmount;
    } else {
      unchecked {
        _vestedAmount =
          (_vestingDetails.totalVestedAmount * (block.timestamp - _vestingDetails.startTimestamp)) /
          _vestingDetails.totalVestingDuration;
      }
    }
  }

  function calculateReleasableAmount(address _payer, address _receiver) public view returns (uint256) {
    bytes32 payerToReceiverRelation = keccak256(abi.encodePacked(_payer, _receiver));
    VestingDetails memory vestingDetails = s_vestingDetails[payerToReceiverRelation];

    return calculateVestedAmount(vestingDetails) - vestingDetails.releasedAmount;
  }
}
