// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Pepe2Pepe} from "../src/Pepe2Pepe.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

// Only the cheatcodes used here; no downloaded test framework is required.
interface Vm {
    function prank(address sender) external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data) external;
}

contract TokenFactoryProbe {
    function deploy() external returns (Pepe2Pepe) {
        return new Pepe2Pepe();
    }
}

contract Pepe2PepeTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0xCA11);
    Pepe2Pepe private token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new Pepe2Pepe();
    }

    function testMetadataAndInitialSupply() public view {
        require(keccak256(bytes(token.name())) == keccak256("Pepe2Pepe"), "name");
        require(keccak256(bytes(token.symbol())) == keccak256("P2P"), "symbol");
        require(token.decimals() == 18, "decimals");
        require(token.INITIAL_SUPPLY() == SUPPLY, "constant");
        require(token.totalSupply() == SUPPLY, "supply");
        require(token.balanceOf(address(this)) == SUPPLY, "deployer allocation");
        require(token.balanceOf(ALICE) == 0 && token.balanceOf(address(0)) == 0, "other allocation");
    }

    function testConstructorEmitsMint() public {
        TokenFactoryProbe factory = new TokenFactoryProbe();
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(factory), SUPPLY);
        Pepe2Pepe deployed = factory.deploy();
        require(deployed.balanceOf(address(factory)) == SUPPLY, "factory must receive mint");
        require(deployed.balanceOf(address(this)) == 0, "origin must not receive mint");
        require(deployed.totalSupply() == SUPPLY, "factory deployment supply");
    }

    function testTransferEmitsEventAndDeliversExactly() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, 123 ether);
        require(token.transfer(ALICE, 123 ether), "return value");
        require(token.balanceOf(ALICE) == 123 ether, "recipient");
        require(token.balanceOf(address(this)) == SUPPLY - 123 ether, "sender");
        require(token.totalSupply() == SUPPLY, "supply changed");
    }

    function testZeroAndSelfTransfers() public {
        vm.prank(ALICE);
        require(token.transfer(BOB, 0), "zero transfer");
        require(token.transfer(address(this), SUPPLY), "self transfer");
        require(token.balanceOf(address(this)) == SUPPLY, "self transfer changed balance");
        require(token.totalSupply() == SUPPLY, "supply changed");
    }

    function testTransferEntireSupply() public {
        require(token.transfer(ALICE, SUPPLY), "transfer");
        require(token.balanceOf(ALICE) == SUPPLY, "recipient");
        require(token.balanceOf(address(this)) == 0, "sender");
    }

    function testTransferToZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        require(token.balanceOf(address(this)) == SUPPLY, "failure changed balance");
    }

    function testTransferOverBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        require(token.balanceOf(BOB) == 0, "failure moved funds");
    }

    function testApprovalEmitsEventCanReplaceAndRevoke() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), SPENDER, 10 ether);
        require(token.approve(SPENDER, 10 ether), "approve");
        require(token.allowance(address(this), SPENDER) == 10 ether, "allowance");
        token.approve(SPENDER, 3 ether);
        require(token.allowance(address(this), SPENDER) == 3 ether, "replacement");
        token.approve(SPENDER, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), BOB, 1);
    }

    function testApproveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function testTransferFromConsumesAllowance() public {
        token.approve(SPENDER, 50 ether);
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, 20 ether), "transferFrom");
        require(token.allowance(address(this), SPENDER) == 30 ether, "allowance consumption");
        require(token.balanceOf(ALICE) == 20 ether, "recipient");
        require(token.balanceOf(address(this)) == SUPPLY - 20 ether, "sender");
    }

    function testInfiniteAllowanceRemainsUnchanged() public {
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 20 ether);
        require(token.allowance(address(this), SPENDER) == type(uint256).max, "infinite allowance");
    }

    function testTransferFromInsufficientAllowanceReverts() public {
        token.approve(SPENDER, 4);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 4, 5));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 5);
        require(token.allowance(address(this), SPENDER) == 4, "failure changed allowance");
        require(token.balanceOf(address(this)) == SUPPLY && token.balanceOf(ALICE) == 0, "failure moved funds");
    }

    function testTransferFromInsufficientBalanceRollsBackAllowance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 10));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 10);
        require(token.allowance(ALICE, SPENDER) == 10, "failed transfer consumed allowance");
        require(token.balanceOf(BOB) == 0, "failure moved funds");
    }

    function testTransferFromZeroRecipientRollsBackAllowance() public {
        token.approve(SPENDER, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 10);
        require(token.allowance(address(this), SPENDER) == 10, "failure changed allowance");
        require(token.totalSupply() == SUPPLY, "failure burned supply");
    }

    function testTransferFromZeroSenderRevertsEvenForZero() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
    }

    function testDeployerCannotTakeHolderFundsWithoutApproval() public {
        token.transfer(ALICE, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(ALICE, address(this), 1);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        require(token.balanceOf(BOB) == 100 ether, "holder cannot transfer");
    }

    function testNoMintBurnOrAdminEntryPoints() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "transferOwnership(address)",
            "initialize(address)",
            "upgradeTo(address)"
        ];
        token.transfer(ALICE, 100 ether);
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, 1 ether);
            (bool deployerOk,) = address(token).call(data);
            require(!deployerOk, "deployer reached unsupported method");
            vm.prank(BOB);
            (bool strangerOk,) = address(token).call(data);
            require(!strangerOk, "stranger reached unsupported method");
        }
        require(token.totalSupply() == SUPPLY, "supply changed");
        require(token.balanceOf(ALICE) == 100 ether, "admin affected holder");
    }

    function testFuzzTransferConservesSupply(uint256 rawAmount) public {
        uint256 amount = rawAmount % (SUPPLY + 1);
        token.transfer(ALICE, amount);
        require(token.balanceOf(ALICE) == amount, "received amount");
        require(token.balanceOf(address(this)) + token.balanceOf(ALICE) == SUPPLY, "conservation");
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        require(token.balanceOf(ALICE) == 0 && token.balanceOf(BOB) == amount, "onward transfer");
        require(token.totalSupply() == SUPPLY, "supply changed");
    }

    function testFuzzDelegatedTransfer(uint256 rawAmount, uint256 rawAllowance) public {
        uint256 allowance = rawAllowance % (SUPPLY + 1);
        uint256 amount = rawAmount % (allowance + 1);
        token.approve(SPENDER, allowance);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, amount);
        require(token.allowance(address(this), SPENDER) == allowance - amount, "remaining allowance");
        require(token.balanceOf(ALICE) == amount, "received amount");
        require(token.balanceOf(address(this)) + token.balanceOf(ALICE) == SUPPLY, "conservation");
        require(token.totalSupply() == SUPPLY, "supply changed");
    }

    function testFuzzOverdrawReverts(uint256 rawExcess) public {
        uint256 amount = SUPPLY + 1 + rawExcess % (type(uint256).max - SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount)
        );
        token.transfer(ALICE, amount);
        require(token.balanceOf(address(this)) == SUPPLY, "failure changed balance");
    }
}
