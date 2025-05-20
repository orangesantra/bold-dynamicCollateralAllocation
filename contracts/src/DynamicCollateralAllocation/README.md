# Motivation

As a security reseacher, during the code review of liquity/bold (Cantina Contest). I have gone through in and out of BOLD protocol. Having this knowledge created this contract for a new feature addition.

# New Files

src/
└── DynamicCollateralAllocation/
    ├── DCA_Manual.sol            
    ├── README.md                 
    ├── Tokoon.sol                

test/
├── dynamicCollateralAllocation.t.sol   
└── TestContracts/
    └── DCAMocks.sol              


# Dynamic Collateral Allocation (DCA)

The idea of Dynamic Collateral Allocation contract is to enhance the Bold Protocol that optimizes user collateral positions to maximize yield while maintaining appropriate risk levels. It rebalances user collateral based on predefined strategies, market conditions, and risk preferences.

## Overview

The DCA module enables users to:
- Define custom optimization strategies with specific risk and yield parameters
- Maintain safer positions during volatile market conditions
- Maximize yield on collateral with active management (as it's not automatic yet)

### Core Functionality

1. **Optimization Strategies**
   - Users can create custom strategies with their risk tolerance, yield preferences, and target LTV ratios
   - Strategies define which collateral tokens can be used and minimum thresholds for rebalancing

2. **Trove Management**
   - Users register their troves with the optimizer
   - The system monitors registered troves for optimization opportunities
   - Batch processing enables gas-efficient optimization across multiple positions

3. **Collateral Evaluation**
   - Each potential collateral token is evaluated based on:
     - Current yield potential
     - Price stability and volatility
     - Impact on position's health (ICR)
     - User's specified risk preferences

4. **Rebalancing Logic**
   - Positions are only rebalanced when benefits exceed transaction costs
   - Adaptive thresholds prevent excessive trading during volatile markets
   - Safety mechanisms ensure positions maintain healthy collateralization

### Scoring Algorithm

The DCA module uses a sophisticated scoring algorithm that balances multiple factors:

```
Score = BaseScore * ICR_Adjustment

Where:
- BaseScore factors in yield and volatility based on user's risk tolerance
- ICR_Adjustment rewards positions with higher safety margins and penalizes those close to liquidation
```

#### Yield vs. Volatility Trade-off

For yield-prioritized strategies:
```
BaseScore = Yield * RiskFactor / (11 - RiskFactor + VolatilityScore)
```
11 because RisFactor is between scale of 1 to 10.

For safety-prioritized strategies:
```
BaseScore = Yield * (11 - RiskFactor) / (RiskFactor + VolatilityScore)
```

This creates an intelligent balance where:
- Higher risk users get more aggressive yield optimization
- Lower risk users maintain safer positions with more conservative allocations
- Positions close to minimum collateralization get strong safety adjustments

## Usage Guide

### Setting a Strategy

Users can set their optimization strategy by calling:

```solidity
function setUserStrategy(
    uint256 _targetLTV,
    uint256 _riskTolerance,
    bool _yieldPrioritized,
    uint256 _rebalanceThreshold,
    address[] calldata _allowedCollaterals
) external
```

Parameters:
- `_targetLTV`: Target Loan-to-Value ratio (in basis points, e.g., 7000 = 70%)
- `_riskTolerance`: Risk tolerance on scale of 1-10 (1 = very conservative, 10 = aggressive)
- `_yieldPrioritized`: Whether yield is prioritized over stability
- `_rebalanceThreshold`: Minimum benefit required to trigger rebalance (in basis points)
- `_allowedCollaterals`: List of collateral tokens this strategy can use

### Registering Troves

Once a strategy is set, users can register troves for optimization:

```solidity
function registerTrove(uint256 _troveId) external
```

### Manual Optimization

Users can trigger optimization for specific troves:

```solidity
function optimizeCollateral(uint256 _troveId) public
```

## Example Scenarios

### Scenario 1: Conservative User

```
User strategy:
- targetLTV: 60% (6000 basis points)
- riskTolerance: 3 (conservative)
- yieldPrioritized: false
- rebalanceThreshold: 100 (1%)
- allowedCollaterals: [ETH, rETH, stETH]
```

In this scenario, the system will:
- Maintain a conservative 60% LTV (166% ICR)
- Only rebalance if the yield improvement exceeds 1%
- Apply stricter volatility penalties due to low risk tolerance
- Potentially favor less volatile assets like rETH over higher yielding but more volatile options

### Scenario 2: Yield-Seeking User

```
User strategy:
- targetLTV: 75% (7500 basis points)
- riskTolerance: 8 (aggressive)
- yieldPrioritized: true
- rebalanceThreshold: 50 (0.5%)
- allowedCollaterals: [ETH, rETH, stETH, wstETH, cbETH]
```

In this scenario, the system will:
- Maintain a more aggressive 75% LTV (133% ICR)
- Rebalance more frequently with a lower 0.5% threshold
- Weight yield more heavily in scoring due to high risk tolerance
- Allow a wider range of collateral tokens to find optimal yield

## Under the Hood

### Collateral Scoring

The collateral scoring system evaluates tokens based on:

1. **Base Score**: Initial score based on yield and volatility, weighted by risk preference
2. **ICR Adjustment**: 
   - Bonus of up to 20% for ICRs above target
   - Penalty of up to 30% for ICRs below target
   - Zero score for ICRs below minimum threshold
3. **MCR Proximity Penalty**: Additional penalty for positions close to liquidation threshold

### Rebalance Worthiness

The system determines if rebalancing is worthwhile by:

1. Calculating yield improvement in basis points
2. Applying an adaptive threshold based on:
   - Volatility differences between current and new collateral
   - Gas costs and minimum threshold to overcome transaction expenses
   - Higher thresholds when moving to more volatile assets
   - Lower thresholds when improving position safety

## Security Consideration

The DCA module includes several safety measures:
1. **Liquidation Manipulation**: One of the main concern of `DCA_Manual.sol::
    optimizeCollateral()` is the liquidation manipulation, by calling this function just before liquidation. To figure this out there's a buffer being set.

    ```solidity
    // Calculate current ICR and check if it's safe
        uint256 currentICR = troveManager.getCurrentICR(_troveId, currentPrice);
        require(currentICR >= MCR, "DCO: Trove below MCR");
    ```
1. **Emergency Shutdown**: Admin can pause the system in case of unexpected behavior.
2. **Slippage Protection**: Dynamic slippage calculation based on asset volatility (though need to br optimized further)
4. **Safety Margins**: It maintains buffer above minimum collateralization ratio.

### NOTE - Though security measures have been implemented, but still through security review need to be done (in progress).

## Administrative Functions

Administrators can configure system parameters:

- `setProtocolFee`: Update protocol fee percentage
- `setFeeCollector`: Update fee collector address
- `setMinTimeBetweenRebalances`: Set minimum time between rebalances
- `setEmergencyShutdown`: Enable/disable emergency shutdown
- `setYieldOracle`: Update yield oracle address
- `setSwapRouter`: Update swap router address
- `updateRegistry`: Update Bold Protocol registry address

## DANGER ZONE - Integration with Bold Protocol

The DCA integrates with Bold Protocol's core components:
- **TroveManager**: Queries trove data and status
- **BorrowerOperations (TODO)**: Modifies trove positions
- **PriceFeed**: Gets current collateral prices
- **TroveNFT**: Verifies trove ownership

## Future Development

### This is prototype contract for new feature addition in current protocol, though to further optimize it iteration is going on.

Future enhancements to the DCA module may include:
- Gas-optimized batch operations for multi-collateral positions 
- Machine learning-based yield prediction and risk assessment (Chainlink automation is under consideration, but it may be pretty gas expensive)
- Advanced volatility models for better risk management