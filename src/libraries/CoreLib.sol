// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title CoreLib
 * @dev A library for core functionality used across the system.
 */
library CoreLib {
    using SafeERC20 for IERC20;

    error PriceError();
    error TransferFailed();

    /**
     * @dev Minimum fee in USD (50$), represented with 8 decimal places.
     */
    uint256 public constant MIN_FEE_USD = 50 * 1e8;

    /**
     * @dev Minimum subscriber deposit in USD (100$), represented with 8 decimal places.
     */
    uint256 public constant MIN_SUBSCRIBER_DEPOSIT_USD = 100 * 1e8;

    /**
     * @dev Safely transfers tokens using OpenZeppelin's SafeERC20.
     * @param token The IERC20 token to transfer.
     * @param to The recipient address.
     * @param amount The amount of tokens to transfer.
     */
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        token.safeTransfer(to, amount);
    }

    /**
     * @dev Safely transfers tokens from a specified address using OpenZeppelin's SafeERC20.
     * @param token The IERC20 token to transfer.
     * @param from The address to transfer from.
     * @param to The recipient address.
     * @param amount The amount of tokens to transfer.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        token.safeTransferFrom(from, to, amount);
    }

    /**
     * @dev Calculates the minimum provider fee in token amount based on the USD price.
     * @param priceFeed The Chainlink price feed interface.
     * @return uint256 The minimum provider fee in token amount.
     */
    function getMinProviderFee(AggregatorV3Interface priceFeed) public view returns (uint256) {
        return usdPriceToToken(priceFeed, MIN_FEE_USD);
    }

    /**
     * @dev Calculates the minimum subscriber deposit in token amount based on the USD price.
     * @param priceFeed The Chainlink price feed interface.
     * @return uint256 The minimum subscriber deposit in token amount.
     */
    function getMinSubscriberDeposit(AggregatorV3Interface priceFeed) public view returns (uint256) {
        return usdPriceToToken(priceFeed, MIN_SUBSCRIBER_DEPOSIT_USD);
    }

    /**
     * @dev Converts a USD amount to its equivalent in token amount based on the current price.
     * @param priceFeed The Chainlink price feed interface.
     * @param amount The USD amount to convert, represented with 8 decimal places.
     * @return uint256 The equivalent token amount, assuming 18 decimal places for the token.
     * @notice This function will revert if the price feed returns a zero or negative price.
     */
    function usdPriceToToken(AggregatorV3Interface priceFeed, uint256 amount) public view returns (uint256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        if (price <= 0) revert PriceError();
        // Convert the USD amount into the equivalent amount of tokens based on Chainlink price
        return (amount * 10 ** 18) / uint256(price);
    }
}
