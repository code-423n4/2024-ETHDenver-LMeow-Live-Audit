// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Moo} from "../src/Moo.sol";

//  ______
// < Moo? >
//  ------
//         \   ^__^
//          \  (oo)\_______
//             (__)\       )\/\
//                 ||----w |
//                 ||     ||

contract CounterTest is Test {
    Moo public moo;
    address ALICE = address(0x0a11ce);
    address BOB = address(1337); // IYKYK
    uint ONE = 1e18;
    uint WITHDRAWAL_COOLDOWN; 

    function setUp() public {
        moo = new Moo();
        vm.deal(ALICE, 10e18);
        vm.deal(BOB, 10e18);
        WITHDRAWAL_COOLDOWN = moo.WITHDRAWAL_COOLDOWN();
    }

    function test_firstDeposit() public {
        vm.prank(ALICE);
        moo.breed{value: 1e18}(1e18);

        assertEq(1e18, moo.balanceOf(ALICE));
    }

    function test_rewardsAccrual() public {
        vm.prank(ALICE);
        moo.breed{value: 1e18}(1e18);

        // simulate rewards sent by Beacon chain
        address(moo).call{value: 2e17}("");

        vm.startPrank(ALICE);
        moo.signalMilk();

        skip(WITHDRAWAL_COOLDOWN + 1);

        uint balanceBefore = ALICE.balance;
        moo.milk(5e17, false);
        uint balanceAfter = ALICE.balance;

        vm.stopPrank;

        assertApproxEqRel(6e17, balanceAfter - balanceBefore, ONE);
    }
}
