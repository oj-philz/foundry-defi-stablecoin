// SPDX-License-Identifier: MIT
/*
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract OpenInvariantTest is StdInvariant, Test {

    DecentralizedStableCoin dsc;
    DSCEngine engine;
    DeployDSC deployer;
    HelperConfig config;

    address wEth;
    address wBtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (,,wEth, wBtc,) = config.activeNetworkConfig();
        targetContract(address(engine));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() external view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = ERC20Mock(wEth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = ERC20Mock(wBtc).balanceOf(address(engine));

        uint256 wEthValue = engine.getUsdValue(wEth, totalWethDeposited);
        uint256 wBtcValue = engine.getUsdValue(wBtc, totalWbtcDeposited);

        assert(wEthValue + wBtcValue >= totalSupply);
    }
}*/