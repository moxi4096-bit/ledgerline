// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { LedgerlineReactive } from "../src/LedgerlineReactive.sol";
import { LedgerlineTestBase } from "./LedgerlineTestBase.sol";

/// @notice Configuration and subscription management.
contract LedgerlineConfigTest is LedgerlineTestBase {
    // --- constructor --------------------------------------------------------------------------------

    function test_constructor_setsOwnerAndAcceptsFunding() public view {
        assertEq(ledger.owner(), owner);
        assertEq(address(ledger).balance, 1 ether);
        assertEq(address(ledger._SERVICE_PROVIDER()), SYSTEM);
    }

    function test_constructor_rejectsZeroOwner() public {
        vm.expectRevert(LedgerlineReactive.InvalidConfig.selector);
        new LedgerlineReactive(address(0));
    }

    // --- assets -------------------------------------------------------------------------------------

    function test_configureAsset_createsAndUpdatesWithoutLosingTotals() public {
        _configureDefault();
        _react(_transferLog(BASE, address(usdBase), alice, shop, 5e6));

        vm.prank(owner);
        uint256 id = ledger.configureAsset(USD, 50e6, 0, 0);

        assertEq(id, 0);
        assertEq(ledger.assetCount(), 1);
        LedgerlineReactive.Asset memory a = ledger.asset(0);
        assertEq(a.dailyLimit, 50e6);
        assertEq(a.savingsBps, 0);
        assertEq(a.totalOut, 5e6, "totals survive a rule change");
        assertEq(ledger.assetIdOf(USD), 0);
    }

    function test_configureAsset_validation() public {
        vm.startPrank(owner);
        vm.expectRevert(LedgerlineReactive.InvalidConfig.selector);
        ledger.configureAsset(bytes32(0), 0, 0, 0);

        uint16 tooHigh = ledger.MAX_SAVINGS_BPS() + 1;
        vm.expectRevert(LedgerlineReactive.InvalidConfig.selector);
        ledger.configureAsset(USD, 0, tooHigh, 0);

        for (uint256 i = 0; i < ledger.MAX_ASSETS(); ++i) {
            ledger.configureAsset(bytes32(i + 1), 0, 0, 0);
        }
        vm.expectRevert(LedgerlineReactive.LimitReached.selector);
        ledger.configureAsset("ONE_TOO_MANY", 0, 0, 0);
        vm.stopPrank();

        vm.expectRevert(LedgerlineReactive.UnknownAsset.selector);
        ledger.assetIdOf("NOPE");
    }

    // --- tokens -------------------------------------------------------------------------------------

    function test_trackToken_subscribesBothDirectionsForEveryWallet() public {
        vm.startPrank(owner);
        ledger.configureAsset(USD, 0, 0, 0);
        ledger.trackWallet(alice);
        ledger.trackWallet(aliceHot);
        ledger.trackToken(BASE, address(usdBase), USD);
        vm.stopPrank();

        assertTrue(sys.isSubscribed(_outKey(BASE, address(usdBase), alice)));
        assertTrue(sys.isSubscribed(_inKey(BASE, address(usdBase), alice)));
        assertTrue(sys.isSubscribed(_outKey(BASE, address(usdBase), aliceHot)));
        assertTrue(sys.isSubscribed(_inKey(BASE, address(usdBase), aliceHot)));
        assertEq(sys.activeSubscriptions(), 4);
        assertEq(ledger.activeTokenCount(), 1);

        LedgerlineReactive.Token memory t = ledger.tokenInfo(BASE, address(usdBase));
        assertEq(t.chainId, BASE);
        assertEq(t.token, address(usdBase));
        assertTrue(t.active);
    }

    function test_trackToken_validation() public {
        vm.startPrank(owner);
        vm.expectRevert(LedgerlineReactive.UnknownAsset.selector);
        ledger.trackToken(BASE, address(usdBase), USD);

        ledger.configureAsset(USD, 0, 0, 0);
        vm.expectRevert(LedgerlineReactive.InvalidConfig.selector);
        ledger.trackToken(0, address(usdBase), USD);
        vm.expectRevert(LedgerlineReactive.InvalidConfig.selector);
        ledger.trackToken(BASE, address(0), USD);

        ledger.trackToken(BASE, address(usdBase), USD);
        vm.expectRevert(LedgerlineReactive.AlreadyTracked.selector);
        ledger.trackToken(BASE, address(usdBase), USD);

        for (uint256 i = 1; i < ledger.MAX_TOKENS(); ++i) {
            ledger.trackToken(BASE, address(uint160(0x1000 + i)), USD);
        }
        vm.expectRevert(LedgerlineReactive.LimitReached.selector);
        ledger.trackToken(BASE, address(0xdead), USD);
        vm.stopPrank();
        assertEq(ledger.tokenCount(), ledger.MAX_TOKENS());
    }

    function test_untrackToken_unsubscribesAndKeepsHistory() public {
        _configureDefault();
        _react(_transferLog(BASE, address(usdBase), employer, alice, 10e6));

        vm.prank(owner);
        ledger.untrackToken(BASE, address(usdBase));

        assertFalse(sys.isSubscribed(_outKey(BASE, address(usdBase), alice)));
        assertFalse(sys.isSubscribed(_inKey(BASE, address(usdBase), aliceHot)));
        assertEq(sys.activeSubscriptions(), 4, "only the Unichain token's 4 remain");
        assertEq(ledger.activeTokenCount(), 1);
        assertEq(ledger.tokenInfo(BASE, address(usdBase)).totalIn, 10e6);

        // Re-tracking resubscribes and continues the same ledger row.
        vm.prank(owner);
        ledger.trackToken(BASE, address(usdBase), USD);
        assertEq(sys.activeSubscriptions(), 8);
        assertEq(ledger.tokenCount(), 2, "no duplicate row");
        assertEq(ledger.tokenInfo(BASE, address(usdBase)).totalIn, 10e6);
    }

    function test_untrackToken_revertsWhenNotTracked() public {
        vm.prank(owner);
        vm.expectRevert(LedgerlineReactive.NotTracked.selector);
        ledger.untrackToken(BASE, address(usdBase));
    }

    // --- wallets ------------------------------------------------------------------------------------

    function test_trackWallet_subscribesOnlyActiveTokens() public {
        vm.startPrank(owner);
        ledger.configureAsset(USD, 0, 0, 0);
        ledger.trackToken(BASE, address(usdBase), USD);
        ledger.trackToken(UNI, address(usdUni), USD);
        ledger.untrackToken(UNI, address(usdUni));
        ledger.trackWallet(alice);
        vm.stopPrank();

        assertTrue(sys.isSubscribed(_outKey(BASE, address(usdBase), alice)));
        assertTrue(sys.isSubscribed(_inKey(BASE, address(usdBase), alice)));
        assertFalse(sys.isSubscribed(_outKey(UNI, address(usdUni), alice)));
        assertEq(sys.activeSubscriptions(), 2);
        assertTrue(ledger.isWallet(alice));
        assertEq(ledger.wallets().length, 1);
    }

    function test_trackWallet_validation() public {
        vm.startPrank(owner);
        vm.expectRevert(LedgerlineReactive.InvalidConfig.selector);
        ledger.trackWallet(address(0));

        ledger.trackWallet(alice);
        vm.expectRevert(LedgerlineReactive.AlreadyTracked.selector);
        ledger.trackWallet(alice);

        for (uint256 i = 1; i < ledger.MAX_WALLETS(); ++i) {
            ledger.trackWallet(address(uint160(0x2000 + i)));
        }
        vm.expectRevert(LedgerlineReactive.LimitReached.selector);
        ledger.trackWallet(address(0xbeef));
        vm.stopPrank();
    }

    function test_untrackWallet_unsubscribesAndRemoves() public {
        _configureDefault();
        vm.prank(owner);
        ledger.untrackWallet(alice);

        assertFalse(ledger.isWallet(alice));
        address[] memory w = ledger.wallets();
        assertEq(w.length, 1);
        assertEq(w[0], aliceHot);
        assertFalse(sys.isSubscribed(_outKey(BASE, address(usdBase), alice)));
        assertFalse(sys.isSubscribed(_inKey(UNI, address(usdUni), alice)));
        assertTrue(sys.isSubscribed(_outKey(UNI, address(usdUni), aliceHot)));
        assertEq(sys.activeSubscriptions(), 4);

        vm.prank(owner);
        vm.expectRevert(LedgerlineReactive.NotTracked.selector);
        ledger.untrackWallet(alice);
    }

    // --- vaults & statements ------------------------------------------------------------------------

    function test_setVault_addReplaceClear() public {
        vm.startPrank(owner);
        ledger.setVault(BASE, address(vaultBase));
        ledger.setVault(UNI, address(vaultUni));
        ledger.setVault(BASE, address(0xb0b)); // replace: no new chain entry
        assertEq(ledger.vaultChains().length, 2);
        assertEq(ledger.vaultOf(BASE), address(0xb0b));

        ledger.setVault(BASE, address(0)); // clear
        uint256[] memory chains = ledger.vaultChains();
        assertEq(chains.length, 1);
        assertEq(chains[0], UNI);
        assertEq(ledger.vaultOf(BASE), address(0));

        vm.expectRevert(LedgerlineReactive.InvalidConfig.selector);
        ledger.setVault(0, address(vaultBase));

        for (uint256 i = 1; i < ledger.MAX_VAULTS(); ++i) {
            ledger.setVault(10_000 + i, address(uint160(0x3000 + i)));
        }
        vm.expectRevert(LedgerlineReactive.LimitReached.selector);
        ledger.setVault(99_999, address(0x4000));
        vm.stopPrank();
    }

    function test_setStatementTarget_validation() public {
        vm.startPrank(owner);
        vm.expectRevert(LedgerlineReactive.InvalidConfig.selector);
        ledger.setStatementTarget(0, address(statement));
        vm.expectRevert(LedgerlineReactive.InvalidConfig.selector);
        ledger.setStatementTarget(BASE, address(0));
        ledger.setStatementTarget(BASE, address(statement));
        vm.stopPrank();
        assertEq(ledger.statementChainId(), BASE);
        assertEq(ledger.statementRecipient(), address(statement));
    }

    function test_setStatementSchedule_subscribesSwitchesAndStops() public {
        uint256 c1000 = ledger.CRON1000_TOPIC0();
        uint256 c10000 = ledger.CRON10000_TOPIC0();

        vm.startPrank(owner);
        ledger.setStatementSchedule(c1000, 1 hours);
        assertTrue(sys.isSubscribed(_cronKey(c1000)));
        assertEq(ledger.nextStatementAt(), block.timestamp + 1 hours);

        ledger.setStatementSchedule(c10000, 1 days);
        assertFalse(sys.isSubscribed(_cronKey(c1000)), "old feed dropped");
        assertTrue(sys.isSubscribed(_cronKey(c10000)));

        ledger.setStatementSchedule(0, 0);
        assertFalse(sys.isSubscribed(_cronKey(c10000)));
        assertEq(ledger.statementCronTopic(), 0);
        assertEq(sys.activeSubscriptions(), 0);

        vm.expectRevert(LedgerlineReactive.InvalidConfig.selector);
        ledger.setStatementSchedule(TRANSFER_TOPIC0, 1);
        vm.stopPrank();
    }

    // --- access control -----------------------------------------------------------------------------

    function test_ownerOnly_everyConfigFunction() public {
        address stranger = makeAddr("stranger");
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeCall(LedgerlineReactive.configureAsset, (USD, 0, 0, 0));
        calls[1] = abi.encodeCall(LedgerlineReactive.trackToken, (BASE, address(usdBase), USD));
        calls[2] = abi.encodeCall(LedgerlineReactive.untrackToken, (BASE, address(usdBase)));
        calls[3] = abi.encodeCall(LedgerlineReactive.trackWallet, (alice));
        calls[4] = abi.encodeCall(LedgerlineReactive.untrackWallet, (alice));
        calls[5] = abi.encodeCall(LedgerlineReactive.setVault, (BASE, address(vaultBase)));
        calls[6] = abi.encodeCall(LedgerlineReactive.setStatementTarget, (BASE, address(statement)));
        calls[7] = abi.encodeCall(LedgerlineReactive.setStatementSchedule, (0, 0));
        calls[8] = abi.encodeCall(LedgerlineReactive.requestStatement, ());
        calls[9] = abi.encodeCall(LedgerlineReactive.withdraw, (payable(stranger), 1));

        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(stranger);
            (bool ok, bytes memory ret) = address(ledger).call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(ret), LedgerlineReactive.NotOwner.selector);
        }
    }

    function test_react_onlySystem() public {
        _configureDefault();
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM));
        ledger.react(_transferLog(BASE, address(usdBase), alice, shop, 1e6));
    }

    // --- funds --------------------------------------------------------------------------------------

    function test_withdraw_sendsUnusedReact() public {
        address payable to = payable(makeAddr("treasury"));
        vm.prank(owner);
        ledger.withdraw(to, 0.4 ether);
        assertEq(to.balance, 0.4 ether);
        assertEq(address(ledger).balance, 0.6 ether);
    }

    function test_coverDebt_paysTheSystemContract() public {
        sys.setDebt(address(ledger), 0.25 ether);
        ledger.coverDebt(); // callable by anyone
        assertEq(sys.debt(address(ledger)), 0);
        assertEq(address(ledger).balance, 0.75 ether);
    }

    function test_pay_onlyFromSystem() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM));
        ledger.pay(1);

        vm.prank(SYSTEM);
        ledger.pay(0.1 ether);
        assertEq(address(ledger).balance, 0.9 ether);
    }
}
