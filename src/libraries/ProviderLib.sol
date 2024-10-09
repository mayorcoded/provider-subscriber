// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.24;

import "./CoreLib.sol";
import "./SubscriberLib.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library ProviderLib {
    using CoreLib for IERC20;

    enum BillingCycle {
        DAY,
        MONTH,
        YEAR
    }

    struct Subscriber {
        bool isPaused;
        uint256 id;
        uint256 nextBillingDate;
    }

    struct Provider {
        uint256 id;
        bool isActive;
        address owner;
        bytes32 hashedKey;
        uint256 feeCycle;
        uint256 balance;
        Subscriber[] subscribers;
        BillingCycle billingCycle;
        uint256 nextWithdrawal;
    }

    struct ProviderData {
        bool hasProviderLimit;
        mapping(uint256 => Provider) providers;
        mapping(bytes32 => uint256) providerKeys;
        uint256 maxProviders;
        IERC20 token;
    }

    error NotProviderOwner();
    error ProviderIsNotActive();
    error DuplicateProviderKey();
    error ProviderStateUnchanged();
    error NotWithinWithdrawalPeriod();
    error ProviderHasActiveSubscribers();
    error ProviderAlreadyRegistered(uint256 providerId);
    error ProviderNotRegistered(uint256 providerId);
    error ProviderLimitReached(uint256 limit);
    error SubscriberAlreadyExists(uint256 subscriberId);
    error InsufficientBalance(uint256 required, uint256 available);
    error InvalidBillingCycle(BillingCycle cycle);
    error ProviderDoesNotExist(uint256 providerId);

    event ProviderStateUpdated(uint256 indexed providerId, bool isActive);
    event SubscriptionPaused(uint256 indexed providerId, uint256 indexed subscriberId);

    /**
     * @dev Registers a new provider in the system.
     * @param self The ProviderData storage.
     * @param providerId The unique identifier for the provider.
     * @param owner The address of the provider owner.
     * @param key The unique key for the provider.
     * @param fee The fee charged by the provider per billing cycle.
     * @notice This function will revert if the provider limit is reached or if the provider ID already exists.
     */
    function registerProvider(
        ProviderData storage self,
        uint256 providerId,
        address owner,
        bytes calldata key,
        uint256 fee
    ) internal {
        if (self.hasProviderLimit && providerId > self.maxProviders) {
            revert ProviderLimitReached(self.maxProviders);
        }
        if (self.providers[providerId].id != 0) {
            revert ProviderAlreadyRegistered(providerId);
        }

        bytes32 hashedProviderKey = keccak256(abi.encodePacked(key, msg.sender));
        if (self.providerKeys[hashedProviderKey] != 0) {
            revert DuplicateProviderKey();
        }

        self.providerKeys[hashedProviderKey] = providerId;
        self.providers[providerId] = Provider({
            id: providerId,
            owner: owner,
            hashedKey: hashedProviderKey,
            feeCycle: fee,
            balance: 0,
            isActive: true,
            subscribers: new Subscriber[](0),
            billingCycle: BillingCycle.MONTH,
            nextWithdrawal: block.timestamp + 30 days
        });
    }

    /**
     * @dev Removes a provider from the system and returns their balance.
     * @param self The ProviderData storage.
     * @param providerId The ID of the provider to remove.
     * @return balance The remaining balance of the removed provider.
     * @notice Only the provider owner can call this function. It will revert if the provider doesn't exist or is not the owner.
     */
    function removeProvider(ProviderData storage self, uint256 providerId) internal returns (uint256 balance) {
        Provider storage provider = self.providers[providerId];
        if (provider.id == 0 || provider.owner == address(0)) {
            revert ProviderDoesNotExist(providerId);
        }
        if (provider.owner != msg.sender) {
            revert NotProviderOwner();
        }

        balance = provider.balance;
        provider.balance = 0;
        provider.id = 0;
        provider.owner = address(0);

        delete self.providerKeys[provider.hashedKey];
        delete self.providers[providerId];
        return balance;
    }

    /**
     * @dev Adds a new subscriber to a provider.
     * @param self The ProviderData storage.
     * @param providerId The ID of the provider.
     * @param subscriberId The ID of the subscriber to add.
     * @param subscriber The Subscriber struct from SubscriberLib.
     * @notice This function will charge the subscriber immediately for the first billing cycle.
     */
    function addSubscriber(
        ProviderData storage self,
        uint256 providerId,
        uint256 subscriberId,
        SubscriberLib.Subscriber storage subscriber
    ) internal {
        Provider storage provider = self.providers[providerId];
        if (provider.id == 0) {
            revert ProviderDoesNotExist(providerId);
        }
        if (!provider.isActive) {
            revert ProviderIsNotActive();
        }

        uint256 len = provider.subscribers.length;
        for (uint256 i = 0; i < len; i++) {
            if (provider.subscribers[i].id == subscriberId) {
                revert SubscriberAlreadyExists(subscriberId);
            }
        }

        uint256 feeCycle = provider.feeCycle;
        if (subscriber.balance < feeCycle) {
            revert InsufficientBalance(feeCycle, subscriber.balance);
        }

        subscriber.balance -= feeCycle;
        provider.balance += feeCycle;
        uint256 nextBillingDate = block.timestamp + getCycleDuration(provider.billingCycle);
        provider.subscribers.push(Subscriber({id: subscriberId, isPaused: false, nextBillingDate: nextBillingDate}));
    }

    /**
     * @dev Processes payments for all subscribers of a provider.
     * @param self The ProviderData storage.
     * @param providerId The ID of the provider.
     * @param subscriberData The SubscriberData storage from SubscriberLib.
     * @return The updated balance of the provider after processing payments.
     * @notice This function will pause subscriptions for subscribers with insufficient balance.
     */
    function processPayments(
        ProviderData storage self,
        uint256 providerId,
        SubscriberLib.SubscriberData storage subscriberData
    ) internal returns (uint256) {
        Provider storage provider = self.providers[providerId];
        if (provider.id == 0) {
            revert ProviderDoesNotExist(providerId);
        }
        if (!provider.isActive) {
            revert ProviderIsNotActive();
        }

        uint256 cycleDuration = getCycleDuration(provider.billingCycle);

        uint256 feeCycle = provider.feeCycle;
        for (uint256 i = 0; i < provider.subscribers.length; i++) {
            Subscriber storage sub = provider.subscribers[i];

            if (!sub.isPaused && block.timestamp >= sub.nextBillingDate) {
                SubscriberLib.Subscriber storage subscriber = subscriberData.subscribers[sub.id];
                if (subscriber.balance >= feeCycle) {
                    subscriber.balance -= feeCycle;
                    provider.balance += feeCycle;
                    sub.nextBillingDate = block.timestamp + cycleDuration;
                } else {
                    pauseSubscription(providerId, sub);
                }
            }
        }

        return provider.balance;
    }

    /**
     * @dev Updates the active state of a provider.
     * @param self The ProviderData storage.
     * @param providerId The ID of the provider.
     * @param newState The new active state to set.
     * @notice This function will revert if the provider doesn't exist or if the new state is the same as the current state.
     */
    function updateProviderState(ProviderData storage self, uint256 providerId, bool newState) internal {
        if (!isProviderRegistered(self, providerId)) {
            revert ProviderDoesNotExist(providerId);
        }

        Provider storage provider = self.providers[providerId];
        if (provider.isActive == newState) {
            revert ProviderStateUnchanged();
        }

        provider.isActive = newState;
        emit ProviderStateUpdated(providerId, newState);
    }

    /**
     * @dev Pauses a subscription for a specific subscriber.
     * @param providerId The ID of the provider.
     * @param subscriber The Subscriber struct to pause.
     * @notice This function emits a SubscriptionPaused event.
     */
    function pauseSubscription(uint256 providerId, Subscriber storage subscriber) internal {
        subscriber.isPaused = true;
        emit SubscriptionPaused(providerId, subscriber.id);
    }

    /**
     * @dev Checks if a provider is registered in the system.
     * @param self The ProviderData storage.
     * @param providerId The ID of the provider to check.
     * @return bool True if the provider is registered, false otherwise.
     */
    function isProviderRegistered(ProviderData storage self, uint256 providerId) internal view returns (bool) {
        return self.providers[providerId].id != 0;
    }

    /**
     * @dev Gets the duration of a billing cycle in seconds.
     * @param cycle The BillingCycle enum value.
     * @return uint256 The duration of the cycle in seconds.
     * @notice This function will revert if an invalid billing cycle is provided.
     */
    function getCycleDuration(BillingCycle cycle) internal pure returns (uint256) {
        if (cycle == BillingCycle.DAY) {
            return 1 days;
        } else if (cycle == BillingCycle.MONTH) {
            return 30 days;
        } else if (cycle == BillingCycle.YEAR) {
            return 365 days;
        }
        revert InvalidBillingCycle(cycle);
    }
}
