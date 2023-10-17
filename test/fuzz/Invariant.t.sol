// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantTest is StdInvariant, Test {

    DecentralizedStableCoin dsc;
    DSCEngine engine;
    DeployDSC deployer;
    HelperConfig config;
    Handler handler;

    address wEth;
    address wBtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (,,wEth, wBtc,) = config.activeNetworkConfig();

        handler = new Handler(engine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() external view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = ERC20Mock(wEth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = ERC20Mock(wBtc).balanceOf(address(engine));

        uint256 wEthValue = engine.getUsdValue(wEth, totalWethDeposited);
        uint256 wBtcValue = engine.getUsdValue(wBtc, totalWbtcDeposited);

        console.log("wEth Value: ", wEthValue);
        console.log("wBtc Value: ", wBtcValue);
        console.log("Total supply: ", totalSupply);
        console.log("Times mint is called: ", handler.timesMintIsCalled());

        assert(wEthValue + wBtcValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() external view {
        engine.getAccountCollateralValue(msg.sender);
        engine.getAccountInformation(msg.sender);
        engine.getAdditionalFeedPrecision();
        engine.getCollateralBalanceOfUser(msg.sender, wEth);
        engine.getCollateralTokenPriceFeed(wEth);
        engine.getCollateralTokens();
        engine.getDsc();
        engine.getDscMintedAmount(msg.sender);
        //engine.getHealthFactor(msg.sender);
        engine.getLiquidationBonus();
        engine.getLiquidationPrecision();
        engine.getLiquidationThreshold();
        engine.getMinHealthFactor();
        engine.getPrecision();
        engine.getTokenAmountFromUsd(wEth , 100e18);
        engine.getUsdValue(wEth,100e18);
    }
}