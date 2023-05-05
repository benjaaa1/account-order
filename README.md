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

### Valid Max Loss Calculation

-   Can be used by UI to calculate the max loss for a position

```
Max loss includes:
Cost of Options
Credits by Premiums
And Collateral Max Loss

The UI may post
maxLossPosted

$480 (fee + costs + max loss collateral - expectedPremium)

1. sell strikes => receive premium
1.a. increases option market balance
2. transfer maxLossPosted to option market
3. buy strikes => maxLossPosted - costs = left over funds in option market + premium collected = maxLossLeftOver > actualMaxLossCalculated

4. difference is the collateral

An actual max loss may be
$450
```

### Ranged Markets Tokens

-   Rewards from Lyra
-   On Optimism => OP Tokens
-   On Arbitrum => Lyra Tokens

Spread Option Market (Would need to use Create2)
-> Stake Lyra on Ethereum Mainnet

controller => generates vault => mints a token
=> generate strategy for vault

=> some tokens are ranged tokens
Ranged token is minted whenevver a position is increased by a certain size
or decreased when

contract OtusController {

buildMarket() {}

}

// profit holder and distributor
contract RangedMarket() {

// openRangedPosition() onlyOwner {}
// opens position of .1 size - maybe easier if we dont open
// opens position in spread option market
// setup in and out market trade

// getinpricing() view {}

// getoutpricing() view {}

// buyRangedPosition() mintRangedPosition()
// transfer funds from user
// mints erc20 tokens transfers to user
// holds spread option token calls (open position with paremeters set by opend ranged position)

// settleRangedPosition() external {}
// check on spread option token
// called by a keeper
// burns tokens and distributes profits if any

// sellRangedPosition() external {}

//

}

// RangedMarketPosition
contract RangedMarketToken is ERC20() {
// modifier
// onlyRangedMarket
}

OtusController (Ranged Market Maker)

-   can have many ranged markets
-   handles creating a ranged market
-   handles buy
-   handles sell

RangedMarket

RangedMarketToken (Position)

// RangedMarket
// check valid ranged market
// valid spread

// calculate max loss

3200 long call
2700 long put

3000 short call
3000 short put

at 4000 max loss is 1000 for short call
with 3200 long call option
3200 - 3000 = 200 max loss
3000 - 2700 = 300 max loss

// Closing partial (longs)
// example
// buy call .1 1950 call paid $.75
// now i want to close
// im actually selling the call (sell_call) im getting paid .308
// longs on partial close i get paid (lose 40 cent though)

// example
// short call .1 1950 call paid $.75
// should i lock in more than the collateral to account for closing fees

// update to limit orders
// lyra makes it too expensive to close a position
// it costs $7 to buy
// if i want to close a minute later
// i'll be able to sell it for $3 later

// if i can set a limit order to buy options at $6
// users place limit order to sell at $5 and above
// swap match

// users sign tx buyer to transfer funds
// users sign tx buyer to transfer lyra option token
// discounted lyra options tab
// immediate buy order button

contract LyraLimitSwap {

enum OrderType {
// buy
// sell
// position id
}

struct Order {

}

mapping(uint => Order) public orders;

uint public orderId;

function buy() {
// buys order id directly from placed seller
// transfer funds
}

function sell() {
// sells order id directly to placed buyer
// transfer funds
}

placeBuyOrder() {
//
}

// probably transfer some eth into this contract
placeSellOrder() {
// sign transaction to transfer lyra option token to new owner once condition met some sort of bytes 32
//
//
}

function cancelOrder()

function checker

function valid() {
// check if any buy orders available
}

function execute

}

sometimes subtracting twice when 1 is enough to cancel short calls lost
so maybe add profits?
