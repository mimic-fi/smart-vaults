// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';

import '@mimic-fi/v2-helpers/contracts/math/FixedPoint.sol';
import '@mimic-fi/v2-helpers/contracts/math/UncheckedMath.sol';
import '@mimic-fi/v2-price-oracle/contracts/IPriceOracle.sol';
import '@mimic-fi/v2-swap-connector/contracts/ISwapConnector.sol';
import '@mimic-fi/v2-registry/contracts/implementations/AuthorizedImplementation.sol';
import '@mimic-fi/v2-strategies/contracts/IStrategy.sol';

import './IWallet.sol';
import './IWrappedNativeToken.sol';

contract Wallet is IWallet, AuthorizedImplementation {
    using SafeERC20 for IERC20;
    using FixedPoint for uint256;
    using UncheckedMath for uint256;

    bytes32 public constant override NAMESPACE = keccak256('WALLET');
    address public constant override ETH = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    address public override strategy;
    address public override priceOracle;
    address public override swapConnector;
    uint256 public override investedValue;
    address public override feeCollector;
    uint256 public override withdrawFee;
    uint256 public override performanceFee;
    uint256 public override swapFee;
    address public immutable override wrappedNativeToken;

    constructor(IRegistry registry, address _wrappedNativeToken) AuthorizedImplementation(registry) {
        wrappedNativeToken = _wrappedNativeToken;
    }

    function initialize(address _admin) external initializer {
        _initialize(_admin);
    }

    receive() external payable {
        // solhint-disable-previous-line no-empty-blocks
    }

    function setStrategy(address newStrategy) external override auth {
        _setStrategy(newStrategy);
    }

    function setPriceOracle(address newPriceOracle) external override auth {
        _setPriceOracle(newPriceOracle);
    }

    function setSwapConnector(address newSwapConnector) external override auth {
        _setSwapConnector(newSwapConnector);
    }

    function setFeeCollector(address newFeeCollector) external override auth {
        _setFeeCollector(newFeeCollector);
    }

    function setWithdrawFee(uint256 newWithdrawFee) external override auth {
        _setWithdrawFee(newWithdrawFee);
    }

    function setPerformanceFee(uint256 newPerformanceFee) external override auth {
        _setPerformanceFee(newPerformanceFee);
    }

    function setSwapFee(uint256 newSwapFee) external override auth {
        _setSwapFee(newSwapFee);
    }

    function collect(address token, address from, uint256 amount, bytes memory data) external override auth {
        _safeTransferFrom(token, from, address(this), amount);
        emit Collect(token, from, amount, data);
    }

    function withdraw(address token, uint256 amount, address recipient, bytes memory data) external override auth {
        require(amount > 0, 'WITHDRAW_AMOUNT_ZERO');
        require(recipient != address(0), 'RECIPIENT_ZERO');

        uint256 withdrawFeeAmount = amount.mulDown(withdrawFee);
        _safeTransfer(token, feeCollector, withdrawFeeAmount);
        uint256 amountAfterFees = amount.sub(withdrawFeeAmount);
        _safeTransfer(token, recipient, amountAfterFees);
        emit Withdraw(token, recipient, amountAfterFees, withdrawFeeAmount, data);
    }

    function wrap(uint256 amount, bytes memory data) external override auth {
        require(address(this).balance >= amount, 'WRAP_INSUFFICIENT_AMOUNT');
        IWrappedNativeToken(wrappedNativeToken).deposit{ value: amount }();
        emit Wrap(amount, data);
    }

    function unwrap(uint256 amount, bytes memory data) external override auth {
        IWrappedNativeToken(wrappedNativeToken).withdraw(amount);
        emit Unwrap(amount, data);
    }

    function claim(bytes memory data) external override auth {
        IStrategy(strategy).claim(data);
        emit Claim(data);
    }

    function join(uint256 amount, uint256 slippage, bytes memory data) external override auth {
        require(amount > 0, 'JOIN_AMOUNT_ZERO');
        require(slippage <= FixedPoint.ONE, 'JOIN_SLIPPAGE_ABOVE_ONE');

        address token = IStrategy(strategy).token();
        _safeTransfer(token, strategy, amount);
        uint256 value = IStrategy(strategy).join(amount, slippage, data);
        investedValue = investedValue + value;
        emit Join(amount, value, slippage, data);
    }

    function exit(uint256 ratio, uint256 slippage, bytes memory data)
        external
        override
        auth
        returns (uint256 received)
    {
        require(investedValue > 0, 'EXIT_NO_INVESTED_VALUE');
        require(ratio > 0 && ratio <= FixedPoint.ONE, 'EXIT_INVALID_RATIO');
        require(slippage <= FixedPoint.ONE, 'EXIT_SLIPPAGE_ABOVE_ONE');

        (uint256 amount, uint256 exitValue) = IStrategy(strategy).exit(ratio, slippage, data);
        address token = IStrategy(strategy).token();
        _safeTransferFrom(token, strategy, address(this), amount);

        uint256 performanceFeeAmount;
        // It can rely on the last updated value since we have just exited, no need to compute current value
        uint256 valueBeforeExit = IStrategy(strategy).lastValue() + exitValue;
        if (valueBeforeExit <= investedValue) {
            // There where losses, invested value is simply reduced using the exited ratio
            // No need for checked math as we are checking it manually beforehand
            investedValue = investedValue.mulUp(FixedPoint.ONE.uncheckedSub(ratio));
        } else {
            // If value gains are greater than the exit value, it means only gains are being withdrawn. In that case
            // the taxable amount is the entire exited amount, otherwise it should be the equivalent gains ratio of it.
            uint256 valueGains = valueBeforeExit - investedValue;
            uint256 taxableAmount = valueGains > exitValue ? amount : ((amount * valueGains) / exitValue);
            performanceFeeAmount = taxableAmount.mulDown(performanceFee);
            _safeTransfer(token, feeCollector, performanceFeeAmount);
            // If the exit value is greater than the value gains, the invested value should be reduced by the portion
            // of the invested value being exited. Otherwise, it's still the same, only gains are being withdrawn.
            // No need for checked math as we are checking it manually beforehand
            uint256 decrement = exitValue > valueGains ? (exitValue.uncheckedSub(valueGains)) : 0;
            investedValue = investedValue - decrement;
        }

        received = amount - performanceFeeAmount;
        emit Exit(received, exitValue, performanceFeeAmount, slippage, data);
    }

    function swap(
        ISwapConnector.Source source,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        SwapLimit limitType,
        uint256 limitAmount,
        bytes memory data
    ) external override auth returns (uint256 amountOut) {
        require(tokenIn != tokenOut, 'SWAP_SAME_TOKEN');

        uint256 minAmountOut;
        if (limitType == SwapLimit.MinAmountOut) {
            minAmountOut = limitAmount;
        } else {
            require(limitAmount <= FixedPoint.ONE, 'SWAP_SLIPPAGE_ABOVE_ONE');
            uint256 price = IPriceOracle(priceOracle).getPrice(tokenOut, tokenIn);
            // No need for checked math as we are checking it manually beforehand
            minAmountOut = amountIn.mulUp(price).mulUp(FixedPoint.ONE.uncheckedSub(limitAmount));
        }

        ISwapConnector connector = ISwapConnector(swapConnector);
        _safeTransfer(tokenIn, address(connector), amountIn);
        uint256 preBalanceOut = IERC20(tokenOut).balanceOf(address(this));
        uint256 amountOutBeforeFees = connector.swap(source, tokenIn, tokenOut, amountIn, minAmountOut, data);
        require(amountOutBeforeFees >= minAmountOut, 'SWAP_MIN_AMOUNT');

        uint256 postBalanceOut = IERC20(tokenOut).balanceOf(address(this));
        require(postBalanceOut >= preBalanceOut.add(amountOutBeforeFees), 'SWAP_INVALID_AMOUNT_OUT');

        uint256 swapFeeAmount = amountOutBeforeFees.mulDown(swapFee);
        _safeTransfer(tokenOut, feeCollector, swapFeeAmount);

        amountOut = amountOutBeforeFees.sub(swapFeeAmount);
        emit Swap(tokenIn, tokenOut, amountIn, amountOut, minAmountOut, swapFeeAmount, data);
    }

    /**
     * @dev Internal method to transfer ERC20 tokens from another account using Mimic's wallet allowance
     * @param token Address of the ERC20 token to transfer
     * @param from Address transferring the tokens from
     * @param to Address transferring the tokens to
     * @param amount Amount of tokens to transfer
     */
    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(from, to, amount);
    }

    /**
     * @dev Internal method to transfer ERC20 or native tokens from the Mimic wallet
     * @param token Address of the ERC20 token to transfer
     * @param to Address transferring the tokens to
     * @param amount Amount of tokens to transfer
     */
    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == ETH) Address.sendValue(payable(to), amount);
        else IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @dev Sets a new strategy.
     * @param newStrategy New strategy to be set
     */
    function _setStrategy(address newStrategy) internal {
        require(strategy == address(0), 'WALLET_STRATEGY_ALREADY_SET');
        _validateDependency(strategy, newStrategy);
        strategy = newStrategy;
        emit StrategySet(newStrategy);
    }

    /**
     * @dev Sets a new price oracle
     * @param newPriceOracle New price oracle to be set
     */
    function _setPriceOracle(address newPriceOracle) internal {
        _validateDependency(priceOracle, newPriceOracle);
        priceOracle = newPriceOracle;
        emit PriceOracleSet(newPriceOracle);
    }

    /**
     * @dev Sets a new swap connector
     * @param newSwapConnector New swap connector to be set
     */
    function _setSwapConnector(address newSwapConnector) internal {
        _validateDependency(swapConnector, newSwapConnector);
        swapConnector = newSwapConnector;
        emit SwapConnectorSet(newSwapConnector);
    }

    /**
     * @dev Internal method to set the fee collector
     * @param newFeeCollector New fee collector to be set
     */
    function _setFeeCollector(address newFeeCollector) internal {
        require(newFeeCollector != address(0), 'FEE_COLLECTOR_ZERO');
        feeCollector = newFeeCollector;
        emit FeeCollectorSet(newFeeCollector);
    }

    /**
     * @dev Internal method to set the withdraw fee
     * @param newWithdrawFee New withdraw fee to be set
     */
    function _setWithdrawFee(uint256 newWithdrawFee) internal {
        require(newWithdrawFee <= FixedPoint.ONE, 'WITHDRAW_FEE_ABOVE_ONE');
        withdrawFee = newWithdrawFee;
        emit WithdrawFeeSet(newWithdrawFee);
    }

    /**
     * @dev Internal method to set the performance fee
     * @param newPerformanceFee New performance fee to be set
     */
    function _setPerformanceFee(uint256 newPerformanceFee) internal {
        require(newPerformanceFee <= FixedPoint.ONE, 'PERFORMANCE_FEE_ABOVE_ONE');
        performanceFee = newPerformanceFee;
        emit PerformanceFeeSet(newPerformanceFee);
    }

    /**
     * @dev Internal method to set the swap fee
     * @param newSwapFee New swap fee to be set
     */
    function _setSwapFee(uint256 newSwapFee) internal {
        require(newSwapFee <= FixedPoint.ONE, 'SWAP_FEE_ABOVE_ONE');
        swapFee = newSwapFee;
        emit SwapFeeSet(newSwapFee);
    }
}
