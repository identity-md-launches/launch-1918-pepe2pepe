// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Pepe2Pepe} from "../src/Pepe2Pepe.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

// Only the cheatcodes used here; the suite stays self-contained like the existing one.
interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function deal(address account, uint256 newBalance) external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

/// @notice Deploys two tokens in one call, as a launch that deploys everything in one transaction
/// would, and checks each constructor minted to its own caller and nothing else.
contract DoubleDeployProbe {
    Pepe2Pepe public first;
    Pepe2Pepe public second;

    function deployBoth() external {
        first = new Pepe2Pepe();
        second = new Pepe2Pepe();
    }
}

/// @notice A contract that forwards ether, to show the token refuses it.
contract EtherPusher {
    function push(address to) external payable returns (bool ok) {
        (ok,) = to.call{value: msg.value}("");
    }
}

/// @notice Edge inputs the author did not write tests for: the exact supply literal, a second
/// deployment, ether and unknown calldata, zero-amount delegated transfers with no allowance,
/// an owner spending its own balance through transferFrom, the finite allowance one below infinity,
/// tokens stuck in the token contract, the floor's privileged-call lists, and bytecode content.
/// forge-config: default.fuzz.runs = 1000
contract Pepe2PepeEdgesTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0xCA11);
    address private constant STRANGER = address(0x5712A6E2);
    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

    Pepe2Pepe private token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new Pepe2Pepe();
    }

    // ----------------------------------------------------------------------------------------------
    // Supply and deployment
    // ----------------------------------------------------------------------------------------------

    function testSupplyLiteralIsExactlyOneBillionTimesTenToTheEighteen() public view {
        require(token.INITIAL_SUPPLY() == 1_000_000_000_000_000_000_000_000_000, "literal");
        require(token.totalSupply() == 10 ** 27, "ten to the 27");
        require(token.totalSupply() == 1_000_000_000 * 10 ** uint256(token.decimals()), "whole tokens times decimals");
        require(token.totalSupply() / 10 ** uint256(token.decimals()) == 1_000_000_000, "whole-token count");
        require(token.totalSupply() % 10 ** uint256(token.decimals()) == 0, "no fractional remainder");
    }

    function testTwoDeploymentsInOneCallAreIndependent() public {
        DoubleDeployProbe probe = new DoubleDeployProbe();
        probe.deployBoth();
        Pepe2Pepe first = probe.first();
        Pepe2Pepe second = probe.second();
        require(address(first) != address(second), "same address");
        require(first.totalSupply() == SUPPLY && second.totalSupply() == SUPPLY, "each has its own supply");
        require(first.balanceOf(address(probe)) == SUPPLY, "first minted to its deployer");
        require(second.balanceOf(address(probe)) == SUPPLY, "second minted to its deployer");
        require(first.balanceOf(address(this)) == 0 && second.balanceOf(address(this)) == 0, "origin got nothing");
        require(first.balanceOf(address(second)) == 0 && second.balanceOf(address(first)) == 0, "cross mint");
    }

    function testDeployerIsCallerNotOrigin() public {
        vm.prank(ALICE);
        Pepe2Pepe deployed = new Pepe2Pepe();
        require(deployed.balanceOf(ALICE) == SUPPLY, "pranked deployer must hold the supply");
        require(deployed.balanceOf(address(this)) == 0, "test contract must hold nothing");
    }

    // ----------------------------------------------------------------------------------------------
    // Calls the token has no business accepting
    // ----------------------------------------------------------------------------------------------

    function testRejectsEther() public {
        vm.deal(address(this), 2 ether);
        (bool direct,) = address(token).call{value: 1 ether}("");
        require(!direct, "accepted plain ether");
        EtherPusher pusher = new EtherPusher();
        require(!pusher.push{value: 1 ether}(address(token)), "accepted forwarded ether");
        require(address(token).balance == 0, "token holds ether");
        (bool withData,) =
            address(token).call{value: 1 ether}(abi.encodeWithSelector(token.transfer.selector, ALICE, 1));
        require(!withData, "accepted ether alongside a non-payable call");
        require(token.balanceOf(ALICE) == 0, "payable transfer moved tokens");
    }

    function testUnknownSelectorReverts() public {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        require(!ok && data.length == 0, "unknown selector did not revert empty");
        (ok,) = address(token).call("");
        require(!ok, "empty calldata did not revert");
        (ok,) = address(token).call(hex"deadbeef");
        require(!ok, "garbage calldata did not revert");
    }

    function testFloorMintListCannotGrowSupply() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], STRANGER, type(uint128).max);
            vm.prank(STRANGER);
            (bool strangerOk,) = address(token).call(data);
            require(!strangerOk, signatures[i]);
            (bool deployerOk,) = address(token).call(data);
            require(!deployerOk, signatures[i]);
            require(token.totalSupply() == SUPPLY, "supply grew");
            require(token.balanceOf(STRANGER) == 0, "stranger was minted to");
        }
    }

    function testFloorPrivilegedListCannotMoveOrFreezeHolder() public {
        token.transfer(ALICE, SUPPLY / 1_000);
        uint256 held = token.balanceOf(ALICE);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], ALICE, true));
            require(!ok, signatures[i]);
        }
        (bool moved,) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, ALICE, address(this), 1));
        require(!moved, "deployer moved a holder's balance");
        require(token.balanceOf(ALICE) == held, "holder balance changed");
        vm.prank(ALICE);
        require(token.transfer(BOB, held / 2), "holder can no longer transfer");
        require(token.balanceOf(BOB) == held / 2, "holder transfer delivered short");
        require(token.totalSupply() == SUPPLY, "supply changed");
    }

    // ----------------------------------------------------------------------------------------------
    // Delegated transfer edges
    // ----------------------------------------------------------------------------------------------

    /// @dev OpenZeppelin semantics: a zero-amount transferFrom needs no allowance, emits Transfer,
    /// and leaves every balance and allowance as it was.
    function testZeroAmountTransferFromWithoutAllowanceSucceedsAndMovesNothing() public {
        require(token.allowance(address(this), STRANGER) == 0, "precondition");
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), BOB, 0);
        vm.prank(STRANGER);
        require(token.transferFrom(address(this), BOB, 0), "zero transferFrom");
        require(token.balanceOf(BOB) == 0 && token.balanceOf(address(this)) == SUPPLY, "moved something");
        require(token.allowance(address(this), STRANGER) == 0, "allowance appeared");
    }

    function testOwnerSpendingItselfThroughTransferFromNeedsSelfAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), ALICE, 1);
        token.approve(address(this), 5);
        require(token.transferFrom(address(this), ALICE, 5), "self-approved transferFrom");
        require(token.allowance(address(this), address(this)) == 0, "self allowance consumed");
        require(token.balanceOf(ALICE) == 5, "recipient");
    }

    function testAllowanceOneBelowInfinityIsFinite() public {
        uint256 almost = type(uint256).max - 1;
        token.approve(SPENDER, almost);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        require(token.allowance(address(this), SPENDER) == almost - 1, "near-infinite allowance must decrement");
    }

    function testAllowanceExactlyConsumedThenNextUnitRefused() public {
        token.approve(SPENDER, 7);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 7);
        require(token.allowance(address(this), SPENDER) == 0, "allowance not exhausted");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        require(token.balanceOf(ALICE) == 7, "second transfer moved funds");
    }

    function testInfiniteAllowanceStillBoundedByBalance() public {
        token.transfer(ALICE, 10);
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10, 11));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 11);
        require(token.allowance(ALICE, SPENDER) == type(uint256).max, "infinite allowance changed on failure");
        require(token.balanceOf(ALICE) == 10 && token.balanceOf(BOB) == 0, "failure moved funds");
    }

    function testTransferFromEmitsOnlyTransferNamedAfterOwner() public {
        token.approve(SPENDER, 10);
        vm.recordLogs();
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "transferFrom must emit exactly one event");
        require(logs[0].emitter == address(token), "emitter");
        require(logs[0].topics[0] == TRANSFER_TOPIC, "not a Transfer");
        require(
            logs[0].topics[1] == bytes32(uint256(uint160(address(this)))), "from must be the owner, not the spender"
        );
        require(logs[0].topics[2] == bytes32(uint256(uint160(ALICE))), "to");
        require(abi.decode(logs[0].data, (uint256)) == 4, "value");
    }

    function testApprovalReplacementEmitsEvenWhenUnchanged() public {
        token.approve(SPENDER, 9);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), SPENDER, 9);
        token.approve(SPENDER, 9);
        require(token.allowance(address(this), SPENDER) == 9, "allowance");
        vm.recordLogs();
        token.approve(SPENDER, 9);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1 && logs[0].topics[0] == APPROVAL_TOPIC, "approve must emit exactly one Approval");
    }

    function testApprovalsAreIndependentPerSpenderAndOwner() public {
        token.approve(SPENDER, 1);
        token.approve(ALICE, 2);
        vm.prank(BOB);
        token.approve(SPENDER, 3);
        require(token.allowance(address(this), SPENDER) == 1, "spender one");
        require(token.allowance(address(this), ALICE) == 2, "spender two");
        require(token.allowance(BOB, SPENDER) == 3, "other owner");
        require(token.allowance(SPENDER, address(this)) == 0, "reverse pair");
        require(token.allowance(ALICE, address(this)) == 0, "reverse pair two");
    }

    // ----------------------------------------------------------------------------------------------
    // Tokens that reach the token contract itself
    // ----------------------------------------------------------------------------------------------

    /// @dev There is no recovery hand, and that is by design: tokens sent to the contract are gone.
    /// The README states this; the test pins that nobody, deployer included, can pull them back.
    function testTokensSentToTheContractCannotBeRecoveredByAnyone() public {
        token.transfer(address(token), 1 ether);
        require(token.balanceOf(address(token)) == 1 ether, "contract balance");
        require(token.totalSupply() == SUPPLY, "supply");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(token), address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, STRANGER, 0, 1));
        vm.prank(STRANGER);
        token.transferFrom(address(token), STRANGER, 1);
        (bool ok,) = address(token).call(abi.encodeWithSignature("recover(address,uint256)", address(this), 1 ether));
        require(!ok, "recover entry point exists");
        (ok,) = address(token).call(abi.encodeWithSignature("rescueTokens(address,uint256)", address(token), 1 ether));
        require(!ok, "rescue entry point exists");
        require(token.balanceOf(address(token)) == 1 ether, "someone recovered the stuck balance");
    }

    // ----------------------------------------------------------------------------------------------
    // Bytecode
    // ----------------------------------------------------------------------------------------------

    function testRuntimeHasNoDelegatecallCallcodeOrSelfdestructAndFitsEip170() public view {
        bytes memory runtime = address(token).code;
        require(runtime.length > 0 && runtime.length <= 24_576, "runtime size");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            require(op != 0xF4, "DELEGATECALL");
            require(op != 0xF2, "CALLCODE");
            require(op != 0xFF, "SELFDESTRUCT");
            require(op != 0xF0 && op != 0xF5, "CREATE in token runtime");
        }
    }

    // ----------------------------------------------------------------------------------------------
    // Fuzzed properties
    // ----------------------------------------------------------------------------------------------

    function testFuzzTransferToArbitraryReceiverDeliversExactly(address to, uint256 rawAmount) public {
        if (to == address(0)) to = address(1);
        uint256 amount = rawAmount % (SUPPLY + 1);
        uint256 before = token.balanceOf(to);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), to, amount);
        require(token.transfer(to, amount), "transfer");
        if (to == address(this)) {
            require(token.balanceOf(to) == SUPPLY, "self transfer changed balance");
        } else {
            require(token.balanceOf(to) == before + amount, "receiver");
            require(token.balanceOf(address(this)) == SUPPLY - amount, "sender");
        }
        require(token.totalSupply() == SUPPLY, "supply");
    }

    function testFuzzApproveStoresExactValue(address spender, uint256 amount) public {
        if (spender == address(0)) spender = address(1);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, amount);
        require(token.approve(spender, amount), "approve");
        require(token.allowance(address(this), spender) == amount, "allowance stored");
        require(token.allowance(spender, address(this)) == 0, "reverse allowance");
        require(token.balanceOf(spender) == (spender == address(this) ? SUPPLY : 0), "approve moved tokens");
    }

    function testFuzzSpendingPastAllowanceRevertsWithExactError(uint256 rawAllowance, uint256 rawExcess) public {
        uint256 allowance = rawAllowance % SUPPLY;
        uint256 amount = allowance + 1 + rawExcess % (SUPPLY - allowance);
        token.approve(SPENDER, allowance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, allowance, amount)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, amount);
        require(token.allowance(address(this), SPENDER) == allowance, "allowance changed on failure");
        require(token.balanceOf(ALICE) == 0, "failure moved funds");
    }

    function testFuzzHolderOverdrawRevertsWithExactError(uint256 rawHeld, uint256 rawExcess) public {
        uint256 held = rawHeld % SUPPLY;
        uint256 amount = held + 1 + rawExcess % (type(uint256).max - held - 1);
        token.transfer(ALICE, held);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, amount));
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        require(token.balanceOf(ALICE) == held && token.balanceOf(BOB) == 0, "failure moved funds");
    }

    /// @dev A chain of hops through three holders returns exactly what left, with no residue anywhere.
    function testFuzzRoundTripThroughThreeHoldersReturnsExactly(uint256 rawAmount, uint8 rawHops) public {
        uint256 amount = rawAmount % (SUPPLY + 1);
        uint256 hops = 1 + rawHops % 16;
        address[3] memory ring = [ALICE, BOB, SPENDER];
        token.transfer(ALICE, amount);
        for (uint256 i; i < hops; ++i) {
            address from = ring[i % 3];
            address to = ring[(i + 1) % 3];
            vm.prank(from);
            require(token.transfer(to, amount), "hop");
            require(token.balanceOf(from) == 0, "hop left residue");
            require(token.balanceOf(to) == amount, "hop arrived short");
        }
        address last = ring[hops % 3];
        vm.prank(last);
        token.transfer(address(this), amount);
        require(token.balanceOf(address(this)) == SUPPLY, "round trip lost or gained");
        require(token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(SPENDER) == 0, "residue");
        require(token.totalSupply() == SUPPLY, "supply");
    }

    /// @dev Splitting the supply across many receivers conserves it exactly, down to the last unit.
    function testFuzzSplitAcrossReceiversConservesSupply(uint256 rawParts, uint256 rawUnit) public {
        uint256 parts = 1 + rawParts % 32;
        uint256 unit = rawUnit % (SUPPLY / parts + 1);
        uint256 sent;
        for (uint256 i; i < parts; ++i) {
            address to = address(uint160(0x1000 + i));
            token.transfer(to, unit);
            sent += unit;
            require(token.balanceOf(to) == unit, "receiver");
        }
        require(token.balanceOf(address(this)) == SUPPLY - sent, "remainder");
        uint256 sum = token.balanceOf(address(this));
        for (uint256 i; i < parts; ++i) {
            sum += token.balanceOf(address(uint160(0x1000 + i)));
        }
        require(sum == SUPPLY, "conservation");
    }

    /// @dev Infinite allowance survives any number of spends; a finite one is consumed exactly.
    function testFuzzRepeatedDelegatedSpendsConsumeExactly(uint256 rawAllowance, uint8 rawSpends, uint256 rawUnit)
        public
    {
        uint256 spends = 1 + rawSpends % 8;
        bool infinite = rawAllowance % 2 == 0;
        uint256 unit = rawUnit % (SUPPLY / spends + 1);
        uint256 allowance = infinite ? type(uint256).max : unit * spends + rawAllowance % (SUPPLY - unit * spends + 1);
        token.approve(SPENDER, allowance);
        for (uint256 i; i < spends; ++i) {
            vm.prank(SPENDER);
            require(token.transferFrom(address(this), ALICE, unit), "spend");
        }
        require(token.balanceOf(ALICE) == unit * spends, "delivered total");
        require(
            token.allowance(address(this), SPENDER) == (infinite ? type(uint256).max : allowance - unit * spends),
            "allowance after spends"
        );
        require(token.balanceOf(address(this)) + token.balanceOf(ALICE) == SUPPLY, "conservation");
    }
}
