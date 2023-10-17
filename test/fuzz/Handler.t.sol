// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    ERC20Mock wEth;
    ERC20Mock wBtc;
    MockV3Aggregator ethUsdPriceFeed;

    uint256 public timesMintIsCalled;

    address[] private usersWithCollateralDeposited;
    mapping(address user => bool hasDeposited) private hasDeposited;
    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        wEth = ERC20Mock(collateralTokens[0]);
        wBtc = ERC20Mock(collateralTokens[1]);
        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(wEth)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        collateralAmount = bound(collateralAmount, 1, type(uint96).max);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, collateralAmount);
        collateral.approve(address(engine), collateralAmount);
        engine.depositCollateral(address(collateral), collateralAmount);
        vm.stopPrank();
        
        if (hasDeposited[msg.sender]) return;
        usersWithCollateralDeposited.push(msg.sender);
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) return;
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);

        if (maxDscToMint < 0) {
            return;
        }

        amount = bound(amount, 0, uint256(maxDscToMint));

        if (amount == 0) {
            return;
        }

        vm.startPrank(sender);
        engine.mintDsc(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral =  _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralAmount = engine.getCollateralBalanceOfUser(address(collateral), msg.sender);
        collateralAmount = bound(collateralAmount, 1, maxCollateralAmount);
        if (collateralAmount == 0) return;

        vm.startPrank(msg.sender);
        engine.redeemCollateral(address(collateral), collateralAmount);
        vm.stopPrank();
    }

    // This breaks our invariance
    //function updateCollateralPrice(uint96 price) public {
    //    int256 newPrice = int256(uint256(price));
    //    ethUsdPriceFeed.updateAnswer(newPrice);
    //}

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) return wEth;
        return wBtc;
    }
}