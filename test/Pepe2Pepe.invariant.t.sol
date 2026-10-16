// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Pepe2Pepe} from "../src/Pepe2Pepe.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

// Only the cheatcodes the handler needs; the suite is self-contained, like the existing one.
interface Vm {
    function prank(address sender) external;
    function label(address account, string calldata newLabel) external;
}

/// @notice Drives the token with random, bounded call sequences from several actors and mirrors in
/// ghost variables what every balance and allowance must be. The handler deploys the token itself so
/// it is the deployer and holds the whole supply at the start, exactly as the launch factory would.
/// @dev Failure paths are driven too: every function whose name ends in `Reverts` builds an input
/// the token must refuse, checks the exact ERC-6093 error, and checks that nothing moved.
contract Pepe2PepeHandler {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    Pepe2Pepe public immutable token;

    /// @dev Actors: the deployer (this handler), four externally owned accounts, and the token
    /// contract itself as a sink that can receive but never send.
    address[] public actors;
    address[] public owners;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    uint256 public ghostMoved;
    uint256 public ghostSinkHighWater;

    uint256 public transfers;
    uint256 public delegatedTransfers;
    uint256 public approvals;
    uint256 public refusedOverdraws;
    uint256 public refusedOverspends;
    uint256 public refusedZeroReceivers;

    constructor() {
        token = new Pepe2Pepe();
        owners.push(address(this));
        owners.push(address(0xA11CE));
        owners.push(address(0xB0B));
        owners.push(address(0xCA201));
        owners.push(address(0xDA7E));
        for (uint256 i; i < owners.length; ++i) {
            actors.push(owners[i]);
        }
        actors.push(address(token));
        vm.label(address(0xA11CE), "alice");
        vm.label(address(0xB0B), "bob");
        vm.label(address(0xCA201), "carol");
        vm.label(address(0xDA7E), "dave");
        ghostBalance[address(this)] = SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function ownerCount() external view returns (uint256) {
        return owners.length;
    }

    // ----------------------------------------------------------------------------------------------
    // Happy paths with bounded inputs
    // ----------------------------------------------------------------------------------------------

    /// @notice A holder sends between zero and its whole balance to any actor, itself included.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _owner(fromSeed);
        address to = _actor(toSeed);
        amount = _bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        require(ok, "transfer returned false");

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostMoved += amount;
        _trackSink();
        ++transfers;
    }

    /// @notice An owner sets any allowance, including zero and the infinite sentinel.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _owner(ownerSeed);
        address spender = _actor(spenderSeed);
        // One in eight approvals is infinite so the sentinel path is exercised.
        if (amount % 8 == 0) amount = type(uint256).max;

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        require(ok, "approve returned false");

        ghostAllowance[owner][spender] = amount;
        ++approvals;
    }

    /// @notice A spender moves within both the allowance and the owner's balance.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _owner(spenderSeed);
        address owner = _owner(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowance = token.allowance(owner, spender);
        uint256 cap = token.balanceOf(owner);
        if (allowance < cap) cap = allowance;
        amount = _bound(amount, 0, cap);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        require(ok, "transferFrom returned false");

        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        ghostMoved += amount;
        if (allowance != type(uint256).max) ghostAllowance[owner][spender] = allowance - amount;
        _trackSink();
        ++delegatedTransfers;
    }

    // ----------------------------------------------------------------------------------------------
    // Failure paths: the token must refuse, name the reason, and leave state untouched
    // ----------------------------------------------------------------------------------------------

    /// @notice Sending one base unit more than held must revert with the exact balance error.
    function transferOverdrawReverts(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _owner(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        uint256 amount = held + _bound(excess, 1, type(uint256).max - held);

        vm.prank(from);
        try token.transfer(to, amount) {
            revert("overdraw was accepted");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(
                        abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount)
                    ),
                "overdraw reverted with the wrong reason"
            );
        }
        require(token.balanceOf(from) == held, "a refused transfer changed the sender");
        ++refusedOverdraws;
    }

    /// @notice Spending more than the finite allowance must revert with the allowance error, and the
    /// allowance must survive the failure unchanged.
    function transferFromOverspendReverts(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _owner(spenderSeed);
        address owner = _owner(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowance = token.allowance(owner, spender);
        if (allowance == type(uint256).max) {
            // An infinite allowance cannot be overspent; pin it to a finite one first.
            allowance = _bound(excess, 0, SUPPLY);
            vm.prank(owner);
            token.approve(spender, allowance);
            ghostAllowance[owner][spender] = allowance;
        }
        uint256 amount = allowance + _bound(excess, 1, type(uint256).max - allowance);
        uint256 ownerHeld = token.balanceOf(owner);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            revert("overspend was accepted");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(
                        abi.encodeWithSelector(
                            IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount
                        )
                    ),
                "overspend reverted with the wrong reason"
            );
        }
        require(token.allowance(owner, spender) == allowance, "a refused transferFrom changed the allowance");
        require(token.balanceOf(owner) == ownerHeld, "a refused transferFrom changed the owner");
        ++refusedOverspends;
    }

    /// @notice A spender with enough allowance but an owner with too little balance: the balance
    /// error wins and the allowance is not consumed.
    function transferFromOverBalanceReverts(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _owner(spenderSeed);
        address owner = _owner(ownerSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(owner);
        uint256 amount = held + _bound(excess, 1, SUPPLY);

        // Grant exactly the amount so only the balance can refuse it.
        vm.prank(owner);
        token.approve(spender, amount);
        ghostAllowance[owner][spender] = amount;

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            revert("transfer over balance was accepted");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(
                        abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount)
                    ),
                "over-balance transferFrom reverted with the wrong reason"
            );
        }
        require(token.allowance(owner, spender) == amount, "a refused transferFrom consumed the allowance");
        require(token.balanceOf(owner) == held, "a refused transferFrom changed the owner");
    }

    /// @notice The zero address is never a valid receiver, whatever the amount.
    function transferToZeroReverts(uint256 fromSeed, uint256 amount) external {
        address from = _owner(fromSeed);
        amount = _bound(amount, 0, token.balanceOf(from));
        uint256 held = token.balanceOf(from);

        vm.prank(from);
        try token.transfer(address(0), amount) {
            revert("transfer to the zero address was accepted");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))),
                "zero receiver reverted with the wrong reason"
            );
        }
        require(token.balanceOf(from) == held, "a refused transfer changed the sender");
        require(token.totalSupply() == SUPPLY, "a refused transfer burned supply");
        ++refusedZeroReceivers;
    }

    /// @notice The zero spender can never be approved.
    function approveZeroSpenderReverts(uint256 ownerSeed, uint256 amount) external {
        address owner = _owner(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) {
            revert("approval of the zero spender was accepted");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))),
                "zero spender reverted with the wrong reason"
            );
        }
    }

    /// @notice A stranger with no allowance cannot move anything but zero from a holder.
    function strangerCannotSpendReverts(uint256 ownerSeed, uint256 amount) external {
        address stranger = address(0x5712A6E2);
        address owner = _owner(ownerSeed);
        uint256 held = token.balanceOf(owner);
        amount = _bound(amount, 1, SUPPLY);
        uint256 allowance = token.allowance(owner, stranger);
        require(allowance == 0, "a stranger acquired an allowance");

        vm.prank(stranger);
        try token.transferFrom(owner, stranger, amount) {
            revert("a stranger spent a holder's balance");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(
                        abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount)
                    ),
                "stranger spend reverted with the wrong reason"
            );
        }
        require(token.balanceOf(owner) == held, "a refused spend changed the holder");
        require(token.balanceOf(stranger) == 0, "a stranger received tokens");
    }

    // ----------------------------------------------------------------------------------------------

    function _owner(uint256 seed) private view returns (address) {
        return owners[seed % owners.length];
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _trackSink() private {
        uint256 sink = token.balanceOf(address(token));
        if (sink > ghostSinkHighWater) ghostSinkHighWater = sink;
    }

    /// @dev Uniform-ish bound into [min, max], never discarding a run.
    function _bound(uint256 x, uint256 min, uint256 max) private pure returns (uint256) {
        require(min <= max, "bound: min > max");
        uint256 size = max - min;
        if (size == type(uint256).max) return x;
        return min + (x % (size + 1));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract Pepe2PepeInvariantTest {
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    Pepe2PepeHandler private handler;
    Pepe2Pepe private token;

    function setUp() public {
        handler = new Pepe2PepeHandler();
        token = handler.token();
    }

    /// @dev Only the handler is driven; the token is reached through it with bounded inputs.
    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function targetSelectors() public view returns (FuzzSelector[] memory targets) {
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = Pepe2PepeHandler.transfer.selector;
        selectors[1] = Pepe2PepeHandler.approve.selector;
        selectors[2] = Pepe2PepeHandler.transferFrom.selector;
        selectors[3] = Pepe2PepeHandler.transferOverdrawReverts.selector;
        selectors[4] = Pepe2PepeHandler.transferFromOverspendReverts.selector;
        selectors[5] = Pepe2PepeHandler.transferFromOverBalanceReverts.selector;
        selectors[6] = Pepe2PepeHandler.transferToZeroReverts.selector;
        selectors[7] = Pepe2PepeHandler.approveZeroSpenderReverts.selector;
        selectors[8] = Pepe2PepeHandler.strangerCannotSpendReverts.selector;
        targets = new FuzzSelector[](1);
        targets[0] = FuzzSelector(address(handler), selectors);
    }

    /// @notice The supply is fixed at construction and nothing can grow or shrink it.
    function invariant_totalSupplyIsFixed() public view {
        require(token.totalSupply() == SUPPLY, "total supply changed");
        require(token.INITIAL_SUPPLY() == SUPPLY, "constant changed");
    }

    /// @notice What every actor holds adds up to exactly the supply: nothing leaks, nothing appears.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 count = handler.actorCount();
        for (uint256 i; i < count; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        require(sum == SUPPLY, "balances do not sum to the supply");
    }

    /// @notice Every balance is exactly what the ghost ledger predicts from the accepted calls.
    function invariant_balancesMatchGhostLedger() public view {
        uint256 count = handler.actorCount();
        for (uint256 i; i < count; ++i) {
            address actor = handler.actors(i);
            require(token.balanceOf(actor) == handler.ghostBalance(actor), "balance diverged from ghost");
            require(token.balanceOf(actor) <= SUPPLY, "balance exceeds the supply");
        }
    }

    /// @notice Every allowance is exactly what was approved minus what was spent; infinite stays infinite.
    function invariant_allowancesMatchGhostLedger() public view {
        uint256 ownerCount = handler.ownerCount();
        uint256 actorCount = handler.actorCount();
        for (uint256 i; i < ownerCount; ++i) {
            address owner = handler.owners(i);
            for (uint256 j; j < actorCount; ++j) {
                address spender = handler.actors(j);
                require(
                    token.allowance(owner, spender) == handler.ghostAllowance(owner, spender),
                    "allowance diverged from ghost"
                );
            }
        }
    }

    /// @notice Tokens that reach the token contract itself never leave it: there is no recovery hand.
    function invariant_tokenContractIsASink() public view {
        require(token.balanceOf(address(token)) == handler.ghostSinkHighWater(), "the token contract paid out");
    }

    /// @notice The zero address and an address nobody ever sent to hold nothing.
    function invariant_nobodyElseHoldsAnything() public view {
        require(token.balanceOf(address(0)) == 0, "the zero address holds tokens");
        require(token.balanceOf(address(0x5712A6E2)) == 0, "a stranger holds tokens");
        require(token.balanceOf(address(this)) == 0, "the test contract holds tokens");
    }

    /// @notice Metadata is immutable across any sequence of calls.
    function invariant_metadataIsImmutable() public view {
        require(keccak256(bytes(token.name())) == keccak256("Pepe2Pepe"), "name changed");
        require(keccak256(bytes(token.symbol())) == keccak256("P2P"), "symbol changed");
        require(token.decimals() == 18, "decimals changed");
    }

    /// @notice Everything that ever moved was at most what the supply could cover per hop, and the
    /// deployer's balance is what remains of the supply after what it sent out net of what came back.
    function invariant_deployerHoldsTheRemainder() public view {
        uint256 others;
        uint256 count = handler.actorCount();
        for (uint256 i = 1; i < count; ++i) {
            others += token.balanceOf(handler.actors(i));
        }
        require(token.balanceOf(address(handler)) == SUPPLY - others, "deployer remainder is wrong");
    }
}
