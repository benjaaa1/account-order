//SPDX-License-Identifier:ISC
pragma solidity ^0.8.9;

import "../positions/OtusOptionToken.sol";

/**
 * @title ISettlementCalculator
 * @author Otus
 * @notice Calculate settlement amounts from lyra options
 */
interface ISettlementCalculator {
    function calculate(
        OtusOptionToken.SettledPosition[] memory optionPositions
    )
        external
        pure
        returns (
            uint totalLPSettlementAmount, // totalPendingCollateral
            uint traderSettlementAmount, // traderProfit
            uint totalCollateral
        );
}
