// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
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
// view & pure functions

//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author wannabeOreki
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
    ///////////////////
    // Errors
    ///////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TransferFailed();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsBroken(uint256 userHealthFactor);

    ///////////////////
    // Types
    ///////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////
    // State Variables
    ///////////////////
    DecentralizedStableCoin private immutable i_dsc;

    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //This protocol is meant to be 200% over collateralized i.e. one can mint 50$ worth of DSC for 100$ worth of collateral.

    ///@dev {s_collateralTokens} is used to store all types of tokens that can we used as collateral. If we know exactly how many tokens we have, we could make this immutable!
    address[] private s_collateralTokens;
    ///@dev {s_collateralDeposited} denotes the total amount of collateral deposited by a user
    mapping(address user => mapping(address tokenCollateralAddress => uint256 amountCollateral)) private
        s_collateralDeposited;
    ///@dev {s_priceFeeds} is a mapping between collateral tokens and their respective pricefeed addresses
    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    ///@dev {s_DSCMinted} denotes the amount of DSC minted by user
    mapping(address user => uint256 amount) private s_DSCMinted;

    ///////////////////
    // Events
    ///////////////////

    event CollateralDeposited(
        address indexed user, address indexed tokenCollateralAddress, uint256 indexed amountCollateral
    );

    ///////////////////
    // Modifiers
    ///////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(token);
        }
        _;
    }

    ///////////////////
    // Constructor
    ///////////////////

    constructor(address[] memory tokenAddresses, address[] memory pricefeedAddresses, address dscAddress) {
        if (tokenAddresses.length != pricefeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }
        for (uint256 i; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = pricefeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    function depositCollateralAndMintDESC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @notice This function updates the state by adding new/existing entry of a user, who deposits any non-zero amount of allowed collateral
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param amountDscToMint: The amount of DSC which is to be minted.
     * @notice This function mint new DSC token for a user, given that the health factor of the user should not be broken.
     */

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(amountDscToMint, msg.sender);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken(userHealthFactor);
        }
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        private
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 adjustedCollateralValueInUsd = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / 100;
        return ((adjustedCollateralValueInUsd * 1e18) / totalDscMinted);
    }

    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralValueInUsd;
        for (uint256 index; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function _getUsdValue(address token, uint256 amount) internal view returns (uint256) {
        AggregatorV3Interface pricefeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 answer,,,) = pricefeed.staleCheckLatestRoundData();
        //Eg. 1000$ => 1e18 wei
        // X Eth => Xe18 wei == ?? $
        // answer will consists of 8 demical places
        // X ETh in USD = (1000 * 1e10) * X // 1e18
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(answer) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
