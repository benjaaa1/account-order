# Otus Account Orders

Testing different UI/UX for limit orders:

Credit to and thanks to:

-   https://github.com/blue-searcher/lyra-quoter

-   https://github.com/Kwenta/margin-manager

Try running some of the following tasks:

```shell
npx hardhat help
npx hardhat test
REPORT_GAS=true npx hardhat test
npx hardhat node
npx hardhat run scripts/deploy.ts
```

# Otus Account/Spread Market Contracts

## Account Marging Management

AccountFactory
AccountOrder

## Spread Market

SpreadOptionMarket

```
Probably
```

SpreadOptionToken
SpreadLiquidityPool

### Edge Cases

Collateral is liquidated (2x min. required increase within expiry)
Keeper would need to check each block (gelato)

-   If collateral is liquidated
-   Route funds to lp
-   Close other positions

-   User is only allowed to close all positions not a single

## Quote Asset Decimals

## USDC 6 decimal points
