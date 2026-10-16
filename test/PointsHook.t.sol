// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";

import "forge-std/console.sol";
import {PointsHook} from "../src/PointsHook.sol";

contract TestPointsHook is Test, Deployers, ERC1155TokenReceiver {
    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    PointsHook hook;

    function setUp() public {
        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);

        // Deploy hook to an address that has the proper flags set
        // 2000 bps = 20% points rate
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        deployCodeTo("PointsHook.sol", abi.encode(manager, uint256(2000)), address(flags));

        // Deploy our hook
        hook = PointsHook(address(flags));

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key, ) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );

        // Add some liquidity to the pool
        _addLiquidity(key);
    }

    function _addLiquidity(PoolKey memory poolKey) internal {
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        uint256 ethToAdd = 0.1 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            SQRT_PRICE_1_1,
            sqrtPriceAtTickUpper,
            ethToAdd
        );
        uint256 tokenToAdd = LiquidityAmounts.getAmount1ForLiquidity(
            sqrtPriceAtTickLower,
            SQRT_PRICE_1_1,
            liquidityDelta
        );

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_swap() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        uint256 pointsBalanceOriginal = hook.balanceOf(
            address(this),
            poolIdUint
        );

        // Set user address in hook data
        bytes memory hookData = abi.encode(address(this));

        // Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14
        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );
        uint256 pointsBalanceAfterSwap = hook.balanceOf(
            address(this),
            poolIdUint
        );
        assertEq(pointsBalanceAfterSwap - pointsBalanceOriginal, 2 * 10 ** 14);
    }

    function _swapEthForTokens(uint256 ethIn, bytes memory hookData) internal {
        swapRouter.swap{value: ethIn}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn), // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );
    }

    // Sad path: no hookData means nobody gets points
    function test_swap_noPointsWithoutHookData() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));

        _swapEthForTokens(0.001 ether, bytes(""));

        assertEq(hook.balanceOf(address(this), poolIdUint), 0);
    }

    // Sad path: swapping TOKEN -> ETH (oneForZero) earns no points
    function test_swap_noPointsTokenForEth() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        bytes memory hookData = abi.encode(address(this));

        // Swap 10 TOKEN for ETH
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        assertEq(hook.balanceOf(address(this), poolIdUint), 0);
    }

    // Fuzz with bound(): map any input into a safe swap size
    function testFuzz_swap_points_bound(uint256 ethIn) public {
        ethIn = bound(ethIn, 1 gwei, 0.01 ether);

        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));

        _swapEthForTokens(ethIn, abi.encode(address(this)));

        assertEq(
            hook.balanceOf(address(this), poolIdUint),
            (ethIn * hook.pointsBps()) / 10_000
        );
    }

    // Fuzz with vm.assume(): keep only inputs that are valid preconditions
    function testFuzz_swap_points_assume(uint24 ethMicro, address recipient)
        public
    {
        // ETH in must be in (0, 0.01 ETH] so the thin test pool stays in range
        vm.assume(ethMicro > 0 && ethMicro <= 10_000_000);
        // ERC1155 cannot mint to the zero address
        vm.assume(recipient != address(0));
        // Minting to a contract that doesn't implement ERC1155TokenReceiver reverts,
        // so only allow EOAs or our own test contract
        vm.assume(recipient.code.length == 0 || recipient == address(this));

        uint256 ethIn = uint256(ethMicro) * 1 gwei;
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));

        _swapEthForTokens(ethIn, abi.encode(recipient));

        assertEq(
            hook.balanceOf(recipient, poolIdUint),
            (ethIn * hook.pointsBps()) / 10_000
        );
    }

    function test_pointsBps_configured() public view {
        assertEq(hook.pointsBps(), 2000);
    }

    function test_swap_customRate() public {
        // Deploy a second hook with a 10% points rate.
        // Bit 14 is outside the hook flag mask, so it gives a distinct valid address.
        uint160 flags2 = uint160(Hooks.AFTER_SWAP_FLAG) | (1 << 14);
        deployCodeTo(
            "PointsHook.sol", abi.encode(manager, uint256(1000)), address(flags2)
        );
        PointsHook hook2 = PointsHook(address(flags2));
        assertEq(hook2.pointsBps(), 1000);

        // Initialize a second pool (different fee) using the second hook
        (PoolKey memory key2, ) = initPool(
            ethCurrency, tokenCurrency, hook2, 500, SQRT_PRICE_1_1
        );
        _addLiquidity(key2);

        uint256 poolId2Uint = uint256(PoolId.unwrap(key2.toId()));
        uint256 pointsBalanceOriginal = hook2.balanceOf(address(this), poolId2Uint);

        bytes memory hookData = abi.encode(address(this));

        // Swap 0.001 ETH, expect 10% of 0.001 ether = 1 * 10**14 points
        swapRouter.swap{value: 0.001 ether}(
            key2,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 pointsBalanceAfterSwap = hook2.balanceOf(address(this), poolId2Uint);
        assertEq(pointsBalanceAfterSwap - pointsBalanceOriginal, 1 * 10 ** 14);
    }
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract TestPointsHookFork is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDC_WHALE = 0x55FE002aefF02F77364de339a1292923A15844B8;
    // Uniswap v4 PoolManager on mainnet
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    string constant DEFAULT_MAINNET_RPC = "https://ethereum-rpc.publicnode.com";

    uint256 forkId;

    modifier forked() {
        forkId = vm.createFork(
            vm.envOr("MAINNET_RPC_URL", DEFAULT_MAINNET_RPC)
        );
        vm.selectFork(forkId);
        _;
        vm.selectFork(0);
    }

    function test_fork_usdcWhaleBalance() public forked {
        uint256 balance = IERC20(USDC).balanceOf(USDC_WHALE);
        console.log("Whale balance (USDC):", balance / 1e6);
        assertGt(balance, 100_000 * 1e6, "Whale should have large balance");
    }

    function test_fork_v4PoolManagerDeployed() public forked {
        assertGt(
            POOL_MANAGER.code.length,
            0,
            "v4 PoolManager should be deployed on mainnet"
        );
    }
}
