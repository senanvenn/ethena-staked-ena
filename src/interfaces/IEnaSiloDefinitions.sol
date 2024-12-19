// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

interface IEnaSiloDefinitions {
  /// @notice Error emitted when the staking vault is not the caller
  error OnlyStakingVault();
}