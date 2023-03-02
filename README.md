# Otus Account Orders

Testing different UI/UX for limit orders:

Credit to and thanks to:

https://github.com/blue-searcher/lyra-quoter
https://github.com/Kwenta/margin-manager

Try running some of the following tasks:

```shell
npx hardhat help
npx hardhat test
REPORT_GAS=true npx hardhat test
npx hardhat node
npx hardhat run scripts/deploy.ts
```

_/ revert InsufficientEthBalance(address(this).balance, 1 ether / 100);
_/ revert InvalidOrderType();
_/ revert OrderInvalid(\_orderId);
_/ revert InvalidStrike(strikeTrade.strikeId, strikeTrade.market);
_/ revert PremiumAboveExpected(result.totalCost, \_maxPremium);
_/ revert PremiumBelowExpected(result.totalCost, \_minExpectedPremium);
_/ revert InsufficientFreeMargin(freeMargin(), \_amount);
_/ revert EthWithdrawalFailed();

emit StrikeOrderPlaced(address(this), \_trade, orderId);
emit Str
_/ emit Withdraw(msg.sender, \_amount);
_/ emit OrderCancelled(address(this), \_orderId);

\_getValidStrike => getStrike(\_market, \_strikeId) {
strike = lyraBase(\_trade.market).getStrikes(\_toDynamic(\_trade.strikeId))[0];
}

getRequiredCollateral

revert InvalidTradeDirection(
address(this),
\_tradeDirection,
\_isForceClose
);
