//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {StableCoin} from "./StableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Ali Arif
 * @notice The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == 1 dollar peg.
 * Thhis stable has the properties:
 * -Exogenous Collateral
 * -Dollar Pegged
 * - Algoritmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". at no point, should the value of all collateral
 * be <= the $$$ backed value for all DSC.
 *
 * This contract is the core of the DSC System. It handles all the logic for mining and reddeming DSC, as well depositing
 * & withdrawing collateral. This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    //Errors
    error NeedsMoreThanZero();
    error MustBeSameLength();
    error NotAllowedToken();
    error TransferFailed();
    error BreaksHealthFactor(uint256 healthFactor);
    error MintFailed();

    //State Variables
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATED_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private collateralDeposit;
    mapping(address user => uint256 amountDscMinted) private dscMinted;
    address[] private collateralTokens;

    StableCoin private immutable DSC;

    //Events

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    //Modifiers

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (priceFeeds[token] == address(0)) {
            revert NotAllowedToken();
        }
        _;
    }

    //External Functions

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        //USDC Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert MustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            collateralTokens.push(tokenAddresses[i]);
        }

        DSC = StableCoin(dscAddress);
    }

    function depositCollateralAndMintDsc() external {}

    /**
     * @notice follow CEI Pattern
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        collateralDeposit[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) revert TransferFailed();
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    /**
     * @notice follow CEI Pattern
     * @param amountDscToMint The amount of stable coin to mint.
     * @notice They must have more collateral than the minimum threshold.
     */
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        dscMinted[msg.sender] += amountDscToMint;
        //if they minted too much then revert
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = DSC.mint(msg.sender, amountDscToMint);
        if (!minted) revert MintFailed();
    }

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}
    //Internal Functions

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = dscMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1 then they can get liquidated
     */

    function _healthFactor(address user) private view returns (uint256) {
        //1. total DSC minted
        //2. Total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATED_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION / totalDscMinted);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        //1. Check Health Factor (enough collateral?)
        //2. Revert if they don't have good health factor

        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert BreaksHealthFactor(userHealthFactor);
        }
    }

    //External and Public View Functions

    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral token, get the amount deposited and map
        // it to the price to get the USD value.
        for (uint256 i = 0; i < collateralTokens.length; ++i) {
            address token = collateralTokens[i];
            uint256 amount = collateralDeposit[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface _priceFeed = AggregatorV3Interface(priceFeeds[token]);
        (, int256 price,,,) = _priceFeed.latestRoundData();
        //1 ETH = $1000
        //The returned value from Cl will be 1000 * 1e8
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }
}
