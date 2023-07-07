// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.19;

// Import Interfaces
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Vaultable} from "../Vaultable.sol";
import {IMasterPool} from "../interfaces/IMasterPool.sol";
import {IFeederPool} from "../interfaces/IFeederPool.sol";
import {IDataVault} from "../interfaces/IDataVault.sol";
import {BaseFeederPool} from "./BaseFeederPool.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FeederPool - Maintains all accounting and functionality related to FeederPools.
contract FeederPoolWL is BaseFeederPool {
    // depositor white list
    mapping(address => bool) private _depositorWhiteList;

    // Events
    event DepositorWhiteListChanged(address indexed depositor, bool status);

    // Errors
    error NotWhiteList();

    // Modifiers
    modifier allowDeposit() override {
        if (!_depositorWhiteList[msg.sender]) revert NotWhiteList();
        _;
    }

    modifier allowWithdraw() override {
        if (!_depositorWhiteList[msg.sender]) revert NotWhiteList();
        _;
    }

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

    /************************/
    /*** Governance Functions ***/
    /************************/

    /**
        @dev    Change state of depositor in white list.
        @param  depositor_ Address of depositor.
        @param  status_ New status of depositor.
    */
    function setDepositorWhiteList(address depositor_, bool status_)
        external
        onlyAllOperator
    {
        _depositorWhiteList[depositor_] = status_;

        emit DepositorWhiteListChanged(depositor_, status_);
    }
}
