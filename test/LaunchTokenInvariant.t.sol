// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A closed set of holders makes the sum-of-balances property exhaustive.
contract LaunchTokenHandler is Test {
    uint256 private constant SUPPLY = 1e27;
    LaunchToken public immutable token;
    address[5] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public successfulCalls;
    uint256 public rejectedCalls;

    constructor(LaunchToken token_, address deployer) {
        token = token_;
        actors[0] = deployer;
        for (uint256 i = 1; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("LOOM holder ", vm.toString(i)));
        }
        expectedBalance[deployer] = SUPPLY;
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 amountSeed, uint8 kindSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = toSeed % 6 == 5 ? address(0) : actors[toSeed % actors.length];
        uint256 amount = _amount(amountSeed, kindSeed, expectedBalance[from]);
        bool expected = to != address(0) && amount <= expectedBalance[from];
        _execute(from, abi.encodeCall(IERC20.transfer, (to, amount)), expected);
        if (expected) {
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
        }
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amountSeed, bool unlimited) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = spenderSeed % 6 == 5 ? address(0) : actors[spenderSeed % actors.length];
        uint256 amount = unlimited ? type(uint256).max : bound(amountSeed, 0, SUPPLY);
        bool expected = spender != address(0);
        _execute(owner, abi.encodeCall(IERC20.approve, (spender, amount)), expected);
        if (expected) expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint8 spenderSeed, uint8 fromSeed, uint8 toSeed, uint256 amountSeed, uint8 kindSeed)
        external
    {
        address spender = actors[spenderSeed % actors.length];
        address from = actors[fromSeed % actors.length];
        address to = toSeed % 6 == 5 ? address(0) : actors[toSeed % actors.length];
        uint256 amount = _amount(amountSeed, kindSeed, expectedBalance[from]);
        uint256 allowance = expectedAllowance[from][spender];
        bool expected = to != address(0) && amount <= expectedBalance[from] && amount <= allowance;
        _execute(spender, abi.encodeCall(IERC20.transferFrom, (from, to, amount)), expected);
        if (expected) {
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
            if (allowance != type(uint256).max) expectedAllowance[from][spender] -= amount;
        }
    }

    function forbiddenAdminCall(uint8 callerSeed, uint8 selectorSeed, uint256 amount) external {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "pause()",
            "setMinter(address)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        address caller = actors[callerSeed % actors.length];
        vm.prank(caller);
        (bool success,) = address(token).call(abi.encodeWithSignature(signatures[selectorSeed % 6], caller, amount));
        assertFalse(success, "unexpected mint/burn/admin surface");
        ++rejectedCalls;
    }

    function _amount(uint256 seed, uint8 kindSeed, uint256 available) private pure returns (uint256) {
        uint256 kind = kindSeed % 5;
        if (kind == 0) return 0;
        if (kind == 1) return available;
        if (kind == 2) return available + 1;
        if (kind == 3) return type(uint256).max;
        return bound(seed, 0, SUPPLY);
    }

    function _execute(address caller, bytes memory data, bool expected) private {
        vm.prank(caller);
        (bool success, bytes memory result) = address(token).call(data);
        assertEq(success, expected, "token call disagrees with ledger");
        if (success) {
            assertTrue(abi.decode(result, (bool)));
            ++successfulCalls;
        } else {
            ++rejectedCalls;
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    LaunchToken private token;
    LaunchTokenHandler private handler;

    function setUp() public {
        address deployer = makeAddr("LOOM policy deployer");
        vm.prank(deployer);
        token = new LaunchToken();
        handler = new LaunchTokenHandler(token, deployer);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = LaunchTokenHandler.transfer.selector;
        selectors[1] = LaunchTokenHandler.approve.selector;
        selectors[2] = LaunchTokenHandler.transferFrom.selector;
        selectors[3] = LaunchTokenHandler.forbiddenAdminCall.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_FixedSupplyEqualsAllHolderBalances() public view {
        uint256 sum;
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            uint256 actual = token.balanceOf(actor);
            assertEq(actual, handler.expectedBalance(actor));
            sum += actual;
        }
        assertEq(sum, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.decimals(), 18);
    }

    function invariant_AllowanceChangesRequireApprovalOrSuccessfulSpending() public view {
        for (uint256 i; i < 5; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < 5; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }

    function test_LedgerHandlesFiniteAndInfiniteAllowancesAndFailedSpends() public {
        handler.approve(0, 1, 7, false);
        handler.transferFrom(1, 0, 2, 3, 4);
        handler.transferFrom(1, 0, 2, 5, 4); // Five exceeds the remaining allowance of four.
        assertEq(token.allowance(handler.actors(0), handler.actors(1)), 4);
        handler.transfer(2, 2, 0, 1); // A self-transfer of the entire balance conserves it.
        handler.approve(0, 1, 0, true);
        handler.transferFrom(1, 0, 3, 9, 4);
        assertEq(token.allowance(handler.actors(0), handler.actors(1)), type(uint256).max);
        handler.transferFrom(1, 0, 5, 1, 4); // Zero recipient cannot consume allowance or burn tokens.
        handler.approve(0, 1, 0, false);
        handler.transferFrom(1, 0, 3, 1, 4);
        invariant_FixedSupplyEqualsAllHolderBalances();
        invariant_AllowanceChangesRequireApprovalOrSuccessfulSpending();
        assertGt(handler.successfulCalls(), 0);
        assertEq(handler.rejectedCalls(), 3);
    }
}
