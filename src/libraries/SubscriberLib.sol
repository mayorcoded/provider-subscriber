// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.24;

import "./ProviderLib.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library SubscriberLib {
    struct Subscriber {
        address owner;
        uint256 balance;
        uint256[] providerIds;
    }

    struct SubscriberData {
        mapping(uint256 => Subscriber) subscribers;
    }

    error NotSubscriber();
    error SubscriberAlreadyRegistered();
    error SubscriberNotRegistered();
    error ProviderAlreadyAdded();

    /**
     * @dev Registers a new subscriber in the system.
     * @param self The SubscriberData storage.
     * @param subscriberId The unique identifier for the subscriber.
     * @param depositAmount The initial deposit amount for the subscriber.
     * @param providerIds An array of provider IDs that the subscriber is subscribing to.
     * @return A storage pointer to the newly registered Subscriber struct.
     * @notice This function will revert if the subscriber ID is already registered.
     */
    function registerSubscriber(
        SubscriberData storage self,
        uint256 subscriberId,
        uint256 depositAmount,
        uint256[] memory providerIds
    ) internal returns (Subscriber storage) {
        if (self.subscribers[subscriberId].owner != address(0)) {
            revert SubscriberAlreadyRegistered();
        }
        self.subscribers[subscriberId] =
            Subscriber({owner: msg.sender, balance: depositAmount, providerIds: providerIds});
        return self.subscribers[subscriberId];
    }

    /**
     * @dev Adds a new provider to a subscriber's list of providers.
     * @param self The SubscriberData storage.
     * @param subscriberId The ID of the subscriber.
     * @param providerId The ID of the provider to add.
     * @notice This function will revert if the subscriber is not registered or if the provider is already added.
     */
    function addProvider(SubscriberData storage self, uint256 subscriberId, uint256 providerId) internal {
        Subscriber storage sub = self.subscribers[subscriberId];
        if (sub.owner == address(0)) {
            revert SubscriberNotRegistered();
        }
        for (uint256 i = 0; i < sub.providerIds.length; i++) {
            if (sub.providerIds[i] == providerId) {
                revert ProviderAlreadyAdded();
            }
        }
        sub.providerIds.push(providerId);
    }

    /**
     * @dev Increases the balance of a subscriber.
     * @param self The SubscriberData storage.
     * @param subscriberId The ID of the subscriber.
     * @param amount The amount to increase the balance by.
     * @notice This function will revert if the subscriber is not registered or if the caller is not the subscriber.
     */
    function increaseBalance(SubscriberData storage self, uint256 subscriberId, uint256 amount) internal {
        Subscriber storage sub = self.subscribers[subscriberId];
        if (sub.owner == address(0)) {
            revert SubscriberNotRegistered();
        }
        if (sub.owner != msg.sender) {
            revert NotSubscriber();
        }
        sub.balance += amount;
    }

    /**
     * @dev Decreases the balance of a subscriber.
     * @param self The SubscriberData storage.
     * @param subscriberId The ID of the subscriber.
     * @param amount The amount to decrease the balance by.
     * @notice This function will revert if the subscriber is not registered.
     * @dev This function does not check for sufficient balance. The caller should ensure sufficient balance before calling.
     */
    function decreaseBalance(SubscriberData storage self, uint256 subscriberId, uint256 amount) internal {
        Subscriber storage sub = self.subscribers[subscriberId];
        if (sub.owner == address(0)) {
            revert SubscriberNotRegistered();
        }
        sub.balance -= amount;
    }

    /**
     * @dev Checks if a subscriber is registered in the system.
     * @param self The SubscriberData storage.
     * @param subscriberId The ID of the subscriber to check.
     * @return bool True if the subscriber is registered, false otherwise.
     */
    function isSubscriber(SubscriberData storage self, uint256 subscriberId) internal view returns (bool) {
        return self.subscribers[subscriberId].owner != address(0);
    }
}
