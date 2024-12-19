// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import "./IStakedUSDeCooldown.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IStakedENA is IERC20Upgradeable {
  // Events //
  /// @notice Event emitted when the rewards are received
  event RewardsReceived(uint256 amount);
  /// @notice Event emitted when the balance from an BLACKLISTED_ROLE user are redistributed
  event StakedENARedistributed(address indexed from, address indexed to, uint256 amount);
  /// @notice Event emitted when cooldown duration updates
  event CooldownDurationUpdated(uint24 previousDuration, uint24 newDuration);
  /// @notice Event emitted when vesting duration updates
  event VestingDurationUpdated(uint24 previousDuration, uint24 newDuration);
  /// @notice Event emitted when a user unstakes
  event Unstake(address indexed unstaker, address indexed receiver, uint256 amount);
  /// @notice Event emitted when a user starts cooldown
  event CooldownStarted(address indexed cooler, uint256 assets, uint256 shares);
  /// @notice Event emitted when a owner rescues tokens
  event TokensRescued(address indexed token, address indexed to, uint256 amount);

  // Errors //
  /// @notice Error emitted shares or assets equal zero.
  error InvalidAmount();
  /// @notice Error emitted when owner attempts to rescue ENA tokens.
  error InvalidToken();
  /// @notice Error emitted when a small non-zero share amount remains, which risks donations attack
  error MinSharesViolation();
  /// @notice Error emitted when owner is not allowed to perform an operation
  error OperationNotAllowed();
  /// @notice Error emitted when there is still unvested amount
  error StillVesting();
  /// @notice Error emitted when owner or blacklist manager attempts to blacklist owner
  error CantBlacklistOwner();
  /// @notice Error emitted when the zero address is given
  error InvalidZeroAddress();
  /// @notice Error emitted when the shares amount to redeem is greater than the shares balance of the owner
  error ExcessiveRedeemAmount();
  /// @notice Error emitted when the shares amount to withdraw is greater than the shares balance of the owner
  error ExcessiveWithdrawAmount();
  /// @notice Error emitted when cooldown value is invalid
  error InvalidCooldown();
  /// @notice Error emitted when vesting period is invalid
  error InvalidVestingPeriod();

  function transferInRewards(uint256 amount) external;

  function rescueTokens(address token, uint256 amount, address to) external;

  function getUnvestedAmount() external view returns (uint256);

  function cooldownAssets(uint256 assets) external returns (uint256 shares);

  function cooldownShares(uint256 shares) external returns (uint256 assets);

  function unstake(address receiver) external;

  function setCooldownDuration(uint24 duration) external;

  function updateVestingPeriod(uint24 newVestingPeriod) external;

  function vestingPeriod() external view returns (uint24);
}