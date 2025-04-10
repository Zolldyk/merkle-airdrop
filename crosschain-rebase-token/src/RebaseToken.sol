// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

/**
 * @title RebaseToken
 * @author Zoll -Ola
 * @notice This is a cross-chain rebase token that incentivizes users to deposit into a wallet
 * @notice The interest rate in the smart contract can only decrease
 * @notice Each have their own interest rate that is the global interest rate at the time of depositing
 */
contract RebaseToken is ERC20, Ownable, AccessControl {
    error RebaseToken__InterestRateCanOnlyDecrease(uint256 currentRate, uint256 newRate);

    uint256 private constant PRECISION_FACTOR = 1e27;
    bytes32 private constant MINT_AND_BURN_ROLE = keccak256("MINT_AND_BURN_ROLE");
    uint256 private s_interestRate = (5 * PRECISION_FACTOR) / 1e8; // 10^-8 == 1/10^8

    mapping(address => uint256) private s_userInterestRate;
    mapping(address => uint256) private s_userLastUpdatedTimestamp;

    event InterestRateSet(uint256 newInterestRate);

    constructor() ERC20("RebaseToken", "RBT") Ownable(msg.sender) {}

    function grantMintAndBurnRole(address _account) external onlyOwner {
        _grantRole(MINT_AND_BURN_ROLE, _account);
    }

    /**
     * @notice Set the interest rate in the contract
     * @param _newInterestRate The new interest rate to be set
     * @dev The interest rate can only be decreased
     */
    function setInterestRate(uint256 _newInterestRate) external onlyOwner {
        // set the interest rate to a new variable
        if (_newInterestRate > s_interestRate) {
            revert RebaseToken__InterestRateCanOnlyDecrease(s_interestRate, _newInterestRate);
        }
        s_interestRate = _newInterestRate;
        emit InterestRateSet(_newInterestRate);
    }

    /**
     * @notice Get the principal balance of a user. This is the number of tokens that have currently being minted to the user, not including any interest that has accrued since the last time the user interacted with the protocol.
     * @param _user The user to get the principal balance for
     * @return The principal balance of the user
     */
    function principalBalanceOf(address _user) external view returns (uint256) {
        return super.balanceOf(_user);
    }

    /*
     * @notice Mint the user tokens when they deposit into the vault
     * @param _user The user to mint the tokens to
     * @param _amount The amount of tokens to mint
     * @dev
     */
    function mint(address _to, uint256 amount) external onlyRole(MINT_AND_BURN_ROLE) {
        _mintAccruedInterest(_to);
        s_userInterestRate[_to] = s_interestRate;
        _mint(_to, amount);
    }

    /**
     * @notice Burn the user tokens when they withdraw from the vault
     * @param _from The user to burn the tokens from
     * @param _amount The amount of tokens to burn
     */
    function burn(address _from, uint256 _amount) external onlyRole(MINT_AND_BURN_ROLE) {
        if (_amount == type(uint256).max) {
            _amount = balanceOf(_from);
        }
        _mintAccruedInterest(_from);
        _mint(_from, _amount);
    }

    /**
     * @notice Calculate the balance for the user including the interest that has accumulated since the last update = (principal balance) * (accrued interest)
     * @param _user The user to calculate the interest rate for
     * @return The balance of the user including the interest that has accumulated since the last update
     */
    function balanceOf(address _user) public view override returns (uint256) {
        // get the current principal balance of the user (the number of tokens that have been minted to the user)
        // multiply the principal balance by the interest that has accumulated in the time since the balance was last updated
        return super.balanceOf(_user) * _calculateUserAccumulatedInterestSinceLastUpdate(_user);
    }

    /**
     * @notice Transfer tokens from one user to another
     * @param _recepient The address of the user to transfer the tokens to
     * @param _amount The amount of tokens to transfer
     * @return True if the transfer was successful
     */
    function transfer(address _recepient, uint256 _amount) public override returns (bool) {
        _mintAccruedInterest(msg.sender);
        _mintAccruedInterest(_recepient);
        if (_amount == type(uint256).max) {
            _amount = balanceOf(msg.sender);
        }
        if (balanceOf(_recepient) == 0) {
            s_userInterestRate[_recepient] = s_userInterestRate[msg.sender];
        }
        return super.transfer(_recepient, _amount);
    }

    /**
     * @notice Transfer tokens from one user to another
     * @param _sender The user to transfer the tokens from
     * @param _recepient The user to transfer the tokens to
     * @param _amount The amount of tokens to transfer
     * @return True if the transfer was successful
     */
    function transferFrom(address _sender, address _recepient, uint256 _amount) public override returns (bool) {
        _mintAccruedInterest(_sender);
        _mintAccruedInterest(_recepient);
        if (_amount == type(uint256).max) {
            _amount = balanceOf(_sender);
        }
        if (balanceOf(_recepient) == 0) {
            s_userInterestRate[_recepient] = s_userInterestRate[_sender];
        }
        return super.transferFrom(_sender, _recepient, _amount);
    }

    /*
     * @notice Calculate the interest that has accumulated since the last update
     * @param _user The user to calculate the interest for
     * @return The interest that has accumulated since the last update
     */
    function _calculateUserAccumulatedInterestSinceLastUpdate(address _user)
        internal
        view
        returns (uint256 linearInterest)
    {
        // we need to calculate the interest that has accumulated since the last update
        // this is going to be linear growth with time
        // 1. calculate the time since the last update
        // 2. calculate the amount of linear growth
        // (principal amount) + (principal amount * user interest rate * time since last update)
        uint256 timeElapsed = block.timestamp - s_userLastUpdatedTimestamp[_user];
        linearInterest = (PRECISION_FACTOR + (s_userInterestRate[_user] * timeElapsed)) / PRECISION_FACTOR;
    }

    /**
     * @notice Mint the accrued interest to the user since the last time they interacted with the protocol(e.g. burn, mint, transfer)
     * @param _user The user to mint the accrued interest to
     */
    function _mintAccruedInterest(address _user) internal {
        // (1) find their current balance of rebase token that have been minted to the user -> principal balance
        uint256 previousPrincipalBalance = super.balanceOf(_user);
        // (2) calculate their current balance including any interest. -> balanceOf
        uint256 currentBalance = balanceOf(_user);
        // calculate the number of tokens to be minted to the user -> (2) - (1)
        uint256 balanceIncrease = currentBalance - previousPrincipalBalance;
        // set the user's last updated timestamp
        s_userLastUpdatedTimestamp[_user] = block.timestamp;
        // call _mint to mint the tokens to the user
        _mint(_user, balanceIncrease);
    }

    /**
     * @notice Get the interest rate that is currently set for the contract. Any future depositors will receive this interest rate
     * @return The interest rate for the contract
     */
    function getInterestRate() external view returns (uint256) {
        return s_interestRate;
    }

    /*
     * @notice Get the interest rate for the user
     * @param _user The user to get the interest rate for
     * @dev The interest rate for the user
     */
    function getUserInterestRate(address user) external view returns (uint256) {
        return s_userInterestRate[user];
    }
}
