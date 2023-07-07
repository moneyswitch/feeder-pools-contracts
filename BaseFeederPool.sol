// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.19;

// Import Interfaces
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Vaultable} from "../Vaultable.sol";
import {IMasterPool} from "../interfaces/IMasterPool.sol";
import {IFeederPool} from "../interfaces/IFeederPool.sol";
import {IDataVault} from "../interfaces/IDataVault.sol";

import {ContractType} from "../enums/ContractType.sol";

import {RewardLocker} from "../rewards/RewardLocker.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {Errors} from "../utils/Errors.sol";
import {Validators} from "../utils/Validators.sol";

/// @title BaseFeederPool - Base Feeder Pool contract
abstract contract BaseFeederPool is RewardLocker, IFeederPool {
    using SafeERC20 for IERC20;

    IERC20 private immutable _liquidityAsset;
    uint8 private immutable _liquidityAssetDecimals;

    IMasterPool private immutable _masterPool;
    uint256 private _impairmentRank; // 0 = lowest rank.

    // Boolean set to false when pool is fully impaired (can't be reversed)
    bool internal _active;

    // Governance booleans to control deposits and withdraws of interest and rewards
    bool internal _interestDepositsStatus = true; // allow deposits of interest
    bool internal _interestWithdrawStatus = true; // allow withdraws of interest

    // Variables related to interest
    mapping(address => uint256) internal _depositorInterestUnits; // amount of units owed in interest pool
    uint256 internal _feederPoolValue; // the feeder pool value (updated by checking masterPool)
    uint256 internal _interestUnitTotal; // amount of units in interest pool

    // Operation Events
    event Deposited(
        address indexed depositor,
        uint256 amount,
        uint256 mintInterestUnits
    );
    event Withdrawn(
        address indexed depositor,
        uint256 amount,
        int256 interest,
        uint256 burnInterestUnits
    );
    event InterestUnitTotalChanged(uint256 interestUnitTotal);
    event ValueChanged(uint256 value);
    event ImpairmentRankChanged(uint256 impairmentRank);

    event InterestDepositStatusChanged(bool status);
    event InterestWithdrawStatusChanged(bool status);

    // Governance Events
    event Deactivated();

    // errors
    error InactiveDeposits();
    error DeactivatePool();
    error InactiveWithdraw();
    error InsufficientFunds();
    error InvalidIMPRank();

    // Modifiers
    modifier allowDeposit() virtual {
        _;
    }

    modifier allowWithdraw() virtual {
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
    ) RewardLocker(dataVault_, tokensPerSecond_) {
        _impairmentRank = impairmentRank_;
        _liquidityAsset = masterPool_.liquidityAsset();
        _masterPool = masterPool_;
        _liquidityAsset.approve(address(_masterPool), type(uint256).max);
        _liquidityAssetDecimals = IERC20Metadata(address(_liquidityAsset))
            .decimals();
        _active = true;
    }

    /************************/
    /*** Transactional Functions for Lenders ***/
    /************************/

    /**
        @dev    Lender depositing into the Feeder Pool.
        @param  amount_ Amount a lender wishes to deposit into the Feeder Pool.
    */
    function deposit(uint256 amount_) external allowDeposit {
        if (!_interestDepositsStatus) revert InactiveDeposits(); // check pool open to deposits
        if (!_active) revert DeactivatePool(); // check pool not deactivated.
        Validators.isNonZero(amount_);

        _masterPool.updateMasterValueFromExternal();

        _updateRewardFactorLocal(); // update the token factor for time since last transaction

        uint256 newUnits_ = 0;
        // First depositor into feeder pool distributed same units as their principal
        if (_interestUnitTotal == 0) {
            _mintInterestUnits(msg.sender, amount_); // mint the first interest units in the pool
            newUnits_ = amount_;
        } else {
            newUnits_ =
                (amount_ * _interestUnitTotal) /
                (_masterPool.getFeederPoolValue()); // calculate new interest units to mint
            _mintInterestUnits(msg.sender, newUnits_); // mint more interest units in the pool
        }

        // Adjust the depositors reward Factor for new deposit
        _depositorRewardFactor[msg.sender] =
            ((_rewardFactorLocal * amount_) +
                (_depositorRewardFactor[msg.sender] *
                    _principalDeposits[msg.sender])) /
            (amount_ + _principalDeposits[msg.sender]);

        _principalDeposits[msg.sender] += amount_; // update the principal deposited by this depositor
        _principalDepositTotal += amount_; // update total amount of principal in interest pool

        // Transfer funds, and make feeder deposit into masterPool
        _liquidityAsset.safeTransferFrom(msg.sender, address(this), amount_);
        _masterPool.depositFeeder(amount_);
        _updateFeederPoolValue();

        emit Deposited(msg.sender, amount_, newUnits_);
    }

    /**
        @dev    Depositor requests to withdraw total amount.
        @param  amount_ Total amount a lender wishes to withdraw from the Pool.
    */
    function withdrawInterestPrincipal(uint256 amount_) external allowWithdraw {
        if (!_interestWithdrawStatus) revert InactiveWithdraw(); // check pool open to withdraw
        if (!_active) revert DeactivatePool(); // check pool not deactivated.
        Validators.isNonZero(amount_);

        _masterPool.updateMasterValueFromExternal();

        _updateRewardFactorLocal(); // update the token factor for time since last transaction

        // Calculate total balance (units in feeder pool vs. total) of depositor and check they have enough funds
        uint256 totalBalance_ = _calculateBalance(msg.sender);

        if (amount_ >= totalBalance_) revert InsufficientFunds();

        // Calculate amount of interest units to sell for depositor to generate amount
        uint256 unitsBurn_ = (amount_ * _interestUnitTotal) /
            _masterPool.getFeederPoolValue();

        // Calculate associated amount of principal being sold from interest and reward pool (proportional)
        uint256 principalWithdraw_ = (unitsBurn_ *
            _principalDeposits[msg.sender]) /
            _depositorInterestUnits[msg.sender];

        _withdraw(principalWithdraw_, amount_, unitsBurn_);
    }

    /**
        @dev    Depositor wishes to withdraw everything.
    */
    function withdrawAll() external allowWithdraw {
        if (!_interestWithdrawStatus) revert InactiveWithdraw(); // check pool open to withdraw
        if (!_active) revert DeactivatePool(); // check pool not deactivated.
        Validators.isNonZero(_depositorInterestUnits[msg.sender]);

        _masterPool.updateMasterValueFromExternal();

        _updateRewardFactorLocal(); // update the token factor for time since last transaction

        // Calculate amount depositor recieves based on their units
        uint256 amount_ = ((_depositorInterestUnits[msg.sender] *
            _masterPool.getFeederPoolValue()) / _interestUnitTotal);
        uint256 unitsBurn_ = _depositorInterestUnits[msg.sender];
        // Calculate associated amount of principal being sold from interest and reward pool

        _withdraw(_principalDeposits[msg.sender], amount_, unitsBurn_);
    }

    /**
        @dev    Updates state variables when withdrawal made.
        @param  principalWithdraw_ Amount of interest principal being sold.
        @param  amount_ The total amount of funds owed to the depositor.
    */
    function _withdraw(
        uint256 principalWithdraw_,
        uint256 amount_,
        uint256 unitsBurn_
    ) internal {
        // Move associated reward into the depositor reward locker and reduce depositor reward principal and total reward prinicipal
        _depositorRewardLocker[msg.sender] +=
            (principalWithdraw_ *
                (_rewardFactorLocal - _depositorRewardFactor[msg.sender])) /
            _WAD;

        // reduce the depositor interest principal by the amount sold and reduce total principal in interest pool
        _principalDeposits[msg.sender] -= principalWithdraw_;
        _principalDepositTotal -= principalWithdraw_;

        // burn interest units
        _burnInterestUnits(msg.sender, unitsBurn_);

        // Make feeder pool deposit into masterPool and transfer funds
        _masterPool.withdrawFeeder(amount_);

        _updateFeederPoolValue(); // get latest value of feeder pool from master pool

        _liquidityAsset.safeTransfer(msg.sender, amount_);

        // Add back rounding to amount.
        emit Withdrawn(
            msg.sender,
            principalWithdraw_,
            int256(amount_ + 1) - int256(principalWithdraw_),
            unitsBurn_
        );
    }

    /************************/
    /*** Minting and Burning Functions for Interest Units ***/
    /************************/

    /**
        @dev    Control minting process for units in interest pool as result of deposit into feeder pool.
        @param  depositor_ Address of depostor.
        @param  amount_ Amount a lender wishes to deposit into the feeder pool.
    */
    function _mintInterestUnits(address depositor_, uint256 amount_) internal {
        // no rounding adjustment needs to occur here as everything has already been rounded down
        _depositorInterestUnits[depositor_] += amount_;
        _interestUnitTotal += amount_;

        emit InterestUnitTotalChanged(_interestUnitTotal);
    }

    /**
        @dev    Control burning process for units in interest pool as result of deposit into feeder pool.
        @param  depositor_ Address of depositor.
        @param  amount_ Amount a lender wishes to deposit into the feeder pool.
    */
    function _burnInterestUnits(address depositor_, uint256 amount_) internal {
        // Check we can apply rounding adjustment
        if (
            amount_ == _interestUnitTotal ||
            amount_ == _depositorInterestUnits[depositor_]
        ) {
            _depositorInterestUnits[depositor_] -= amount_;
            _interestUnitTotal -= amount_;
        } else {
            // Burn an extra unit to avoid people gaining monies
            _depositorInterestUnits[depositor_] -= amount_ + 1;
            _interestUnitTotal -= amount_ + 1;
        }

        emit InterestUnitTotalChanged(_interestUnitTotal);
    }

    /************************/
    /*** Helper Functions for Calculations ***/
    /************************/

    /**
        @dev    Get the latest value of the feeder pool from the master pool.
    */
    function _updateFeederPoolValue() internal {
        _feederPoolValue = _masterPool.getFeederPoolValue();

        emit ValueChanged(_feederPoolValue);
    }

    /**
        @dev    Used to calculated the balance of an depositor.
        @param  depositor_ Lender address.
    */
    function _calculateBalance(address depositor_)
        internal
        view
        returns (uint256)
    {
        if (_active && _interestUnitTotal > 0) {
            return
                (_depositorInterestUnits[depositor_] * _masterPool.getFeederPoolValue()) /
                (_interestUnitTotal);
        }
        return 0;
    }

    /************************/
    /*** Governance Functions ***/
    /************************/

    /**
        @dev    Set status of activity for deposits into interest pool.
        @param  status_ new status.
    */
    function setInterestDepositStatus(bool status_) external onlyAllOperator {
        if (_interestDepositsStatus == status_) revert Errors.InvalidStatus();
        _interestDepositsStatus = status_;

        emit InterestDepositStatusChanged(status_);
    }

    /**
        @dev    Set status of activity for withdraws out of interest pool.
        @param  status_ new status.
    */
    function setInterestWithdrawStatus(bool status_) external onlyAllOperator {
        if (_interestWithdrawStatus == status_) revert Errors.InvalidStatus();
        _interestWithdrawStatus = status_;

        emit InterestWithdrawStatusChanged(status_);
    }

    /**
        @dev    Set impairment rank of feeder pool.
        @param  impairmentRank_ new impairment rank.
    */
    function setImpairmentRank(uint256 impairmentRank_)
        external
        onlyAllOperator
    {
        if (_impairmentRank == impairmentRank_) revert InvalidIMPRank();
        _impairmentRank = impairmentRank_;

        emit ImpairmentRankChanged(_impairmentRank);
    }

    /**
        @dev    Deactive pool - called when pool fully impaired, effectively makes it inaccessible to access interest units.
    */
    function deactivate() external {
        if (msg.sender != dataVault.getContract(ContractType.MasterLiquidator))
            revert Errors.Unauthorized();

        _active = false;
        emit Deactivated();
    }

    /************************/
    /*** Getter / Setter Functions ***/
    /************************/

    /**
        @dev    Gets earned interest for depositor up until latest block.
        @param  depositor_ Lender address.
    */
    function getEarnedInterest(address depositor_)
        public
        view
        returns (uint256)
    {
        // get the total balance of the lender
        uint256 totalBalance_ = getTotalBalance(depositor_);
        if (_active && totalBalance_ >= _principalDeposits[depositor_]) {
            return totalBalance_ - _principalDeposits[depositor_];
        }
        return 0;
    }

    /**
        @dev    Gets balance for depositor up until latest block.
        @param  depositor_ Lender address.
    */
    function getTotalBalance(address depositor_) public view returns (uint256) {
        if (_active && _interestUnitTotal > 0) {
            uint256 tempFeederPoolValue = _masterPool.getFeederPoolValueLatest(
                address(this)
            );
            return
                (_depositorInterestUnits[depositor_] * tempFeederPoolValue) /
                (_interestUnitTotal);
        }
        return 0;
    }

    /**
        @dev    Returns the master pool.
    */
    function masterPool() external view returns (IMasterPool) {
        return _masterPool;
    }

    /**
        @dev    Returns true.
    */
    function isFeederPool() external pure returns (bool) {
        return true;
    }

    /**
        @dev    Get Liquidity Asset.
    */
    function liquidityAsset() external view returns (IERC20) {
        return _liquidityAsset;
    }

    /**
        @dev    Get Liquidity Asset Decimals.
    */
    function liquidityAssetDecimals() external view returns (uint8) {
        return _liquidityAssetDecimals;
    }

    /**
        @dev    Get Total Interest Units
    */
    function interestUnitTotal() external view returns (uint256) {
        return _interestUnitTotal;
    }

    /**
        @dev    Get Last Feeder Pool Value
    */
    function value() external view returns (uint256) {
        return _feederPoolValue;
    }

    /**
        @dev    Get activity status
    */
    function activeStatus() external view returns (bool) {
        return _active;
    }

    /**
        @dev    Get impairment rank
    */
    function impairmentRank() external view returns (uint256) {
        return _impairmentRank;
    }

    /**
        @dev    Get principal deposit total
    */
    function principalDepositTotal() external view returns (uint256) {
        return _principalDepositTotal;
    }

    /**
        @dev    Get Depositor Interest Principal
    */
    function principalDeposits(address depositor_)
        external
        view
        returns (uint256)
    {
        return _principalDeposits[depositor_];
    }

    /**
        @dev    Get Depositor Interest Units
    */
    function depositorInterestUnits(address depositor_)
        external
        view
        returns (uint256)
    {
        return _depositorInterestUnits[depositor_];
    }
}
