// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.19;

import "./IStWSX.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


/**
 * @title stWSX token wrapper with static balances.
 * @dev It's an ERC20 token that represents the account's share of the total
 * supply of stWSX tokens. WstWSX token's balance only changes on transfers,
 * unlike StWSX that is also changed when oracles report staking rewards and
 * penalties. It's a "power user" token for DeFi protocols which don't
 * support rebasable tokens.
 *
 * The contract is also a trustless wrapper that accepts stWSX tokens and mints
 * wstWSX in return. Then the user unwraps, the contract burns user's wstWSX
 * and sends user locked stWSX in return.
 *
 *
 */
contract WstWSX is ERC20{

    IStWSX public stWSX; // the target token we will wrap
    uint256 private constant ONE_TOKEN = 10 ** 18; // Value of 1 complete token

    /**
     * @param _stWSX address of the StWSX token to wrap
     */
    constructor(IStWSX _stWSX) ERC20("Wrapped liquid staked WSX", "wstWSX") {
        stWSX = _stWSX;
    }

    /**
     * @notice Exchanges stWSX to wstWSX
     * @param _stWSXAmount amount of stWSX to wrap in exchange for wstWSX
     * @dev Requirements:
     *  - `_stWSXAmount` must be non-zero
     *  - msg.sender must approve at least `_stWSXAmount` stWSX to this
     *    contract.
     *  - msg.sender must have at least `_stWSXAmount` of stWSX.
     * User should first approve _stWSXAmount to the WstWSX contract
     * @return Amount of wstWSX user receives after wrap
     */
    function wrap(uint256 _stWSXAmount) external returns (uint256) {
        require(_stWSXAmount > 0, "wstWSX: can't wrap zero stWSX");
        uint256 wstWSXAmount = stWSX.getSharesByPooledWSX(_stWSXAmount);
        _mint(msg.sender, wstWSXAmount);
        stWSX.transferFrom(msg.sender, address(this), _stWSXAmount);

        emit Wrap(msg.sender, _stWSXAmount, wstWSXAmount);

        return wstWSXAmount;
    }

    /**
     * @notice Exchanges wstWSX to stWSX
     * @param _wstWSXAmount amount of wstWSX to unwrap in exchange for stWSX
     * @dev Requirements:
     *  - `_wstWSXAmount` must be non-zero
     *  - msg.sender must have at least `_wstWSXAmount` wstWSX.
     * @return Amount of stWSX user receives after unwrap
     */
    function unwrap(uint256 _wstWSXAmount) external returns (uint256) {
        require(_wstWSXAmount > 0, "wstWSX: zero amount unwrap not allowed");
        uint256 stWSXAmount = stWSX.getPooledWSXByShares(_wstWSXAmount);
        _burn(msg.sender, _wstWSXAmount);
        stWSX.transfer(msg.sender, stWSXAmount);
        emit Unwrap(msg.sender, _wstWSXAmount, stWSXAmount);
        return stWSXAmount;
    }

    /**
     * @notice Get amount of wstWSX for a given amount of stWSX
     * @param _stWSXAmount amount of stWSX
     * @return Amount of wstWSX for a given stWSX amount
     */
    function getWstWSXByStWSX(uint256 _stWSXAmount) external view returns (uint256) {
        return stWSX.getSharesByPooledWSX(_stWSXAmount);
    }

    /**
     * @notice Get amount of stWSX for a given amount of wstWSX
     * @param _wstWSXAmount amount of wstWSX
     * @return Amount of stWSX for a given wstWSX amount
     */
    function getStWSXByWstWSX(uint256 _wstWSXAmount) external view returns (uint256) {
        return stWSX.getPooledWSXByShares(_wstWSXAmount);
    }

    /**
     * @notice Get amount of stWSX for a one wstWSX
     * @return Amount of stWSX for 1 wstWSX
     */
    function stWSXPerToken() external view returns (uint256) {
        return stWSX.getPooledWSXByShares(ONE_TOKEN);
    }

    /**
     * @notice Get amount of wstWSX for a one stWSX
     * @return Amount of wstWSX for a 1 stWSX
     */
    function tokensPerStWSX() external view returns (uint256) {
        return stWSX.getSharesByPooledWSX(ONE_TOKEN);
    }

    // called when user wraps tokens
    event Wrap(address sender, uint stWSXWrapped, uint wstWSXMinted);
    // called when user unwraps tokens
    event Unwrap(address sender, uint wstWSXUnwrapped, uint stWSXUnwrapped);
}
