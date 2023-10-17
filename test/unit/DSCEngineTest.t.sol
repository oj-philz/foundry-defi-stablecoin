// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;
import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    DeployDSC deployer;
    HelperConfig config;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address wEth;
    address wBtc;

    uint256 private constant COLLATERAL_AMOUNT = 10 ether;
    uint256 private constant MINT_AMOUNT = 8000 ether;
    uint256 private constant STARTING_BALANCE_USER = 10 ether;
    uint256 private constant STARTING_BALANCE_USER2 = 20 ether;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant PRECISION = 1e18;

    address USER = makeAddr("user");
    address USER2 = makeAddr("user2");

    address[] private s_priceFeedAddresses;
    address[] private s_tokenAddresses;

    event CollateralDeposited(
        address indexed user,
        address indexed tokenAddress,
        uint256 indexed collateralAmount
    );
    event CollateralRedeemed(address indexed tokenAddress, address indexed from, address indexed to, uint256 collateralAmount);

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();

        (ethUsdPriceFeed, btcUsdPriceFeed, wEth, wBtc,) = config.activeNetworkConfig();

        ERC20Mock(wEth).mint(USER, STARTING_BALANCE_USER);
        ERC20Mock(wEth).mint(USER2, STARTING_BALANCE_USER2);
    }

    ///////////////////////////// 
    // Constructor Tests   ////// 
    /////////////////////////////

    function testRevertIfTokenAndPriceFeedAddressesNotEqual() external {
        s_priceFeedAddresses.push(ethUsdPriceFeed);
        s_priceFeedAddresses.push(btcUsdPriceFeed);
        s_tokenAddresses.push(wEth);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAndPriceFeedAddressesMustBeEqual.selector);
        new DSCEngine(s_tokenAddresses, s_priceFeedAddresses, address(dsc));
    }

    /////////////////////// 
    // Price Tests   ////// 
    ///////////////////////

    function testGetUsdValue() external {
        uint256 amount = 15e18;
        uint256 expectedAmount = 30000e18;

        uint256 actualAmount = engine.getUsdValue(wEth, amount);

        assertEq(actualAmount, expectedAmount);
    }

    function testGetTokenAmountFromUsd() external {
        uint256 usdAmount = 100e18;
        uint256 expectedAmount = 5e16;

        uint256 actualAmount = engine.getTokenAmountFromUsd(wEth, usdAmount); // returns zero......
        console.log(expectedAmount, actualAmount);

        assertEq(actualAmount,expectedAmount);
    }

    /////////////////////////////////// 
    // depositCollateral Tests   ////// 
    ///////////////////////////////////

    function testRevertIfDepositCollateralAmountIsZero() external {
        vm.startPrank(USER);
        dsc.approve(address(engine), COLLATERAL_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.depositCollateral(wEth, 0);
        vm.stopPrank();
    }

    function testRevertIfCollateralTokenIsNotAllowed() external {
        ERC20Mock randToken = new ERC20Mock();
        console.log(address(randToken));
        vm.startPrank(USER);
        randToken.mint(USER, COLLATERAL_AMOUNT);
        randToken.approve(address(engine), COLLATERAL_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(randToken), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    modifier collateralDeposited() {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateral(wEth, COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetUserInfo() external collateralDeposited {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositedCollateral = engine.getTokenAmountFromUsd(wEth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(expectedDepositedCollateral, COLLATERAL_AMOUNT);
    }

    function testCanDepositCollateralAndEmitLog() external {
        vm.prank(USER);
        ERC20Mock(wEth).approve(address(engine), COLLATERAL_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit CollateralDeposited(USER, wEth, COLLATERAL_AMOUNT);

        vm.prank(USER);
        engine.depositCollateral(wEth, COLLATERAL_AMOUNT);
    }

    ///////////////////////// 
    // mintDsc Tests   //////
    /////////////////////////
    function testRevertIfMintAmountIsZero() external collateralDeposited {
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        vm.prank(USER);
        engine.mintDsc(0);
    }

    function testRevertIfHealthFactorIsBroken() external collateralDeposited {
        uint256 extraMintAmount = 2000 ether;
        
        vm.startPrank(USER);
        engine.mintDsc(MINT_AMOUNT);
        engine.mintDsc(extraMintAmount);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        vm.expectRevert(
            abi.encodeWithSignature(
                "DSCEngine__BreaksHealthFactor(uint256)", 
                engine.calculateHealthFactor(totalDscMinted + extraMintAmount, collateralValueInUsd)
            )
        );
        engine.mintDsc(extraMintAmount);
        vm.stopPrank();
    }

    function testCanMintDsc() external collateralDeposited {
        vm.startPrank(USER);
        engine.mintDsc(MINT_AMOUNT);

        assertEq(MINT_AMOUNT, dsc.balanceOf(USER));
    }

    ///////////////////////// ///////////////////
    // depositCollateralAndMintDsc Tests   //////
    /////////////////////////////////////////////

    function testCanDepositCollateralAndMintDsc() external  {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateralAndMintDsc(wEth, COLLATERAL_AMOUNT, MINT_AMOUNT);

        (uint256 dscMinted, uint256 collateralAmountInUSd) = engine.getAccountInformation(USER);
        uint256 collateralAmount = engine.getTokenAmountFromUsd(wEth, collateralAmountInUSd);

        assertEq(dscMinted, MINT_AMOUNT);
        assertEq(collateralAmount, COLLATERAL_AMOUNT);
    }


    /////////////////////////////////// 
    // redeemCollateral Tests   ///////
    ///////////////////////////////////

    modifier collateralDepositedAndDscMinted(address user) {
        vm.startPrank(user);
        ERC20Mock(wEth).approve(address(engine), COLLATERAL_AMOUNT);
        engine.depositCollateralAndMintDsc(wEth, COLLATERAL_AMOUNT, MINT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testRevertIfRedeemColateralAmountisZero() external collateralDepositedAndDscMinted(USER) {
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        vm.prank(USER);
        engine.redeemCollateral(wEth, 0);
    }

    function testRedeemRevertIfHealthFactorIsBroken() external collateralDepositedAndDscMinted(USER) {
        uint256 redeemAmount = 5 ether;
        uint256 redeemAmountInUsd = engine.getUsdValue(wEth, redeemAmount);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        vm.expectRevert(
            abi.encodeWithSignature(
                "DSCEngine__BreaksHealthFactor(uint256)", 
                engine.calculateHealthFactor(totalDscMinted, collateralValueInUsd - redeemAmountInUsd)
            )
        );

        vm.prank(USER);
        engine.redeemCollateral(wEth, redeemAmount);
    }

    function testRedeemCollateralAndUpdateUserInfo() external collateralDepositedAndDscMinted(USER) {
        uint256 redeemAmount = 1 ether;
        uint256 collateralBeforeRedeem = engine.getCollateralBalanceOfUser(USER, wEth);

        vm.prank(USER);
        engine.redeemCollateral(wEth, redeemAmount);
        uint256 collateralAfterRedeem = engine.getCollateralBalanceOfUser(USER, wEth);

        assertEq(collateralAfterRedeem, collateralBeforeRedeem - redeemAmount);
    }

    function testRedeemCollateralAndEmitLog() external collateralDepositedAndDscMinted(USER) {
        uint256 redeemAmount = 1 ether;

        vm.expectEmit(true, true, true, true);
        emit CollateralRedeemed(wEth, address(engine), USER, redeemAmount);
        vm.prank(USER);
        engine.redeemCollateral(wEth, redeemAmount);
    }

    ////////////////////////// 
    // burnDsc Tests   ///////
    //////////////////////////

    function testRevertIfBurnAmountIsZero() external collateralDepositedAndDscMinted(USER) {
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        vm.prank(USER);
        engine.burnDsc(0);
    }

    function testCanBurnDsc() external collateralDepositedAndDscMinted(USER) {
        uint256 burnAmount = 5000 ether;

        vm.startPrank(USER);
        dsc.approve(address(engine), burnAmount);
        engine.burnDsc(burnAmount);
        vm.stopPrank();

        uint256 dscBalance = dsc.balanceOf(USER);

        assertEq(MINT_AMOUNT - burnAmount, dscBalance);
    }

    ///////////////////////// ///////////////////
    //  redeemCollateralAndBurnDsc Tests   //////
    /////////////////////////////////////////////

    function testRedeemCollateralForDsc() external collateralDepositedAndDscMinted(USER) {
        uint256 reedemAmount = 5 ether;
        uint256 burnAmount = 4000 ether;

        vm.startPrank(USER);
        dsc.approve(address(engine), burnAmount);
        engine.redeemCollateralForDsc(wEth, reedemAmount, burnAmount);
        vm.stopPrank();

        (uint256 dscMinted, uint256 collateralAmountInUSd) = engine.getAccountInformation(USER);
        uint256 collateralAmount = engine.getTokenAmountFromUsd(wEth, collateralAmountInUSd);

        assertEq(dscMinted, MINT_AMOUNT - burnAmount);
        assertEq(collateralAmount, COLLATERAL_AMOUNT - reedemAmount);
    }


    ////////////////////////// 
    // Liquidate Tests   /////
    //////////////////////////

    function testRevertIfLiquidationAmountIsZero() external collateralDepositedAndDscMinted(USER) {
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        vm.prank(USER2);
        engine.liquidate(wEth, USER, 0);
    }

    function testRevertIfDebtorHealthFactorIsOkay() external collateralDepositedAndDscMinted(USER) {
        uint256 debtAmountInUSd = 8000 ether;

        vm.startPrank(USER2);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(wEth, USER, debtAmountInUSd);
        vm.stopPrank();
    }

    function testCanLiquidateDebtor() external collateralDepositedAndDscMinted(USER) {
        uint256 usdAmountInWei = 8000 ether;
        uint256 extraMintAmount = 2000 ether;
        uint256 debtorBalanceBeforeLiquidation = engine.getCollateralBalanceOfUser(USER, wEth);

        vm.prank(USER);
        engine.mintDsc(extraMintAmount);

        vm.startPrank(USER2);
        ERC20Mock(wEth).approve(address(engine), STARTING_BALANCE_USER2);
        engine.depositCollateralAndMintDsc(wEth, STARTING_BALANCE_USER2, MINT_AMOUNT + MINT_AMOUNT);
        console.log(engine.getDscMintedAmount(USER2), engine.getAccountCollateralValue(USER2));
        console.log(engine.calculateHealthFactor(engine.getDscMintedAmount(USER2), engine.getAccountCollateralValue(USER2)));
        dsc.approve(address(engine), usdAmountInWei);
        engine.liquidate(wEth, USER, usdAmountInWei);
        console.log(engine.getDscMintedAmount(USER2), engine.getAccountCollateralValue(USER2));
        console.log(engine.calculateHealthFactor(engine.getDscMintedAmount(USER2), engine.getAccountCollateralValue(USER2)));
        vm.stopPrank();

        
        uint256 debtorBalanceAfterLiquidation = engine.getCollateralBalanceOfUser(USER, wEth);
        uint256 liquidatorIncentive = engine.getTokenAmountFromUsd(wEth, usdAmountInWei) + (engine.getTokenAmountFromUsd(wEth, usdAmountInWei) * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        assertEq(debtorBalanceBeforeLiquidation - liquidatorIncentive, debtorBalanceAfterLiquidation);
        // add more asserts whenever you can..for now foucs on 85%
    }

    function testRevertIfLiquidatorHealthFactorIsBroken() external collateralDepositedAndDscMinted(USER) collateralDepositedAndDscMinted(USER2) {
        uint256 debtAmountInUSd = 8000 ether;
        uint256 extraMintAmount = 2000 ether;

        vm.startPrank(USER2);
        engine.mintDsc(extraMintAmount);
        dsc.approve(address(engine), debtAmountInUSd);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(wEth, USER, debtAmountInUSd);
        vm.stopPrank();
    }

    function testRevertIfDebtorHealthFactorNotImproved() external collateralDepositedAndDscMinted(USER) collateralDepositedAndDscMinted(USER2) {
        uint256 debtAmountInUSd = 10000 ether;
        uint256 extraMintAmount = 2000 ether;

        vm.prank(USER);
        engine.mintDsc(extraMintAmount);

        vm.startPrank(USER2);
        dsc.approve(address(engine), debtAmountInUSd);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        engine.liquidate(wEth, USER, 1);
        vm.stopPrank();
    }

    ////////////////////////// 
    // Other Tests   /////////
    //////////////////////////

    function testCalculateHealthFactor() external collateralDepositedAndDscMinted(USER) {
        (uint256 dscMinted, uint256 collateralValue) = engine.getAccountInformation(USER);
        uint256 expectedHealthFactor = (((collateralValue * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION) * PRECISION) / dscMinted;
        uint256 actualHealthFactor = engine.getHealthFactor(USER);

        assertEq(actualHealthFactor, expectedHealthFactor);
    }

    function testGetAccountCollateralValue() external collateralDepositedAndDscMinted(USER) {
        uint256 expectedCollateralValue = 20000 ether;
        uint256 actualCollateralValue = engine.getAccountCollateralValue(USER);

        assertEq(expectedCollateralValue, actualCollateralValue);
    }
}