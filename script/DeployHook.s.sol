// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {PointsHook} from "../src/PointsHook.sol";

contract DeployHook is Script {
    // CREATE2 Deployer Proxy - Foundry routes `new X{salt: salt}()` through it
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    // The only hook permission we need is afterSwap
    uint160 constant FLAGS = uint160(Hooks.AFTER_SWAP_FLAG);
    // 2000 bps = 20% of ETH spent is minted as points
    uint256 constant POINTS_BPS = 2000;
    // Uniswap v4 PoolManager on mainnet
    address constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function run() external returns (address hookAddress) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address poolManager = vm.envOr("POOL_MANAGER", MAINNET_POOL_MANAGER);

        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), POINTS_BPS);

        // Mine a salt so the hook deploys to an address with AFTER_SWAP_FLAG set
        (address minedAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            FLAGS,
            type(PointsHook).creationCode,
            constructorArgs
        );

        vm.startBroadcast(privateKey);
        PointsHook hook = new PointsHook{salt: salt}(
            IPoolManager(poolManager),
            POINTS_BPS
        );
        vm.stopBroadcast();

        require(address(hook) == minedAddress, "DeployHook: address mismatch");

        hookAddress = address(hook);
        console.log("PointsHook deployed at:", hookAddress);
        console.log("flags in address:", uint160(hookAddress) & Hooks.ALL_HOOK_MASK);
    }
}
