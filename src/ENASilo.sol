// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IEnaSiloDefinitions.sol";

/**
 * @title EnaSilo
 * @notice The Silo allows to store ENA during the stake cooldown process.
 */
contract EnaSilo is IEnaSiloDefinitions {
  address immutable _STAKING_VAULT;
  IERC20 immutable _ENA;

  constructor(address stakingVault, address ena) {
    _STAKING_VAULT = stakingVault;
    _ENA = IERC20(ena);
  }

  modifier onlyStakingVault() {
    if (msg.sender != _STAKING_VAULT) revert OnlyStakingVault();
    _;
  }

  function withdraw(address to, uint256 amount) external onlyStakingVault {
    _ENA.transfer(to, amount);
  }
}