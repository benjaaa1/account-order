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

# Otus Product Marketing

## Otus Markets Built on Lyra

-   Otus Option Spread Markets
-   Otus Ranged Markets (Will also be ERC 1155 Will have 2 tokens OUT and IN)

## Will support multiple options platforms (aaevo premia )

-   Otus Option Markets (compare to Hegic.co pricing)

#

ERC1155

-   OtusOptionMarket
    > User buys multiple options
    > ERC1155 is minted when it's a combo
    > When it's a single strike no ERC1155 token needed
