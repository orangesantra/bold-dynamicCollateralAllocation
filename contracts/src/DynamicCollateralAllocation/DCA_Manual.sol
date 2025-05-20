// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from ".././Dependencies/Ownable.sol";
import {ReentrancyGuard} from "contracts/lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "contracts/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "contracts/lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Metadata} from "contracts/lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {ITroveNFT} from ".././Interfaces/ITroveNFT.sol";
import {IAddressesRegistry} from ".././Interfaces/IAddressesRegistry.sol";
import {ITroveManager} from ".././Interfaces/ITroveManager.sol";
import {IBorrowerOperations} from ".././Interfaces/IBorrowerOperations.sol";
import {IPriceFeed} from ".././Interfaces/IPriceFeed.sol";
import {IERC20Metadata} from "contracts/lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../Types/LatestTroveData.sol";

/**
 * @title Dynamic Collateral Optimizer
 * @notice Automatically manages and optimizes collateral positions in Bold Protocol
 * @dev Integrates with Bold Protocol to rebalance collateral for optimal yield and safety
 */

// ============ Interfaces ============

// Yield oracle interfaces
/**
 @notice - There is need to create seperate Yield Oracle contract, for showing yield of contract.
 @notice - and that contract will created using existing price oracle or TWAP. The Yield oracle
 contract in DCAMock is using arbitrary value for testing.
*/
interface IYieldOracle {
    function getCollateralYield(address _collateral) external view returns (uint256 yield);
    function getSupportedCollateral() external view returns (address[] memory);
}

/**
 * @notice - To use uniswap V2 or V3.
 * @notice - for testing, skeleton version is used.
 */
interface ISwapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
contract DynamicCollateralOptimizer_Manual is Ownable(msg.sender), ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct OptimizationStrategy {
        uint256 targetLTV;          // Target Loan-to-Value ratio (in bps, e.g. 7000 = 70%)
        uint256 riskTolerance;      // 1-10 scale of risk preference
        bool yieldPrioritized;      // Whether yield is prioritized over stability
        uint256 rebalanceThreshold;   // Minimum benefit required to trigger rebalance (in bps)
        address[] allowedCollaterals; // List of collateral tokens this strategy can use
    }

    struct TroveData {
        address owner;
        uint256 debt;
        uint256 coll;
        uint256 interestRate;
        uint8 status;
        address collateralType;
    }

    struct CollateralAllocation {
        address token;
        uint256 amount;
        uint256 yield;
        uint256 volatilityScore; // Higher = more volatile
    }

    struct SwapOperation {
        address fromToken;
        address toToken;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    uint256 public constant BASIS_POINTS = 10000; // 100% in basis points
    uint256 public constant MIN_REBALANCE_THRESHOLD = 50; // 0.5% minimum threshold
    uint256 public constant SAFETY_MARGIN = 500; // 5% safety margin above MCR
    uint256 public constant MCR = 11000; // 110% Minimum Collateralization Ratio in bps

    uint32 public lastCalled_global; // Last time the optimizer function is called.

    IAddressesRegistry public registry;
    ITroveManager public troveManager;
    IBorrowerOperations public borrowerOperations;
    IPriceFeed public priceFeed;
    IYieldOracle public yieldOracle;
    ISwapRouter public swapRouter;
    ITroveNFT public troveNFT;

    // User strategies and permissions
    mapping(address => OptimizationStrategy) public userStrategies;
    mapping(address => bool) public isUserActive;
    mapping(uint256 => address) public troveToUser;
    mapping(address => uint256[]) public userTroves;

    // Protocol config
    uint256 public protocolFeePercent; // In basis points
    address public feeCollector;
    uint256 public lastRebalanceTimestamp;
    uint256 public minTimeBetweenRebalances;
    
    bool public emergencyShutdown;

    // ============ Events ============
    event StrategyCreated(address indexed user, uint256 targetLTV, uint256 riskTolerance);
    event TroveOptimized(uint256 indexed troveId, address owner, address fromCollateral, address toCollateral, uint256 amount);
    event TroveRegistered(uint256 indexed troveId, address indexed owner);
    event TroveUnregistered(uint256 indexed troveId, address indexed owner);
    event EmergencyShutdown(bool active);
    event ProtocolFeeChanged(uint256 newFee);
    event BatchOptimizationCompleted(uint256 processedCount, uint256 optimizedCount);

    // ============ Constructor ============

    constructor(
        address _registry,
        address _yieldOracle,
        address _swapRouter,
        uint256 _protocolFeePercent,
        address _feeCollector,
        uint256 _minTimeBetweenRebalances
    ) {
        troveNFT = ITroveNFT(IAddressesRegistry(_registry).troveNFT());

        registry = IAddressesRegistry(_registry);
        yieldOracle = IYieldOracle(_yieldOracle);
        swapRouter = ISwapRouter(_swapRouter);
        
        // Initialize Bold Protocol interfaces
        troveManager = ITroveManager(registry.troveManager());
        borrowerOperations = IBorrowerOperations(registry.borrowerOperations());
        priceFeed = IPriceFeed(registry.priceFeed());
        
        // Set protocol parameters
        protocolFeePercent = _protocolFeePercent;
        feeCollector = _feeCollector;
        minTimeBetweenRebalances = _minTimeBetweenRebalances;
    }

    // ============ Modifiers ============

    modifier onlyTroveOwner(uint256 _troveId) {
        require(troveToUser[_troveId] == msg.sender, "DCO: Not trove owner");
        _;
    }

    modifier whenNotShutdown() {
        require(!emergencyShutdown, "DCO: Protocol is in emergency shutdown");
        _;
    }

    modifier validRebalanceTiming() {
        require(
            block.timestamp >= lastRebalanceTimestamp + minTimeBetweenRebalances,
            "DCO: Too soon to rebalance"
        );
        _;
    }    
    
    // ============ User Strategy Management ============

    function getUserAllowedCollaterals(address _user) external view returns (address[] memory) {
        return userStrategies[_user].allowedCollaterals;
    }

    function getUserTroveCount(address _user) external view returns (uint256) {
        return userTroves[_user].length;
    }

    function getTrovetoUser(uint256 _troveId) external view returns (address) {
        return troveToUser[_troveId];
    }
    /**
     * @notice Creates or updates a user's optimization strategy
     * @param _targetLTV Target loan-to-value ratio (in basis points)
     * @param _riskTolerance Risk tolerance on scale of 1-10
     * @param _yieldPrioritized Whether yield is prioritized over stability
     * @param _rebalanceThreshold Minimum benefit to trigger rebalance (in bps)
     * @param _allowedCollaterals Array of allowed collateral token addresses
     */
    function setUserStrategy(
        uint256 _targetLTV,
        uint256 _riskTolerance,
        bool _yieldPrioritized,
        uint256 _rebalanceThreshold,
        address[] calldata _allowedCollaterals
    ) external {
        require(_targetLTV <= 9000, "DCO: LTV too high"); // Max 90% LTV
        require(_targetLTV >= 5000, "DCO: LTV too low");  // Min 50% LTV
        require(_riskTolerance >= 1 && _riskTolerance <= 10, "DCO: Invalid risk tolerance");
        require(_rebalanceThreshold >= MIN_REBALANCE_THRESHOLD, "DCO: Threshold too low");
        require(_allowedCollaterals.length > 0, "DCO: No collaterals specified");
        
        // Verify all collaterals are supported
        for (uint i = 0; i < _allowedCollaterals.length; i++) {
            require(_isCollateralSupported(_allowedCollaterals[i]), "DCO: Unsupported collateral");
        }
        
        userStrategies[msg.sender] = OptimizationStrategy({
            targetLTV: _targetLTV,
            riskTolerance: _riskTolerance,
            yieldPrioritized: _yieldPrioritized,
            rebalanceThreshold: _rebalanceThreshold,
            allowedCollaterals: _allowedCollaterals
        });
        
        isUserActive[msg.sender] = true;
        
        emit StrategyCreated(msg.sender, _targetLTV, _riskTolerance);
    }    
    
    /**
     * @notice Register a trove to be managed by the optimizer
     * @param _troveId The ID of the trove to register
     */
    function registerTrove(uint256 _troveId) external {
        require(isUserActive[msg.sender], "DCO: No active strategy");
        
        // Verify trove ownership
        address owner1 = troveNFT.ownerOf(_troveId);
        ITroveManager.Status status = troveManager.getTroveStatus(_troveId);
        require(owner1 == msg.sender, "DCO: Not trove owner");
        require(status == ITroveManager.Status.active, "DCO: Trove not active");
        
        troveToUser[_troveId] = msg.sender;
        userTroves[msg.sender].push(_troveId);
        
        emit TroveRegistered(_troveId, msg.sender);
    }

    /**
     * @notice Unregister a trove from the optimizer
     * @param _troveId The ID of the trove to unregister
     */
    function unregisterTrove(uint256 _troveId) external onlyTroveOwner(_troveId) {
        delete troveToUser[_troveId];
        
        // Remove trove from user's array
        uint256[] storage troves = userTroves[msg.sender];
        for (uint256 i = 0; i < troves.length; i++) {
            if (troves[i] == _troveId) {
                troves[i] = troves[troves.length - 1];
                troves.pop();
                break;
            }
        }
        
        emit TroveUnregistered(_troveId, msg.sender);
    }

    // ============ Optimization Core Functions ============

    /**
     * @notice Optimizes a single trove's collateral composition
     * @param _troveId The ID of the trove to optimize
     */
    function optimizeCollateral(uint256 _troveId) 
        public 
        whenNotShutdown
        validRebalanceTiming
        nonReentrant 
    {

        lastCalled_global = uint32(block.timestamp);
        address user = troveToUser[_troveId];
        require(user != address(0), "DCO: Trove not registered");
        
        OptimizationStrategy storage strategy = userStrategies[user];
        
        // Get current trove data
        TroveData memory trove = _getTroveData(_troveId);
        
        // Get current collateral price
        (uint256 currentPrice, ) = priceFeed.fetchPrice();
        
        // Calculate current ICR and check if it's safe
        uint256 currentICR = troveManager.getCurrentICR(_troveId, currentPrice);

        // @notice - The purpose of this line is to prevent optimization within 10% of liquidation threshold.
        // This is a safety measure to ensure that user don't missure this function to avoid
        // liquidation.
        require(currentICR >= MCR * 110 / 100, "DCO: Too close to liquidation threshold");
        
        CollateralAllocation memory optimalCollateral = _findOptimalCollateral(
            trove,
            strategy,
            currentPrice,
            currentICR
        );
        
        // Check if rebalancing is beneficial
        if (_isRebalanceWorthwhile(trove, optimalCollateral, strategy.rebalanceThreshold)) {
            // Execute the rebalancing
            _executeCollateralSwap(_troveId, trove, optimalCollateral);
            
            lastRebalanceTimestamp = block.timestamp;
        }
    }
      /**
     * @notice Batch optimizes multiple troves for gas efficiency
     * @param _troveIds Array of trove IDs to optimize
     * @return processedCount Number of troves processed
     * @return optimizedCount Number of troves successfully optimized
     */
    function batchOptimizeTroves(uint256[] calldata _troveIds) 
            public
            whenNotShutdown
            validRebalanceTiming
            nonReentrant
            returns (uint256 processedCount, uint256 optimizedCount)
        {
            require(_troveIds.length > 0, "DCO: Empty troves array");
            
            (uint256 currentPrice, ) = priceFeed.fetchPrice();
            
            for (uint256 i = 0; i < _troveIds.length; i++) {
                uint256 troveId = _troveIds[i];
                address user = troveToUser[troveId];
                
                if (user == address(0)) continue;
                
                // Skip if no active strategy
                if (!isUserActive[user]) continue;
                
                processedCount++;
                
                TroveData memory trove;
                try this._getTroveData(troveId) returns (TroveData memory _trove) {
                    trove = _trove;
                } catch {
                    continue;
                }
                
                if (trove.status != uint8(ITroveManager.Status.active)) continue;
                
                uint256 currentICR;
                try troveManager.getCurrentICR(troveId, currentPrice) returns (uint256 _icr) {
                    currentICR = _icr;
                    if (currentICR < MCR) continue;
                } catch {
                    continue;
                }
                
                OptimizationStrategy storage strategy = userStrategies[user];
                CollateralAllocation memory optimalCollateral = _findOptimalCollateral(
                    trove,
                    strategy,
                    currentPrice,
                    currentICR
                );
                
                if (_isRebalanceWorthwhile(trove, optimalCollateral, strategy.rebalanceThreshold)) {
                    try this._executeCollateralSwap(troveId, trove, optimalCollateral) {
                        optimizedCount++;
                    } catch {
                        continue;
                    }
                }
            }
            
            if (processedCount > 0) {
                lastRebalanceTimestamp = block.timestamp;
                lastCalled_global = uint32(block.timestamp);
            }
            
            emit BatchOptimizationCompleted(processedCount, optimizedCount);
            return (processedCount, optimizedCount);
    }

    // ============ Internal Functions ============      
    /**
     * @dev Gets trove data in a structured format
     * @param _troveId The trove ID
     * @return TroveData struct with trove information
     */
    function _getTroveData(uint256 _troveId) public view returns (TroveData memory) {
        // Get latest trove data from TroveManager
        LatestTroveData memory latestData = troveManager.getLatestTroveData(_troveId);
        // ITroveManager.LatestTroveData memory latestData = troveManager.getLatestTroveData(_troveId);
        
        // Get trove status
        ITroveManager.Status status = troveManager.getTroveStatus(_troveId);
        
        // Get trove owner from NFT
        address owner1 = troveNFT.ownerOf(_troveId);
        
        // Get collateral type
        address collateralType = address(registry.collToken());
        
        return TroveData({
            owner: owner1,
            debt: latestData.entireDebt,
            coll: latestData.entireColl,
            interestRate: latestData.annualInterestRate,
            status: uint8(status),
            collateralType: collateralType
        });
    }    /**
     * @dev Finds the optimal collateral type based on user strategy
     * @param _trove Current trove data
     * @param _strategy User's optimization strategy
     * @param _price Current collateral price from the price feed
     * @param _currentICR Current Individual Collateralization Ratio of the trove
     * @return The optimal collateral allocation
     */
    function _findOptimalCollateral(
        TroveData memory _trove,
        OptimizationStrategy storage _strategy,
        uint256 _price,
        uint256 _currentICR
    ) internal view returns (CollateralAllocation memory) {
        // Enhanced validation with descriptive error messages
        require(_price > 0, "DCO: Invalid price provided");
        require(_currentICR >= MCR, "DCO: ICR below minimum required ratio");
        require(_trove.coll > 0, "DCO: Trove has no collateral");
        require(_trove.debt > 0, "DCO: Trove has no debt");
        
        address[] memory allowedCollaterals = _strategy.allowedCollaterals;
        require(allowedCollaterals.length > 0, "DCO: No allowed collaterals configured");
        
        // Calculate current USD value of collateral using provided price
        uint256 currentCollateralValueUSD = (_trove.coll * _price) / 1e18;
        
        // Calculate target ICR based on strategy with safety considerations
        // If user has a target LTV, convert it to ICR and add safety margin
        // Otherwise use their current ICR as the target
        uint256 targetICR;
        if (_strategy.targetLTV > 0) {
            // Convert LTV to ICR: ICR = 100% / LTV
            targetICR = (BASIS_POINTS * BASIS_POINTS / _strategy.targetLTV) + SAFETY_MARGIN;
            
            // Ensure target ICR is at least as high as current ICR if current is safe
            if (_currentICR > targetICR && _currentICR >= MCR + 1000) { // 10% above MCR
                // Prefer maintaining the user's current higher safety level
                targetICR = _currentICR;
            }
        } else {
            // Default to current ICR with a small safety buffer
            targetICR = _currentICR + 200; // Add 2% safety buffer
        }
            
        // Initialize with current collateral data
        uint256 currentVolatility = _getCollateralVolatility(_trove.collateralType);
        uint256 currentYield = yieldOracle.getCollateralYield(_trove.collateralType);
        
        CollateralAllocation memory bestAllocation = CollateralAllocation({
            token: _trove.collateralType,
            amount: _trove.coll,
            yield: currentYield,
            volatilityScore: currentVolatility
        });
        
        // Score the current allocation as baseline
        uint256 highestScore = 0;
        uint256 currentScore = _calculateCollateralScore(
            currentYield,
            currentVolatility,
            _strategy.riskTolerance,
            _strategy.yieldPrioritized,
            _currentICR,  // Use actual current ICR for more accurate comparison
            targetICR
        );
        
        // Use current as baseline if valid
        if (currentScore > 0) {
            highestScore = currentScore;
        }
        
        // Evaluate each allowed collateral
        for (uint256 i = 0; i < allowedCollaterals.length; i++) {
            address collateralToken = allowedCollaterals[i];
            
            // Skiping current collateral
            if (collateralToken == _trove.collateralType) continue;
            
            // Get token price and checking it's validity
            try this._evaluateCollateral(
                collateralToken,
                currentCollateralValueUSD,
                _strategy,
                _trove.debt,
                targetICR,
                _price  // Pass the price to avoid additional price feed calls
            ) returns (CollateralAllocation memory candidate, uint256 score) {
                if (score > highestScore) {
                    highestScore = score;
                    bestAllocation = candidate;
                }
            } catch (bytes memory reason) {
                // TODO: better error handling.
                continue;
            }
        }
        
        return bestAllocation;
    }
      /**
     * @dev Helper function to evaluate a potential collateral token
     * @param _collateralToken The collateral token to evaluate
     * @param _collateralValueUSD The USD value of the current collateral
     * @param _strategy The user's optimization strategy
     * @param _debt The current debt amount
     * @param _targetICR The target ICR to maintain
     * @param _price The current price from price feed
     * @return candidate The collateral allocation for this token
     * @return score The score for this collateral
     */
    function _evaluateCollateral(
        address _collateralToken,
        uint256 _collateralValueUSD,
        OptimizationStrategy memory _strategy,
        uint256 _debt,
        uint256 _targetICR,
        uint256 _price
    ) public view returns (CollateralAllocation memory candidate, uint256 score) {
        // Input validation
        require(_collateralToken != address(0), "DCO: Invalid collateral token");
        require(_collateralValueUSD > 0, "DCO: Invalid collateral value");
        require(_debt > 0, "DCO: Invalid debt value");
        require(_targetICR >= MCR, "DCO: Target ICR below minimum");
        require(_price > 0, "DCO: Invalid price");
        
        // Get collateral metadata and current market data
        uint256 yield = yieldOracle.getCollateralYield(_collateralToken);
        uint256 volatilityScore = _getCollateralVolatility(_collateralToken);
        
        // Apply a token-specific price adjustment based on volatility
        // More volatile tokens get a conservative price discount for safety
        uint256 tokenPrice;
        if (_collateralToken == address(registry.collToken())) {
            // If this is the main collateral token priced by the price feed
            tokenPrice = _price;
        } else {
            tokenPrice = priceFeed.lastGoodPrice();
            require(tokenPrice > 0, "DCO: Invalid token price");
            
            // Apply a conservative discount based on volatility
            uint256 discountFactor = BASIS_POINTS - (volatilityScore * 100);
            tokenPrice = (tokenPrice * discountFactor) / BASIS_POINTS;
        }
        
        // Get token decimals for proper conversion
        uint8 decimals = IERC20Metadata(_collateralToken).decimals();
        
        // Calculate equivalent amount preserving the same USD value
        // The calculation needs to account for token decimals
        uint256 equivalentAmount = (_collateralValueUSD * (10 ** decimals)) / tokenPrice;
        
        // Calculate the new ICR that would result from this allocation
        // This takes into account the token's volatility and price
        uint256 newValue = (equivalentAmount * tokenPrice) / (10 ** decimals);
        uint256 newICR = (newValue * 1e18) / _debt;
        
        // If ICR would be below target, adjust amount to meet target
        if (newICR < _targetICR) {
            // Recalculate the required amount to achieve target ICR
            // This formula derives from: ICR = (collateralValue * 1e18) / debt
            // So: collateralValue = (debt * ICR) / 1e18
            uint256 requiredValue = (_debt * _targetICR) / 1e18;
            equivalentAmount = (requiredValue * (10 ** decimals)) / tokenPrice;
            
            // Update the newICR to reflect this adjustment
            newICR = _targetICR;
        }
        
        // Create the candidate allocation
        candidate = CollateralAllocation({
            token: _collateralToken,
            amount: equivalentAmount,
            yield: yield,
            volatilityScore: volatilityScore
        });
        
        // Calculate score with improved scoring that factors in:
        // 1. Yield potential
        // 2. Volatility risk
        // 3. ICR safety margin
        // 4. User's risk tolerance and strategy
        score = _calculateCollateralScore(
            yield,
            volatilityScore,
            _strategy.riskTolerance,
            _strategy.yieldPrioritized,
            newICR,
            _targetICR
        );
        
        return (candidate, score);
    }
      /**
     * @dev Gets volatility score for a collateral token
     * @param _collateralToken The collateral token address
     * @return Volatility score (1-10)
     */
     // NOTE - The addresses may mismatch. 
    function _getCollateralVolatility(address _collateralToken) public view returns (uint256) {
        // TODO: In mainnet deployment EMA price is need to be implemented to calculate volatility.

        // Base collateral types (ETH, WETH, etc.)
        if (_collateralToken == address(registry.collToken())) {
            return 3; // Moderate volatility for ETH/WETH
        }
        
        // Liquid Staking Tokens (LSTs)     
        // rETH (Rocket Pool ETH)
        if (_collateralToken == address(0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0) || 
            // rETH address in production
            _collateralToken == address(0xae78736Cd615f374D3085123A210448E74Fc6393)) {
            return 2; // Lower volatility for rETH due to stability mechanisms
        }
        
        // wstETH (Wrapped staked ETH from Lido)
        if (_collateralToken == address(0x5e74C9036fb86BD7eCdcb084a0673EFc32eA31cb) ||
            // This is a placeholder address - use actual wstETH address in production
            _collateralToken == address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0)) {
            return 2; // Lower volatility for wstETH
        }
        // ----------------------------------------------------------------------
        /**
        NOTE: As below tokens aren't supported in BOLD, it's only for future reference.
         */
        // cbETH (Coinbase ETH)
        if (_collateralToken == address(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704)) {
            return 3; // Moderate volatility for cbETH
        }
        
        // sfrxETH (Staked Frax ETH)
        if (_collateralToken == address(0xac3E018457B222d93114458476f3E3416Abbe38F)) {
            return 3; // Moderate volatility
        }
        
        // stETH (Lido Staked ETH)
        if (_collateralToken == address(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84)) {
            return 3; // Moderate volatility for stETH
        }
        
        // Default for unknown tokens - conservative high volatility assumption
        return 7; // Assume high volatility for unrecognized tokens
    }
      /**
     * @dev Calculates collateral score based on yield, volatility, and user preferences
     * @param _yield Yield of the collateral
     * @param _volatilityScore Volatility score (1-10)
     * @param _riskTolerance User's risk tolerance (1-10)
     * @param _yieldPrioritized Whether yield is prioritized over stability
     * @param _currentICR Current ICR of the potential allocation
     * @param _targetICR Target ICR based on user's strategy
     * @return Calculated score for the collateral
     */
    function _calculateCollateralScore(
        uint256 _yield,
        uint256 _volatilityScore,
        uint256 _riskTolerance,
        bool _yieldPrioritized,
        uint256 _currentICR,
        uint256 _targetICR
    ) public pure returns (uint256) {
        // Input validation
        if (_yield == 0 || _volatilityScore == 0 || _currentICR == 0 || _targetICR == 0) {
            return 0; // Invalid parameters
        }
        
        // Normalize risk tolerance to 1-10 range
        uint256 riskFactor = _riskTolerance > 10 ? 10 : (_riskTolerance < 1 ? 1 : _riskTolerance);
        
        // Calculate base score that balances yield and volatility
        uint256 baseScore;
        
        if (_yieldPrioritized) {
            // Yield-prioritized scoring: yield is weighted by risk tolerance
            // Higher risk tolerance = more weight to yield vs volatility
            baseScore = _yield * riskFactor / (11 - riskFactor + _volatilityScore);
        } else {
            // Safety-prioritized scoring: yield is inversely weighted by risk tolerance
            // Lower risk tolerance = more penalty for volatility
            baseScore = _yield * (11 - riskFactor) / (riskFactor + _volatilityScore);
        }
        
        // Apply ICR adjustments - higher ICR is better for safety
        
        // ICR Bonus calculation:
        // 1. If ICR is above target, add a bonus (up to 20%)
        if (_currentICR > _targetICR) {
            // Calculate bonus proportional to how much ICR exceeds target
            uint256 icrExcessPercent = ((_currentICR - _targetICR) * 100) / _targetICR;
            
            // Cap the bonus at 20% (2000 basis points)
            uint256 icrBonus = (icrExcessPercent * 20) * BASIS_POINTS / 100;
            icrBonus = icrBonus > 2000 ? 2000 : icrBonus;
            
            // Apply the bonus
            baseScore = baseScore * (BASIS_POINTS + icrBonus) / BASIS_POINTS;
        } 
        // 2. If ICR is below target but above MCR, apply a penalty
        else if (_currentICR < _targetICR && _currentICR >= MCR) {
            // Calculate penalty proportional to ICR shortfall
            uint256 icrDeficitPercent = ((_targetICR - _currentICR) * 100) / _targetICR;
            
            // Higher penalty for being close to MCR
            uint256 icrPenalty = (icrDeficitPercent * 30) * BASIS_POINTS / 100;
            icrPenalty = icrPenalty > 3000 ? 3000 : icrPenalty;
            
            // Apply the penalty
            baseScore = baseScore * (BASIS_POINTS - icrPenalty) / BASIS_POINTS;
        }
        // 3. If ICR is below MCR, score is 0 (invalid option)
        else if (_currentICR < MCR) {
            return 0;
        }
        
        // Apply a final adjustment based on how close the ICR is to the minimum
        // This creates a strong preference for safer positions as they approach MCR
        uint256 safetyMargin = _currentICR > MCR ? (_currentICR - MCR) : 0;
        if (safetyMargin < 1000) { // Within 10% of MCR
            // Apply significant penalty when close to MCR
            uint256 mcrProximityPenalty = (1000 - safetyMargin) / 10; // 0-10% penalty
            baseScore = baseScore * (BASIS_POINTS - mcrProximityPenalty) / BASIS_POINTS;
        }
        
        return baseScore;
    }    /**
     * @dev Executes collateral swap by withdrawing and depositing
     * @param _troveId Trove ID to modify
     * @param _currentTrove Current trove data
     * @param _newCollateral New collateral allocation
     */
    function _executeCollateralSwap(
        uint256 _troveId,
        TroveData memory _currentTrove,
        CollateralAllocation memory _newCollateral
    ) public nonReentrant whenNotShutdown {
        // Input validation
        require(_troveId > 0, "DCO: Invalid trove ID");
        require(_currentTrove.owner != address(0), "DCO: Invalid trove owner");
        require(_currentTrove.coll > 0, "DCO: No collateral to swap");
        require(_newCollateral.token != address(0), "DCO: Invalid new collateral token");
        require(_newCollateral.amount > 0, "DCO: Invalid new collateral amount");
        
        // Verify trove is owned by the appropriate user
        address troveOwner = troveToUser[_troveId];
        require(troveOwner != address(0), "DCO: Trove not registered");
        require(_currentTrove.owner == troveOwner, "DCO: Trove owner mismatch");
        
        // Get current price to calculate appropriate slippage parameters
        (uint256 currentPrice, bool priceSuccess) = priceFeed.fetchPrice();
        if (!priceSuccess || currentPrice == 0) {
            currentPrice = priceFeed.lastGoodPrice();
            require(currentPrice > 0, "DCO: Invalid price");
        }
        
        // Calculate optimal slippage based on volatility
        uint256 fromVolatility = _getCollateralVolatility(_currentTrove.collateralType);
        uint256 toVolatility = _getCollateralVolatility(_newCollateral.token);
        // More volatile pairs = higher slippage allowance needed
        uint256 baseSlippage = 50; // 0.5% base slippage
        uint256 volatilitySlippage = ((fromVolatility + toVolatility) * 10) / 2; // Avg volatility * 10 bps
        uint256 slippageBps = baseSlippage + volatilitySlippage;
        
        // Cap maximum slippage
        if (slippageBps > 300) { // Cap at 3%
            slippageBps = 300;
        }
        
        // Create swap operation with proper slippage calculation
        SwapOperation memory swap = SwapOperation({
            fromToken: _currentTrove.collateralType,
            toToken: _newCollateral.token,
            amountIn: _currentTrove.coll,
            minAmountOut: _calculateMinAmountOut(
                _currentTrove.coll,
                _currentTrove.collateralType,
                _newCollateral.token,
                slippageBps
            )
        });
        
        // Execute the swap
        uint256 newCollAmount = _executeSwap(swap);
        
        // Verify swap result meets minimum expectations
        require(newCollAmount > 0, "DCO: Swap returned zero tokens");
        
        // TODO: integrate with BOLD protocol.
        // In mainnet deployment, this would interact with Bold protocol to:
        // 1. Close the existing trove or adjust its collateral
        // 2. Ensure the debt remains unchanged
        
        // For demonstration purposes, just emitting an event
        emit TroveOptimized(
            _troveId,
            _currentTrove.owner,
            _currentTrove.collateralType,
            _newCollateral.token,
            newCollAmount
        );
    }

    /**
     * @dev Execute an actual token swap using a DEX/ will use uinswap v2 initially.
     * @param _swap The swap operation details
     * @return The amount of tokens received
     */
    function _executeSwap(SwapOperation memory _swap) internal returns (uint256) {
        // Approve the router to spend tokens
        IERC20(_swap.fromToken).approve(address(swapRouter), _swap.amountIn);
        
        // Create the swap path
        address[] memory path = new address[](2);
        path[0] = _swap.fromToken;
        path[1] = _swap.toToken;
        
        // Execute the swap
        uint256[] memory amounts = swapRouter.swapExactTokensForTokens(
            _swap.amountIn,
            _swap.minAmountOut,
            path,
            address(this),
            block.timestamp + 300 // 5 minute deadline
        );
        
        // Return the amount of tokens received
        return amounts[amounts.length - 1];
    }    
    
    /**
     * @dev Calculate minimum output amount for a swap with slippage tolerance
     * @param _amountIn Input amount
     * @param _tokenIn Input token
     * @param _tokenOut Output token
     * @param _slippageBps Slippage in basis points (e.g. 50 = 0.5%)
     */
    function _calculateMinAmountOut(
        uint256 _amountIn,
        address _tokenIn,
        address _tokenOut,
        uint256 _slippageBps
    ) public returns (uint256) {
        // Input validation
        require(_amountIn > 0, "DCO: Amount in must be positive");
        require(_tokenIn != address(0) && _tokenOut != address(0), "DCO: Invalid token addresses");
        require(_slippageBps <= 1000, "DCO: Slippage too high"); // Max 10%

        // Get current price from price feed with fallback to last good price
        uint256 currentPrice;
        bool success;
        (currentPrice, success) = priceFeed.fetchPrice();
        if (!success || currentPrice == 0) {
            currentPrice = priceFeed.lastGoodPrice();
            require(currentPrice > 0, "DCO: Unable to get valid price");
        }
        // TODO: - need to optimize price fetching.
        IPriceFeed tokenInPriceFeed;
        IPriceFeed tokenOutPriceFeed;
        
        // Use the main priceFeed for all tokens instead of trying to get token-specific feeds
        
        // Initialize prices (will be properly set below)
        uint256 priceIn;
        uint256 priceOut;
        
        // Apply safety checks to detect potential oracle manipulation
        if (_tokenIn == address(registry.collToken())) {
            priceIn = currentPrice;
        } else {
            // TODO: - implemenation of multiple price feeds.
            uint256 volatilityIn = _getCollateralVolatility(_tokenIn);
            uint256 discountFactorIn = BASIS_POINTS - (volatilityIn * 50); // 0.5% per volatility point
            priceIn = (currentPrice * discountFactorIn) / BASIS_POINTS;
        }
        
        if (_tokenOut == address(registry.collToken())) {
            priceOut = currentPrice;
        } else {
            // Same for output token
            uint256 volatilityOut = _getCollateralVolatility(_tokenOut);
            // More conservative with output token to ensure minimum amount
            uint256 discountFactorOut = BASIS_POINTS - (volatilityOut * 100); // 1% per volatility point
            priceOut = (currentPrice * discountFactorOut) / BASIS_POINTS;
        }
        
        require(priceIn > 0 && priceOut > 0, "DCO: Invalid token prices");

        // Get decimals for both tokens
        uint8 decimalsIn = IERC20Metadata(_tokenIn).decimals();
        uint8 decimalsOut = IERC20Metadata(_tokenOut).decimals();

        // Calculate USD value of input amount
        uint256 amountInUSD = (_amountIn * priceIn) / (10 ** decimalsIn);
        
        // Calculate equivalent output amount in the output token
        uint256 amountOut = (amountInUSD * (10 ** decimalsOut)) / priceOut;

        // Apply slippage tolerance to get minimum output amount
        uint256 minAmountOut = (amountOut * (BASIS_POINTS - _slippageBps)) / BASIS_POINTS;
        
        // Safety check to ensure we don't get 0 back due to rounding
        require(minAmountOut > 0, "DCO: Calculated minimum output is zero");
        
        return minAmountOut;
    }

    /**
     * @dev Checks if a collateral token is supported by the protocol
     * @param _collateral The collateral token address to check
     */
    function _isCollateralSupported(address _collateral) internal view returns (bool) {
        address[] memory supportedCollaterals = yieldOracle.getSupportedCollateral();
        
        for (uint256 i = 0; i < supportedCollaterals.length; i++) {
            if (supportedCollaterals[i] == _collateral) {
                return true;
            }
        }
        
        return false;
    }    
    
    /**
     * @dev Checks if rebalancing is worthwhile based on yield improvement and gas costs
     * @param _currentTrove Current trove data
     * @param _newCollateral New optimal collateral allocation
     * @param _threshold Minimum benefit threshold in basis points
     * @return Whether rebalancing is beneficial
     */
    function _isRebalanceWorthwhile(
        TroveData memory _currentTrove,
        CollateralAllocation memory _newCollateral,
        uint256 _threshold
    ) public view returns (bool) {
        // Input validation
        require(_threshold > 0, "DCO: Invalid threshold");
        
        // If token is the same, no rebalancing needed
        if (_currentTrove.collateralType == _newCollateral.token) {
            return false;
        }
        
        // Calculate current yield and new yield
        uint256 currentYield = yieldOracle.getCollateralYield(_currentTrove.collateralType);
        uint256 newYield = _newCollateral.yield;
        
        // If new yield is lower or equal, not worth rebalancing for yield
        if (newYield <= currentYield) {
            return false;
        }
        
        // Calculate yield improvement in basis points
        uint256 improvementBps = ((newYield - currentYield) * BASIS_POINTS) / currentYield;
        
        // Get volatility scores
        uint256 currentVolatility = _getCollateralVolatility(_currentTrove.collateralType);
        uint256 newVolatility = _newCollateral.volatilityScore;
        
        // Factor in gas costs - minimum threshold to overcome transaction costs
        // This sets a base level of improvement needed to justify the gas expenditure
        uint256 minGasCostThreshold = 20; // 0.2% minimum to overcome gas costs
        if (improvementBps < minGasCostThreshold) {
            return false;
        }
        
        // Calculate adaptive threshold based on volatility changes
        uint256 adaptiveThreshold = _threshold;
        
        // If new collateral is more volatile than current, require higher yield improvement
        if (newVolatility > currentVolatility) {
            // Calculate volatility difference
            uint256 volatilityIncrease = newVolatility - currentVolatility;
            
            // Progressively increase threshold based on volatility increase
            // More volatile = need more yield benefit to justify the risk
            if (volatilityIncrease == 1) {
                // Small volatility increase: +25% on threshold
                adaptiveThreshold += _threshold / 4;
            } 
            else if (volatilityIncrease == 2) {
                // Medium volatility increase: +50% on threshold
                adaptiveThreshold += _threshold / 2;
            }
            else if (volatilityIncrease >= 3) {
                // Large volatility increase: +100% on threshold per point of difference
                adaptiveThreshold += _threshold * volatilityIncrease / 2;
            }
            
            // Cap the maximum threshold to prevent unreasonable requirements
            uint256 maxThreshold = 1000; // 10% maximum threshold
            if (adaptiveThreshold > maxThreshold) {
                adaptiveThreshold = maxThreshold;
            }
        }
        // If new collateral is less volatile, this can be more lenient with the threshold
        else if (newVolatility < currentVolatility) {
            // Calculate volatility improvement
            uint256 volatilityDecrease = currentVolatility - newVolatility;
            
            // Reduce threshold based on volatility decrease
            // Less volatile = accept lower yield benefit due to safety improvement
            uint256 reductionFactor = volatilityDecrease * 10; // 10% reduction per point
            
            // Ensureing to don't reduce below the gas cost threshold
            if (reductionFactor > 50) {
                reductionFactor = 50; // Cap at 50% reduction
            }
            
            adaptiveThreshold = adaptiveThreshold * (100 - reductionFactor) / 100;
            
            // Ensure threshold doesn't go below minimum gas cost
            if (adaptiveThreshold < minGasCostThreshold) {
                adaptiveThreshold = minGasCostThreshold;
            }
        }
        
        // Return true if improvement exceeds adaptive threshold
        return improvementBps >= adaptiveThreshold;
    }

    // ============ Admin Functions ============

    /**
     * @notice Updates the protocol fee percentage
     * @param _newFeePercent New fee percent in basis points
     */
    function setProtocolFee(uint256 _newFeePercent) external onlyOwner {
        require(_newFeePercent <= 1000, "DCO: Fee too high"); // Max 10%
        protocolFeePercent = _newFeePercent;
        emit ProtocolFeeChanged(_newFeePercent);
    }

    /**
     * @notice Updates the fee collector address
     * @param _newFeeCollector New fee collector address
     */
    function setFeeCollector(address _newFeeCollector) external onlyOwner {
        require(_newFeeCollector != address(0), "DCO: Invalid address");
        feeCollector = _newFeeCollector;
    }
    
    /**
     * @notice Updates the minimum time between rebalances
     * @param _newMinTime New minimum time in seconds
     */
    function setMinTimeBetweenRebalances(uint256 _newMinTime) external onlyOwner {
        minTimeBetweenRebalances = _newMinTime;
    }

    /**
     * @notice Emergency shutdown of the contract
     * @param _shutdown Whether to activate emergency shutdown
     */
    function setEmergencyShutdown(bool _shutdown) external onlyOwner {
        emergencyShutdown = _shutdown;
        emit EmergencyShutdown(_shutdown);
    }

    /**
     * @notice Update yield oracle address
     * @param _newYieldOracle New yield oracle address
     */
    function setYieldOracle(address _newYieldOracle) external onlyOwner {
        require(_newYieldOracle != address(0), "DCO: Invalid address");
        yieldOracle = IYieldOracle(_newYieldOracle);
    }

    /**
     * @notice Update swap router address
     * @param _newSwapRouter New swap router address
     */
    function setSwapRouter(address _newSwapRouter) external onlyOwner {
        require(_newSwapRouter != address(0), "DCO: Invalid address");
        swapRouter = ISwapRouter(_newSwapRouter);
    }
    
    /**
     * @notice Updates the Bold Protocol registry address and refreshes interfaces
     * @param _newRegistry New registry address
     */
    function updateRegistry(address _newRegistry) external onlyOwner {
        require(_newRegistry != address(0), "DCO: Invalid address");
        registry = IAddressesRegistry(_newRegistry);
        
        // Update interface pointers
        troveManager = ITroveManager(registry.troveManager());
        borrowerOperations = IBorrowerOperations(registry.borrowerOperations());
        priceFeed = IPriceFeed(registry.priceFeed());
    }
}