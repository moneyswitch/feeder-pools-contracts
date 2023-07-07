// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.19;

// Import Interfaces
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Vaultable} from "../Vaultable.sol";
import {IMasterPool} from "../interfaces/IMasterPool.sol";
import {IDataVault} from "../interfaces/IDataVault.sol";
import {BaseFeederPool} from "./BaseFeederPool.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FeederPool - Maintains all accounting and functionality related to FeederPools.
contract FeederPool is BaseFeederPool {
    /**
        @dev    Constructor.
        @param  dataVault_ DataVault used for storage.
        @param  masterPool_ Address of master Pool related to this Feeder pool.
    */
    constructor(
        IDataVault dataVault_,
        uint256 impairmentRank_, // 0 = lowest rank
        uint256 tokensPerSecond_,
        IMasterPool masterPool_
    )
        BaseFeederPool(
            dataVault_,
            impairmentRank_,
            tokensPerSecond_,
            masterPool_
        )
    {}
}
