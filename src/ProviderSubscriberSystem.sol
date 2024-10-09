// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./libraries/CoreLib.sol";
import "./libraries/ProviderLib.sol";
import "./libraries/SubscriberLib.sol";

contract ProviderSubscriberSystem is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using ProviderLib for ProviderLib.ProviderData;
    using SubscriberLib for SubscriberLib.SubscriberData;
    using CoreLib for IERC20;

    uint8 public constant USD_DECIMALS = 8;
    uint8 public constant PRICE_FEED_DECIMALS = 8;

    bool private isUpgradable;

    IERC20 public token;
    AggregatorV3Interface public priceFeed;

    ProviderLib.ProviderData private providerData;
    SubscriberLib.SubscriberData private subscriberData;

    uint256 public providerIdCounter;
    uint256 public subscriberIdCounter;

    event ProviderRegistered(uint256 indexed providerId, address indexed owner, uint256 fee);
    event ProviderRemoved(uint256 indexed providerId, address indexed owner);
    event ProviderFeeUpdated(uint256 indexed providerId, uint256 newFee, ProviderLib.BillingCycle billingCycle);
    event ProviderEarningsWithdrawn(uint256 indexed providerId, uint256 amount);
    event SubscriberRegistered(uint256 indexed subscriberId, address indexed owner, uint256 deposit);
    event SubscriptionIncreased(uint256 indexed subscriberId, uint256 amount);
    event PaymentProcessed(uint256 indexed subscriberId, uint256 totalFee);
    event SubscriptionPaused(uint256 indexed subscriberId);
    event SubscriptionResumed(uint256 indexed subscriberId);
    event UpgradesDisabled();

    error ContractIsNotUpgradable();
    error NotProviderOwner();
    error InsufficientProviderFee(uint256 required, uint256 provided);
    error NoProvidersSpecified();
    error InsufficientSubscriberDeposit(uint256 required, uint256 provided);
    error SubscriberNotFound(uint256 subscriberId);

    /**
     * @dev Initializes the contract with token and price feed addresses.
     * @param _token Address of the ERC20 token used for payments.
     * @param _priceFeed Address of the Chainlink price feed.
     */
    function initialize(address _token, address _priceFeed) public initializer {
        __Ownable_init(msg.sender);
        token = IERC20(_token);
        priceFeed = AggregatorV3Interface(_priceFeed);
        providerData.hasProviderLimit = true;
        providerData.maxProviders = 200;
        providerData.token = token;
        isUpgradable = true;
    }

    /**
     * @dev Registers a new provider with the given key and fee.
     * @param key The provider's unique key.
     * @param fee The provider's fee.
     * @return providerId The ID of the newly registered provider.
     */
    function registerProvider(bytes calldata key, uint256 fee) external returns (uint256 providerId) {
        uint256 minFee = CoreLib.getMinProviderFee(priceFeed);
        if (fee < minFee) {
            revert InsufficientProviderFee(minFee, fee);
        }

        providerId = ++providerIdCounter;
        providerData.registerProvider(providerId, msg.sender, key, fee);
        emit ProviderRegistered(providerId, msg.sender, fee);
    }

    /**
     * @dev Removes a provider from the system.
     * @param providerId The ID of the provider to be removed.
     */
    function removeProvider(uint256 providerId) external {
        uint256 balance = providerData.removeProvider(providerId);
        if (balance > 0) {
            CoreLib.safeTransfer(token, msg.sender, balance);
        }

        emit ProviderRemoved(providerId, msg.sender);
    }

    /**
     * @dev Updates a provider's fee and billing cycle.
     * @param providerId The ID of the provider.
     * @param newFee The new fee to be set.
     * @param billingCycle The new billing cycle to be set.
     */
    function updateProviderFee(uint256 providerId, uint256 newFee, ProviderLib.BillingCycle billingCycle) external {
        ProviderLib.Provider storage provider = providerData.providers[providerId];
        if (msg.sender != provider.owner) {
            revert NotProviderOwner();
        }

        if (provider.billingCycle != billingCycle) {
            provider.billingCycle = billingCycle;
        }

        uint256 minFee = CoreLib.getMinProviderFee(priceFeed);
        if (newFee < minFee) {
            revert InsufficientProviderFee(minFee, newFee);
        }
        provider.feeCycle = newFee;
        emit ProviderFeeUpdated(providerId, newFee, billingCycle);
    }

    /**
     * @dev Allows a provider to withdraw their earnings.
     * @param providerId The ID of the provider.
     * @param amount The amount to withdraw.
     */
    function withdrawProviderEarnings(uint256 providerId, uint256 amount) external {
        ProviderLib.Provider storage provider = providerData.providers[providerId];
        uint256 balance = provider.balance;

        if (msg.sender != provider.owner) {
            revert NotProviderOwner();
        }
        if (amount > balance) {
            revert ProviderLib.InsufficientBalance(amount, balance);
        }
        if (block.timestamp < provider.nextWithdrawal) {
            revert ProviderLib.NotWithinWithdrawalPeriod();
        }

        _beforeEarningsWithdrawal(providerId);

        provider.balance -= amount;
        provider.nextWithdrawal = block.timestamp + 30 days;
        CoreLib.safeTransfer(token, msg.sender, amount);
        emit ProviderEarningsWithdrawn(providerId, amount);
    }

    /**
     * @dev Updates the active state of a provider. Only callable by the contract owner.
     * @param providerId The ID of the provider.
     * @param newState The new active state to set.
     */
    function updateProviderState(uint256 providerId, bool newState) external onlyOwner {
        providerData.updateProviderState(providerId, newState);
    }

    /**
     * @dev Registers a new subscriber with the given provider IDs and deposit.
     * @param providerIds An array of provider IDs to subscribe to.
     * @param deposit The initial deposit amount.
     */
    function registerSubscriber(uint256[] memory providerIds, uint256 deposit) external {
        if (providerIds.length == 0) {
            revert NoProvidersSpecified();
        }
        uint256 minDeposit = CoreLib.getMinSubscriberDeposit(priceFeed);
        if (deposit < minDeposit) {
            revert InsufficientSubscriberDeposit(minDeposit, deposit);
        }

        uint256 subscriberId = ++subscriberIdCounter;
        subscriberData.registerSubscriber(subscriberId, deposit, providerIds);
        CoreLib.safeTransferFrom(token, msg.sender, address(this), deposit);

        uint256 len = providerIds.length;
        for (uint256 i = 0; i < len; i++) {
            providerData.addSubscriber(providerIds[i], subscriberId, subscriberData.subscribers[subscriberId]);
        }
        emit SubscriberRegistered(subscriberId, msg.sender, deposit);
    }

    /**
     * @dev Increases the deposit for a subscriber.
     * @param subscriberId The ID of the subscriber.
     * @param amount The amount to increase the deposit by.
     */
    function increaseSubscriptionDeposit(uint256 subscriberId, uint256 amount) external {
        subscriberData.increaseBalance(subscriberId, amount);
        CoreLib.safeTransferFrom(token, msg.sender, address(this), amount);
        emit SubscriptionIncreased(subscriberIdCounter, amount);
    }

    /**
     * @dev Pauses a subscription for a specific provider.
     * @param subscriberId The ID of the subscriber.
     * @param providerId The ID of the provider.
     */
    function pauseSubscription(uint256 subscriberId, uint256 providerId) external {
        ProviderLib.Provider storage provider = providerData.providers[providerId];
        bool found = false;
        uint256 len = provider.subscribers.length;

        for (uint256 i = 0; i < len; i++) {
            if (subscriberData.subscribers[subscriberId].owner == msg.sender) {
                ProviderLib.pauseSubscription(providerId, provider.subscribers[i]);
                emit SubscriptionPaused(provider.subscribers[i].id);
                found = true;
                break;
            }
        }
        if (!found) {
            revert SubscriberNotFound(subscriberId);
        }
    }

    /**
     * @dev Resumes a paused subscription for a specific provider.
     * @param subscriberId The ID of the subscriber.
     * @param providerId The ID of the provider.
     */
    function resumeSubscription(uint256 subscriberId, uint256 providerId) external {
        ProviderLib.Provider storage provider = providerData.providers[providerId];
        bool found = false;
        for (uint256 i = 0; i < provider.subscribers.length; i++) {
            if (subscriberData.subscribers[subscriberId].owner == msg.sender) {
                provider.subscribers[i].isPaused = false;
                emit SubscriptionResumed(provider.subscribers[i].id);
                found = true;
                break;
            }
        }
        if (!found) {
            revert SubscriberNotFound(subscriberId);
        }
    }

    /**
     * @dev Retrieves information about a provider.
     * @param providerId The ID of the provider.
     * @return owner The address of the provider owner.
     * @return feeCycle The provider's fee per cycle.
     * @return balance The provider's current balance.
     * @return subscriberCount The number of subscribers for this provider.
     * @return isActive Whether the provider is currently active.
     */
    function getProviderInfo(uint256 providerId) external view returns (address, uint256, uint256, uint256, bool) {
        ProviderLib.Provider storage provider = providerData.providers[providerId];
        return (provider.owner, provider.feeCycle, provider.balance, provider.subscribers.length, provider.isActive);
    }

    /**
     * @dev Retrieves information about a subscriber.
     * @param subscriberId The ID of the subscriber.
     * @return owner The address of the subscriber.
     * @return balance The subscriber's current balance.
     * @return providerIds An array of provider IDs the subscriber is subscribed to.
     */
    function getSubscriberInfo(uint256 subscriberId) external view returns (address, uint256, uint256[] memory) {
        SubscriberLib.Subscriber storage subscriber = subscriberData.subscribers[subscriberId];
        return (subscriber.owner, subscriber.balance, subscriber.providerIds);
    }

    /**
     * @dev Retrieves the current earnings of a provider.
     * @param providerId The ID of the provider.
     * @return The current balance of the provider.
     */
    function getProviderEarnings(uint256 providerId) external view returns (uint256) {
        return providerData.providers[providerId].balance;
    }

    /**
     * @dev Calculates the USD value of a subscriber's deposit.
     * @param subscriberId The ID of the subscriber.
     * @return The USD value of the subscriber's deposit.
     */
    function getSubscriberDepositValueUSD(uint256 subscriberId) external view returns (uint256) {
        SubscriberLib.Subscriber memory subscriber = subscriberData.subscribers[subscriberId];
        if (subscriber.owner == address(0)) {
            revert SubscriberNotFound(subscriberId);
        }

        uint256 depositAmount = subscriber.balance;
        uint8 tokenDecimals = IERC20Metadata(address(token)).decimals();

        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        if (price <= 0 || updatedAt == 0 || answeredInRound < roundId) {
            revert CoreLib.PriceError();
        }

        // Convert price to USD with proper precision
        uint256 priceUsd = uint256(price);
        return (depositAmount * priceUsd * (10 ** USD_DECIMALS)) / (10 ** PRICE_FEED_DECIMALS) / (10 ** tokenDecimals);
    }

    /**
     * @dev Disables future upgrades of the contract. Can only be called by the owner.
     */
    function disableUpgrades() external onlyOwner {
        isUpgradable = false;
        emit UpgradesDisabled();
    }

    /**
     * @dev Internal function to process payments before an earnings withdrawal.
     * @param providerId The ID of the provider.
     */
    function _beforeEarningsWithdrawal(uint256 providerId) internal {
        providerData.processPayments(providerId, subscriberData);
    }

    /**
     * @dev Internal function to authorize an upgrade. Overrides UUPSUpgradeable.
     * @param newImplementation Address of the new implementation.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (!isUpgradable) revert ContractIsNotUpgradable();
    }
}
