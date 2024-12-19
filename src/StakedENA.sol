// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "./SingleAdminAccessControlUpgradeable.sol";
import "./interfaces/IStakedENA.sol";
import "./ENASilo.sol";

/**
 * @title StakedENA
 * @notice The StakedENA contract allows users to stake ENA tokens
 */
contract StakedENA is
  SingleAdminAccessControlUpgradeable,
  ReentrancyGuardUpgradeable,
  ERC20PermitUpgradeable,
  ERC4626Upgradeable,
  IStakedENA
{
  using SafeERC20Upgradeable for IERC20Upgradeable;

  /* ------------- CONSTANTS ------------- */
  /// @notice In addition to roles below, DEFAULT_ADMIN_ROLE is used for the owner of the contract 
  /// has several powers.  Some view this as over-centralization, but we have elected for a simple 
  /// well-secured admin
  /// @notice The role that is allowed to distribute rewards to this contract
  bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
  /// @notice The role that is allowed to blacklist and un-blacklist addresses
  bytes32 public constant BLACKLIST_MANAGER_ROLE = keccak256("BLACKLIST_MANAGER_ROLE");
  /// @notice The role which prevents an address to transfer, stake, or unstake. The owner of the contract can redirect address staking balance if an address is blacklisted.
  bytes32 public constant BLACKLISTED_ROLE = keccak256("BLACKLISTED_ROLE");
  /// @notice Minimum non-zero shares amount to prevent donation attack
  uint64 private constant _MIN_SHARES = 1 ether;
  /// @notice Max allowed configurable vesting period
  uint24 public constant MAX_VESTING_PERIOD = 90 days;
  uint24 public constant MAX_COOLDOWN_DURATION = 90 days;

  /* ------------- STATE VARIABLES ------------- */

  /// @notice The amount of the last asset distribution from the controller contract into this
  /// contract + any unvested remainder at that time
  uint256 public vestingAmount;
  /// @notice The timestamp of the last asset distribution from the controller contract into this contract
  uint256 public lastDistributionTimestamp;
  /// @notice The vesting period of vestingAmount over which it increasingly becomes available to stakers
  uint24 public vestingPeriod;
  /// @notice Amount of time that the user needs to wait after calling "cooldownShares" or "cooldownAssets" in order to claim the underlying asset
  uint24 public cooldownDuration;
  /// @notice The Silo stores ENA during the cooldown process
  EnaSilo public silo;

  mapping(address => UserCooldown) public cooldowns;

  /// @notice ensure cooldownDuration is zero
  modifier ensureCooldownOff() {
    if (cooldownDuration != 0) revert OperationNotAllowed();
    _;
  }

  /// @notice ensure cooldownDuration is gt 0
  modifier ensureCooldownOn() {
    if (cooldownDuration == 0) revert OperationNotAllowed();
    _;
  }

  /// @notice ensure input amount nonzero
  modifier notZero(uint256 amount) {
    if (amount == 0) revert InvalidAmount();
    _;
  }

  /// @notice ensures blacklist target is not owner
  modifier notOwner(address target) {
    if (target == owner()) revert CantBlacklistOwner();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /* ------------- INITIALIZE ------------- */

  /**
   * @notice Initializer for StakedENA contract.
   * @param _asset The address of the ENA token.
   * @param _initialRewarder The address of the initial rewarder.
   * @param _owner The address of the admin role.
   *
   */
  function initialize(IERC20Upgradeable _asset, address _initialRewarder, address _owner) public initializer {
    __ERC20_init("Staked ENA", "sENA");
    __ERC4626_init(_asset);
    __ERC20Permit_init("sENA");
    __ReentrancyGuard_init();

    if (_owner == address(0) || _initialRewarder == address(0) || address(_asset) == address(0)) {
      revert InvalidZeroAddress();
    }
    silo = new EnaSilo(address(this), address(_asset));
    _updateVestingPeriod(7 days);
    _grantRole(REWARDER_ROLE, _initialRewarder);
    _grantRole(DEFAULT_ADMIN_ROLE, _owner);
    cooldownDuration = 7 days;
  }

  /* ------------- EXTERNAL ------------- */

  /**
   * @dev See {IERC4626-withdraw}.
   */
  function withdraw(uint256 assets, address receiver, address _owner)
    public
    virtual
    override
    ensureCooldownOff
    returns (uint256)
  {
    return super.withdraw(assets, receiver, _owner);
  }

  /**
   * @dev See {IERC4626-redeem}.
   */
  function redeem(uint256 shares, address receiver, address _owner)
    public
    virtual
    override
    ensureCooldownOff
    returns (uint256)
  {
    return super.redeem(shares, receiver, _owner);
  }

  /**
   * @notice Claim the staking amount after the cooldown has finished. The address can only retire the full amount of assets.
   * No attempt is made to restrict blacklisted addresses from claiming their assets at this point as the assets have already
   * been converted to ENA and ENA is a permissionless token.
   * @dev unstake can be called after cooldown have been set to 0, to let accounts to be able to claim remaining assets locked at Silo
   * @param receiver Address to send the assets by the staker
   */
  function unstake(address receiver) external nonReentrant {
    UserCooldown storage userCooldown = cooldowns[msg.sender];
    uint256 assets = userCooldown.underlyingAmount;

    if (block.timestamp >= userCooldown.cooldownEnd || cooldownDuration == 0) {
      userCooldown.cooldownEnd = 0;
      userCooldown.underlyingAmount = 0;

      silo.withdraw(receiver, assets);
      emit Unstake(msg.sender, receiver, assets);
    } else {
      revert InvalidCooldown();
    }
  }

  /// @notice redeem assets and starts a cooldown to claim the converted underlying asset
  /// @param assets assets to redeem
  function cooldownAssets(uint256 assets) external ensureCooldownOn returns (uint256 shares) {
    if (assets > maxWithdraw(msg.sender)) revert ExcessiveWithdrawAmount();

    shares = previewWithdraw(assets);

    cooldowns[msg.sender].cooldownEnd = uint104(block.timestamp) + cooldownDuration;
    cooldowns[msg.sender].underlyingAmount += uint152(assets);

    _withdraw(msg.sender, address(silo), msg.sender, assets, shares);
    emit CooldownStarted(msg.sender, assets, shares);
  }

  /// @notice redeem shares into assets and starts a cooldown to claim the converted underlying asset
  /// @param shares shares to redeem
  function cooldownShares(uint256 shares) external ensureCooldownOn returns (uint256 assets) {
    if (shares > maxRedeem(msg.sender)) revert ExcessiveRedeemAmount();

    assets = previewRedeem(shares);

    cooldowns[msg.sender].cooldownEnd = uint104(block.timestamp) + cooldownDuration;
    cooldowns[msg.sender].underlyingAmount += uint152(assets);

    _withdraw(msg.sender, address(silo), msg.sender, assets, shares);
    emit CooldownStarted(msg.sender, assets, shares);
  }

  /// @notice Set cooldown duration. If cooldown duration is set to zero, the contract behavior changes to follow ERC4626 standard and disables cooldownShares and cooldownAssets methods. If cooldown duration is greater than zero, the ERC4626 withdrawal and redeem functions are disabled, breaking the ERC4626 standard, and enabling the cooldownShares and the cooldownAssets functions.
  /// @param duration Duration of the cooldown
  function setCooldownDuration(uint24 duration) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
    if (duration > MAX_COOLDOWN_DURATION) {
      revert InvalidCooldown();
    }

    uint24 previousDuration = cooldownDuration;
    cooldownDuration = duration;
    emit CooldownDurationUpdated(previousDuration, cooldownDuration);
  }

  /**
   * @notice Allows the owner to update the vesting period.
   * @param newVestingPeriod The new vesting period.
   */
  function updateVestingPeriod(uint24 newVestingPeriod) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
    _updateVestingPeriod(newVestingPeriod);
  }

  /**
   * @notice Allows the owner to transfer rewards from the controller contract into this contract.
   * @param amount The amount of rewards to transfer.
   */
  function transferInRewards(uint256 amount) external nonReentrant onlyRole(REWARDER_ROLE) notZero(amount) {
    _updateVestingAmount(amount);
    // transfer assets from rewarder to this contract
    IERC20Upgradeable(asset()).safeTransferFrom(msg.sender, address(this), amount);

    emit RewardsReceived(amount);
  }

  /**
   * @notice Allows blacklist managers to blacklist addresses.
   * @notice It is deemed acceptable for a pending owner to be blacklisted.  The pending owner can unblacklist
   * themselves upon receiving ownership.
   * @param target The address to blacklist.
   */
  function addToBlacklist(address target) external nonReentrant onlyRole(BLACKLIST_MANAGER_ROLE) notOwner(target) {
    _grantRole(BLACKLISTED_ROLE, target);
  }

  /**
   * @notice Allows blacklist managers to un-blacklist addresses.
   * @param target The address to un-blacklist.
   */
  function removeFromBlacklist(address target) external nonReentrant onlyRole(BLACKLIST_MANAGER_ROLE) {
    _revokeRole(BLACKLISTED_ROLE, target);
  }

  /**
   * @notice Allows the owner to rescue tokens accidentally sent to the contract.
   * Note that the owner cannot rescue ENA tokens because they functionally sit here
   * and belong to stakers but can rescue staked ENA as they should never actually
   * sit in this contract and a staker may well transfer them here by accident.
   * @param token The token to be rescued.
   * @param amount The amount of tokens to be rescued.
   * @param to Where to send rescued tokens
   */
  function rescueTokens(address token, uint256 amount, address to) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
    if (address(token) == asset()) revert InvalidToken();
    IERC20Upgradeable(token).safeTransfer(to, amount);
    emit TokensRescued(token, to, amount);
  }

  /**
   * @dev Burns the blacklisted user amount and mints to the desired owner address.
   * @param from The address to burn the entire balance, with the BLACKLISTED_ROLE
   * @param to The address to mint the entire balance of "from" parameter.
   */
  function redistributeLockedAmount(address from, address to) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
    if (!hasRole(BLACKLISTED_ROLE, from) || hasRole(BLACKLISTED_ROLE, to)) revert OperationNotAllowed();
    uint256 amountToDistribute = balanceOf(from);
    if(amountToDistribute == 0) revert InvalidAmount();
    uint256 enaToVest = previewRedeem(amountToDistribute);
    _burn(from, amountToDistribute);
    // to address of address(0) enables burning
    if (to == address(0)) {
      _updateVestingAmount(enaToVest);
    } else {
      _mint(to, amountToDistribute);
    }

    emit StakedENARedistributed(from, to, amountToDistribute);
  }

  /**
   * @dev Allows a user to increment their nonce, cancelling any permit signatures before the specified deadline.
   */
  function useNonce() external returns (uint256) {
      return _useNonce(msg.sender);
  }

  /* ------------- PUBLIC ------------- */

  /**
   * @notice Returns the amount of ENA tokens that are vested in the contract.
   */
  function totalAssets() public view override returns (uint256) {
    return IERC20Upgradeable(asset()).balanceOf(address(this)) - getUnvestedAmount();
  }

  /**
   * @notice Returns the amount of ENA tokens that are unvested in the contract.
   */
  function getUnvestedAmount() public view returns (uint256) {
    uint256 timeSinceLastDistribution = block.timestamp - lastDistributionTimestamp;
    if (timeSinceLastDistribution >= vestingPeriod) {
      return 0;
    }

    uint256 deltaT;
    unchecked {
      deltaT = (vestingPeriod - timeSinceLastDistribution);
    }
    return (deltaT * vestingAmount) / vestingPeriod;
  }

  /// @dev Necessary because both ERC20 (from ERC20Permit) and ERC4626 declare decimals()
  function decimals() public pure override(ERC4626Upgradeable, ERC20Upgradeable) returns (uint8) {
    return 18;
  }

  /**
   * @dev Remove renounce role access from AccessControl, to prevent users to resign roles.
   * @notice It's deemed preferable security-wise to ensure the contract maintains an owner, 
   * over the ability to renounce roles, role renunciation can be achieved via owner revoking the role.
   */
  function renounceRole(bytes32, address) public virtual override {
    revert OperationNotAllowed();
  }

  /* ------------- INTERNAL ------------- */

  /**
   * @notice ensures a small non-zero amount of shares does not remain, exposing to donation attack
   * This should never happen due to the initial deposit to the dead address
   */
  function _checkMinShares() internal view {
    uint256 _totalSupply = totalSupply();
    if (_totalSupply > 0 && _totalSupply < _MIN_SHARES) revert MinSharesViolation();
  }

  /**
   * @dev Deposit/mint common workflow.
   * @param caller sender of assets
   * @param receiver where to send shares
   * @param assets assets to deposit
   * @param shares shares to mint
   */
  function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
    internal
    override
    nonReentrant
    notZero(assets)
    notZero(shares)
  {
    super._deposit(caller, receiver, assets, shares);
    _checkMinShares();
  }

  /**
   * @dev Withdraw/redeem common workflow.
   * @param caller tx sender
   * @param receiver where to send assets
   * @param _owner where to burn shares from
   * @param assets asset amount to transfer out
   * @param shares shares to burn
   */
  function _withdraw(address caller, address receiver, address _owner, uint256 assets, uint256 shares)
    internal
    override
    nonReentrant
    notZero(assets)
    notZero(shares)
  {
    if (hasRole(BLACKLISTED_ROLE, _owner) || hasRole(BLACKLISTED_ROLE, receiver)) {
      revert OperationNotAllowed();
    }

    super._withdraw(caller, receiver, _owner, assets, shares);
    _checkMinShares();
  }

  /**
   * @dev Update the vesting amount and reset the last distribution timestamp.
   * @param newVestingAmount The new vesting amount.
   */
  function _updateVestingAmount(uint256 newVestingAmount) internal {
    if (getUnvestedAmount() > 0) revert StillVesting();

    vestingAmount = newVestingAmount;
    lastDistributionTimestamp = block.timestamp;
  }

  /**
   * @dev Update the vesting period.
   * @param newVestingPeriod The new vesting period.
   */
  function _updateVestingPeriod(uint24 newVestingPeriod) internal {
    if (getUnvestedAmount() > 0) revert StillVesting();
    if (newVestingPeriod > MAX_VESTING_PERIOD) revert InvalidVestingPeriod();
    emit VestingDurationUpdated(vestingPeriod, newVestingPeriod);
    vestingPeriod = newVestingPeriod;
  }

  /**
   * @dev Hook that is called before any transfer of tokens. This includes
   * minting and burning. Disables transfers from or to of addresses with the BLACKLISTED_ROLE role.
   */
  function _beforeTokenTransfer(address from, address to, uint256) internal virtual override {
    if (hasRole(BLACKLISTED_ROLE, msg.sender)) {
      revert OperationNotAllowed();
    }
    if (hasRole(BLACKLISTED_ROLE, from) && to != address(0)) {
      revert OperationNotAllowed();
    }
    if (hasRole(BLACKLISTED_ROLE, to)) {
      revert OperationNotAllowed();
    }
  }
}