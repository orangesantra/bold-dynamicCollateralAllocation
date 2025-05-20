// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../../src/DynamicCollateralAllocation/DCA_Manual.sol";

contract YieldOracleMock is IYieldOracle {
    mapping(address => uint256) private yields;
    address[] private supportedCollateral;

    function setCollateralYield(address collateralToken, uint256 yield) external {
        yields[collateralToken] = yield;
        
        // Check if collateral is already supported
        bool isSupported = false;
        for (uint i = 0; i < supportedCollateral.length; i++) {
            if (supportedCollateral[i] == collateralToken) {
                isSupported = true;
                break;
            }
        }
        
        // Add to supported collateral if not already supported
        if (!isSupported) {
            supportedCollateral.push(collateralToken);
        }
    }

    function getCollateralYield(address _collateral) external view override returns (uint256) {
        return yields[_collateral];
    }

    function getSupportedCollateral() external view override returns (address[] memory) {
        return supportedCollateral;
    }
}

contract SwapRouterMock is ISwapRouter {
    mapping(address => mapping(address => uint256)) private exchangeRates; // fromToken -> toToken -> rate (in basis points)
    uint256 private constant BASIS_POINTS = 10000;

    function setExchangeRate(address fromToken, address toToken, uint256 rateBPS) external {
        // Rate is in basis points, e.g., 10500 means 1 fromToken = 1.05 toToken
        exchangeRates[fromToken][toToken] = rateBPS;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override returns (uint256[] memory amounts) {
        require(path.length >= 2, "Invalid path");
        require(block.timestamp <= deadline, "Expired deadline");
        
        address fromToken = path[0];
        address toToken = path[path.length - 1];
        
        uint256 rate = exchangeRates[fromToken][toToken];
        require(rate > 0, "Exchange rate not set");
        
        uint256 amountOut = (amountIn * rate) / BASIS_POINTS;
        require(amountOut >= amountOutMin, "Insufficient output amount");
        
        // Mock the token transfers
        IERC20(fromToken).transferFrom(msg.sender, address(this), amountIn);
        IERC20(toToken).transfer(to, amountOut);
        
        // Return amounts
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[amounts.length - 1] = amountOut;
        
        return amounts;
    }
}