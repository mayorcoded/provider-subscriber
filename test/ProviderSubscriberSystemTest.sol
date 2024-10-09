// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ProviderSubscriberSystem.sol";
import "../src/libraries/ProviderLib.sol";
import "../src/libraries/CoreLib.sol";
import "./utils/MockERC20.sol";
import "./utils/MockPriceFeed.sol";

contract ProviderSubscriberSystemTest is Test {
    ProviderSubscriberSystem private system;
    MockERC20 private token;
    MockPriceFeed private priceFeed;
    address private owner;
    address private provider;

    function setUp() public {
        owner = address(this);
        provider = address(0x1);
        token = new MockERC20();
        priceFeed = new MockPriceFeed(1e8); // $1 initial price

        system = new ProviderSubscriberSystem();
        system.initialize(address(token), address(priceFeed));

        vm.label(address(system), "ProviderSubscriberSystem");
        vm.label(address(token), "MockERC20");
        vm.label(address(priceFeed), "MockPriceFeed");
        vm.label(provider, "Provider");
    }

    function testRegisterProvider() public {
        bytes memory key = "test_key";
        uint256 fee = 100 * 1e18; // 100 tokens

        vm.startPrank(provider);
        uint256 providerId = system.registerProvider(key, fee);
        vm.stopPrank();

        assertEq(providerId, 1, "Provider ID should be 1");

        (address providerOwner, uint256 providerFee, uint256 balance, uint256 subscriberCount, bool isActive) =
            system.getProviderInfo(providerId);
        assertEq(providerOwner, provider, "Provider owner should match");
        assertEq(providerFee, fee, "Provider fee should match");
        assertEq(balance, 0, "Initial balance should be 0");
        assertEq(subscriberCount, 0, "Initial subscriber count should be 0");
        assertTrue(isActive, "Provider should be active");
    }

    function testRegisterProviderInsufficientFee() public {
        bytes memory key = "provider_test_key";
        uint256 fee = 10 * 1e18; // 10 tokens, which is less than the minimum required

        vm.startPrank(provider);
        vm.expectRevert(
            abi.encodeWithSelector(ProviderSubscriberSystem.InsufficientProviderFee.selector, 50 * 1e18, fee)
        );
        system.registerProvider(key, fee);
        vm.stopPrank();
    }

    function testRegisterProviderDuplicateKey() public {
        bytes memory key = "provider_test_key";
        uint256 fee = 100 * 1e18;

        vm.startPrank(provider);
        system.registerProvider(key, fee);

        vm.expectRevert(abi.encodeWithSelector(ProviderLib.DuplicateProviderKey.selector));
        system.registerProvider(key, fee);
        vm.stopPrank();
    }

    function testRegisterProviderMaxLimit() public {
        bytes memory key = "provider_test_key";
        uint256 fee = 100 * 1e18;

        for (uint256 i = 0; i < 200; i++) {
            vm.prank(address(uint160(i + 1)));
            system.registerProvider(abi.encodePacked(key, i), fee);
        }

        vm.prank(address(201));
        vm.expectRevert(abi.encodeWithSelector(ProviderLib.ProviderLimitReached.selector, 200));
        system.registerProvider("new_provider_key", fee);
    }

    function testRemoveProvider() public {
        bytes memory key = "provider_test_key";
        uint256 fee = 100 * 1e18; // 100 tokens

        vm.startPrank(provider);
        uint256 providerId = system.registerProvider(key, fee);

        // Check provider exists
        (address providerOwner,,,,) = system.getProviderInfo(providerId);
        assertEq(providerOwner, provider, "Provider should exist");

        // Remove provider
        system.removeProvider(providerId);
        vm.stopPrank();

        // Check provider no longer exists
        vm.expectRevert();
        system.removeProvider(providerId);
    }

    function testRemoveProviderNotOwner() public {
        bytes memory key = "provider_test_key";
        uint256 fee = 100 * 1e18;

        vm.prank(provider);
        uint256 providerId = system.registerProvider(key, fee);

        address notOwner = address(0x2);
        vm.prank(notOwner);
        vm.expectRevert(ProviderLib.NotProviderOwner.selector);
        system.removeProvider(providerId);
    }

    function testUpdateProviderFee() public {
        bytes memory key = "provider_test_key";
        uint256 initialFee = 100 * 1e18; // 100 tokens
        uint256 newFee = 150 * 1e18; // 150 tokens
        ProviderLib.BillingCycle newBillingCycle = ProviderLib.BillingCycle.MONTH;

        vm.startPrank(provider);
        uint256 providerId = system.registerProvider(key, initialFee);

        system.updateProviderFee(providerId, newFee, newBillingCycle);
        vm.stopPrank();

        (, uint256 updatedFee,,,) = system.getProviderInfo(providerId);
        assertEq(updatedFee, newFee, "Provider fee should be updated");
    }

    function testUpdateProviderFeeNotOwner() public {
        bytes memory key = "provider_test_key";
        uint256 initialFee = 100 * 1e18;
        uint256 newFee = 150 * 1e18;
        ProviderLib.BillingCycle newBillingCycle = ProviderLib.BillingCycle.MONTH;

        vm.prank(provider);
        uint256 providerId = system.registerProvider(key, initialFee);

        address notOwner = address(0x2);
        vm.prank(notOwner);
        vm.expectRevert(ProviderSubscriberSystem.NotProviderOwner.selector);
        system.updateProviderFee(providerId, newFee, newBillingCycle);
    }
}
