// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BeforeSwapDelta} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {BaseHook} from '@uniswap/v4-periphery/utils/BaseHook.sol';

import {IPositionManager} from './interfaces/IPositionManager.sol';
import {IRevenueManager} from './interfaces/IRevenueManager.sol';
import {ITreasuryManagerFactory} from './interfaces/ITreasuryManagerFactory.sol';


contract AtriumFlaunchExample is BaseHook {

    struct FlaunchToken {
        address memecoin;
        uint tokenId;
        address payable manager;
    }

    address public immutable managerImplementation;

    IPositionManager public immutable positionManager;
    ITreasuryManagerFactory public immutable treasuryManagerFactory;

    mapping (PoolId _poolId => FlaunchToken _flaunchToken) public flaunchTokens;

    constructor(
        IPoolManager _poolManager,
        address _positionManager,
        address _treasuryManagerFactory,
        address _managerImplementation
    ) BaseHook(_poolManager) {
        positionManager = IPositionManager(_positionManager);
        treasuryManagerFactory = ITreasuryManagerFactory(_treasuryManagerFactory);
        managerImplementation = _managerImplementation;
    }

    function _afterInitialize(
        address, PoolKey calldata _key, uint160, int24
    ) internal override returns (bytes4) {
        // We can only flaunch a token if the pair is ETH
        if (Currency.unwrap(_key.currency0) != address(0)) {
            return IHooks.afterInitialize.selector;
        }

        // Flaunch our token
        address memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'SYMBOL',
                tokenUri: 'https://token.gg/',
                initialTokenFairLaunch: 50e27,
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 10_00, // 10% fees
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Get the flaunched tokenId
        uint tokenId = positionManager.flaunchContract().tokenId(memecoin);

        // Deploy our token to a fresh RevenueManager
        address payable manager = treasuryManagerFactory.deployManager(managerImplementation);

        // Initialize our manager with the token
        positionManager.flaunchContract().approve(manager, tokenId);
        IRevenueManager(manager).initialize(
            IRevenueManager.FlaunchToken(positionManager.flaunchContract(), tokenId),
            address(this),
            abi.encode(
                IRevenueManager.InitializeParams(
                    payable(address(this)),
                    payable(address(this)),
                    100_00
                )
            )
        );

        flaunchTokens[_key.toId()] = FlaunchToken({
            memecoin: memecoin,
            tokenId: tokenId,
            manager: manager
        });

        return IHooks.afterInitialize.selector;
    }

    function _beforeSwap(
        address, PoolKey calldata _key, IPoolManager.SwapParams calldata, bytes calldata
    ) internal override returns (bytes4 selector_, BeforeSwapDelta, uint24) {
        _claimAndDonateFees(_key);
        selector_ = IHooks.beforeSwap.selector;
    }

    function _beforeRemoveLiquidity(
        address, PoolKey calldata _key, IPoolManager.ModifyLiquidityParams calldata, bytes calldata
    ) internal override returns (bytes4) {
        _claimAndDonateFees(_key);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _beforeAddLiquidity(
        address, PoolKey calldata _key, IPoolManager.ModifyLiquidityParams calldata, bytes calldata
    ) internal override returns (bytes4) {
        _claimAndDonateFees(_key);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _claimAndDonateFees(PoolKey calldata _key) internal {
        PoolId poolId = _key.toId();

        // Ensure we have a FlaunchToken registered
        FlaunchToken memory flaunchToken = flaunchTokens[poolId];
        if (flaunchToken.tokenId == 0) {
            return;
        }

        // Withdraw the fees received by the manager
        (, uint ethReceived) = IRevenueManager(flaunchToken.manager).claim();

        // If we received no ETH, then we have nothing to donate
        if (ethReceived == 0) {
            return;
        }

        poolManager.donate({
            key: _key,
            amount0: ethReceived,
            amount1: 0,
            hookData: ''
        });
    }

    // Define which hooks are enabled
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    receive() external payable {}
}
