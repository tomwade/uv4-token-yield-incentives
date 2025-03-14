// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from '@uniswap/v4-core/contracts/interfaces/IPoolManager.sol';
import {Hooks} from '@uniswap/v4-core/contracts/libraries/Hooks.sol';

import {BaseHook} from '@uniswap/v4-periphery/contracts/BaseHook.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {RevenueManager} from '@flaunch/treasury/managers/RevenueManager.sol';


contract AtriumFlaunchExample is BaseHook {

    struct FlaunchToken {
        address memecoin;
        uint tokenId;
        address payable manager;
        bool flipped;
    }

    address public immutable managerImplementation;

    PositionManager public immutable positionManager;
    TreasuryManagerFactory public immutable treasuryManagerFactory;

    mapping (PoolId _poolId => FlaunchToken _flaunchToken) public flaunchTokens;

    constructor(
        IPoolManager _poolManager,
        PositionManager _positionManager,
        TreasuryManagerFactory _treasuryManagerFactory,
        address _managerImplementation
    ) BaseHook(_poolManager) {
        positionManager = _positionManager;
        treasuryManagerFactory = _treasuryManagerFactory;
        managerImplementation = _managerImplementation;
    }

    function afterInitialize(
        address, IPoolManager.PoolKey calldata _key, uint160, int24
    ) external override poolManagerOnly {
        // We can only flaunch a token if the pair is ETH
        if (_key.currency0() != Currency.ADDRESS_ZERO() && _key.currency1() != Currency.ADDRESS_ZERO()) {
            return;
        }

        // Flaunch our token
        address memecoin = positionManager.flaunch(
            PositionManager.FlaunchParams(
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
            )
        );

        // Get the flaunched tokenId
        uint tokenId = flaunch.tokenId(memecoin);

        // Deploy our token to a fresh RevenueManager
        address payable manager = treasuryManagerFactory.deployManager(managerImplementation);

        // Initialize our manager with the token
        flaunch.approve(manager, tokenId);
        RevenueManager(manager).initialize(
            ITreasuryManager.FlaunchToken(positionManager.flaunch(), tokenId),
            address(this),
            abi.encode(
                RevenueManager.InitializeParams(address(this), address(this), 100_00)
            )
        );

        flaunchTokens[_key.toId()] = FlaunchToken({
            memecoin: memecoin,
            tokenId: tokenId,
            manager: manager,
            flipped: _key.currency1() == Currency.ADDRESS_ZERO()
        });
    }

    function beforeSwap(
        address, PoolKey calldata _key, IPoolManager.SwapParams memory, bytes calldata
    ) public override onlyPoolManager returns (bytes4 selector_, BeforeSwapDelta, uint24) {
        _claimAndDonateFees(_key);
        selector_ = IHooks.beforeSwap.selector;
    }

    function beforeRemoveLiquidity(
        address, PoolKey calldata _key, IPoolManager.ModifyLiquidityParams calldata, bytes calldata
    ) public view override onlyPoolManager returns (bytes4) {
        _claimAndDonateFees(_key);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function beforeAddLiquidity(
        address, PoolKey calldata _key, IPoolManager.ModifyLiquidityParams calldata, bytes calldata
    ) public view override onlyPoolManager returns (bytes4) {
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
        (, uint ethReceived) = RevenueManager(flaunchToken.manager).claim();

        // If we received no ETH, then we have nothing to donate
        if (ethReceived == 0) {
            return;
        }

        poolManager.donate({
            key: _key,
            amount0: flaunchToken.flipped ? 0 : ethReceived,
            amount1: flaunchToken.flipped ? ethReceived : 0,
            hookData: ''
        });
    }

    // Define which hooks are enabled
    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
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
