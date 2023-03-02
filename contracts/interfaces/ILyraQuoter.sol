//SPDX-License-Identifier:ISC
pragma solidity ^0.8.9;

// Interfaces
import {IOptionMarket} from "@lyrafinance/protocol/contracts/interfaces/IOptionMarket.sol";

interface ILyraQuoter {
    function quote(
        IOptionMarket _optionMarket,
        uint256 strikeId,
        uint256 iterations,
        IOptionMarket.OptionType optionType,
        uint256 amount,
        IOptionMarket.TradeDirection tradeDirection,
        bool isForceClose
    ) external view returns (uint256 totalPremium, uint256 totalFee);
}
