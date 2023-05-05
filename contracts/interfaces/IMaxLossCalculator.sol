//SPDX-License-Identifier:ISC
pragma solidity ^0.8.9;

/**
 * @title MaxLossCalculator
 * @author Otus
 * @notice Calculate max loss at min, max and each strike price
 */
interface IMaxLossCalculator {
    struct Strike {
        uint strikePrice;
        uint amount;
        uint premium;
        uint optionType;
    }

    function calculate(Strike[] memory strikes) external pure returns (uint);
}
