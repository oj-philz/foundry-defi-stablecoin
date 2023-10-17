// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";


/*
 * @title DSCEngine
 * @author Patrick Collins
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////////
    // Erros ///////////
    ////////////////////

    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAndPriceFeedAddressesMustBeEqual();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ////////////////////
    // Types ///////////
    ////////////////////

    using OracleLib for AggregatorV3Interface;

    //////////////////////////////
    // State Variables ///////////
    //////////////////////////////

    DecentralizedStableCoin private immutable i_dsc;

    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;

    /// @dev Mapping of token address to price feed address
    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    /// @dev Amount of collateral deposited by user
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;
    /// @dev Amount of DSC minted by user
    mapping(address user => uint256 amount) private s_DSCMinted;
    /// @dev If we know exactly how many tokens we have, we could make this immutable!
    address[] private s_collateralTokens;

    /////////////////////
    // Events ///////////
    /////////////////////

    event CollateralDeposited(
        address indexed user,
        address indexed tokenAddress,
        uint256 indexed collateralAmount
    );
    event CollateralRedeemed(address indexed tokenAddress, address indexed from, address indexed to, uint256 collateralAmount);

    ////////////////////////
    // Modifiers ///////////
    ////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////////////
    // Functions ///////////
    ////////////////////////

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAndPriceFeedAddressesMustBeEqual();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////////////
    // External functions ///////////
    /////////////////////////////////


    /**
     * 
     * @param collateralToken The token to be used as collateral
     * @param collateralAmount the amount of collateral to be deposited
     * @param dscAmount the amount of dsc to be minted
     * @notice This function allows the user to deposit collateral and mint dsc in one transaction
     */
    function depositCollateralAndMintDsc(address collateralToken, uint256 collateralAmount, uint256 dscAmount) external {
        depositCollateral(collateralToken, collateralAmount);
        mintDsc(dscAmount);        
    }

    /**
     * @notice followes CEI
     * @param tokenCollateralAddress the token to deposit as collateral
     * @param tokenCollateralAmount the amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 tokenCollateralAmount
    )
        public
        moreThanZero(tokenCollateralAmount)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += tokenCollateralAmount;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            tokenCollateralAmount
        );

        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            tokenCollateralAmount
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc(address collateralToken, uint256 collateralAmount, uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(collateralToken, collateralAmount);
    }

    function redeemCollateral(address collateralToken, uint256 collateralAmount) 
    public
    moreThanZero(collateralAmount)
    nonReentrant {
        _redeemCollateral(collateralToken, address(this), msg.sender, collateralAmount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) 
    public
    moreThanZero(amount)
     {
        _burnDsc(amount, msg.sender, msg.sender);
        i_dsc.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate(address collatralToken, address user, uint256 usdAmountInWei) external moreThanZero(usdAmountInWei) nonReentrant{
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor > MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        uint256 collateralAmount = getTokenAmountFromUsd(collatralToken, usdAmountInWei);
        uint256 liquidationBonus = (collateralAmount * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralAmount = collateralAmount + liquidationBonus;

        _redeemCollateral(collatralToken,msg.sender, user, totalCollateralAmount);
        _burnDsc(usdAmountInWei, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /////////////////////////////////
    // Private functions ///////////
    /////////////////////////////////

    function _burnDsc(uint256 amount, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amount;
        if (onBehalfOf != dscFrom) {
            s_DSCMinted[dscFrom] -= amount;
        }
        bool success = i_dsc.transferFrom(dscFrom, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    /**
     * @dev This is low-level call to redeem collateral, any function which calls to this function should 
     * implement _revertIfHealthFactorBroken()
     */
    function _redeemCollateral(address collateralToken, address from, address to, uint256 collateralAmount) private {
        s_collateralDeposited[to][collateralToken] -= collateralAmount;
        emit CollateralRedeemed(collateralToken, from, to, collateralAmount);
        bool success = IERC20(collateralToken).transfer(from, collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /////////////////////////////////////////////////////////
    // Private & Internal view and pure functions ///////////
    /////////////////////////////////////////////////////////

    function _getUsdValue(address token, uint256 amount) internal view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        //check health factor (do they hav enough collateral?)
        // revert if they don't
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _getAccountInformation(address user) private view 
    returns (uint256 totalDscMinted, uint256 collateralValueInUSd) {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUSd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) private pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max; 
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /////////////////////////////////////////////////////////
    // External & Public view and pure functions ////////////
    /////////////////////////////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) public view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getTokenAmountFromUsd(address collatralToken, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[collatralToken]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return ((usdAmountInWei) / (uint256(price) * ADDITIONAL_FEED_PRECISION)) * PRECISION;
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i=0; i<s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        } 
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getDscMintedAmount(address user) external view returns (uint256) {
        return s_DSCMinted[user];
    }

}
