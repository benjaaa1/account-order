import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  lyraConstants,
  TestSystem,
  getGlobalDeploys,
  lyraEvm,
} from "@lyrafinance/protocol";
import { fromBN, MAX_UINT, toBN, ZERO_ADDRESS } from "@lyrafinance/protocol/dist/scripts/util/web3utils";
import { DEFAULT_PRICING_PARAMS } from "@lyrafinance/protocol/dist/test/utils/defaultParams";
import { TestSystemContractsType } from "@lyrafinance/protocol/dist/test/utils/deployTestSystem";
import { PricingParametersStruct } from "@lyrafinance/protocol/dist/typechain-types/OptionMarketViewer";
import {
  LyraBase,
  LyraQuoter,
  MockERC20,
  SpreadLiquidityPool,
  SpreadMaxLossCollateral,
  SpreadOptionMarket,
  SpreadOptionToken
} from "../../typechain-types";
import { LyraGlobal } from "@lyrafinance/protocol/dist/test/utils/package/parseFiles";
import { BigNumber, BigNumberish } from "ethers";
import { ITradeTypes } from "../../typechain-types/contracts/SpreadOptionMarket";

const MARKET_KEY_ETH = ethers.utils.formatBytes32String("ETH");

let sUSD: MockERC20;
let lyraTestSystem: TestSystemContractsType;
let lyraBaseETH: LyraBase;
let lyraQuoter: LyraQuoter;

// spread market contracts
let spreadOptionMarket: SpreadOptionMarket;
let spreadLiquidityPool: SpreadLiquidityPool;
let spreadOptionToken: SpreadOptionToken;
let spreadMaxLossCollateral: SpreadMaxLossCollateral;

let deployer: SignerWithAddress;
let owner: SignerWithAddress;
let depositor1: SignerWithAddress;
let depositor2: SignerWithAddress;
let depositor3: SignerWithAddress;
let trader1: SignerWithAddress;
let trader2: SignerWithAddress;

let lyraGlobal: LyraGlobal;

const boardParameter = {
  expiresIn: lyraConstants.DAY_SEC * 7,
  baseIV: "0.8",
  strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
  skews: ["1.3", "1.2", "1.1", "1", "1.1", "1.3", "1.3"],
};

const spotPrice = toBN("3000");

const initialPoolDeposit = toBN("1500000");

describe("spread option market", async () => {

  before("assign roles", async () => {
    [deployer, owner, depositor1, depositor2, depositor3, trader1, trader2] = await ethers.getSigners();
  });

  before("deploy lyra test", async () => {
    lyraGlobal = getGlobalDeploys("local");

    const pricingParams: PricingParametersStruct = {
      ...DEFAULT_PRICING_PARAMS,
      standardSize: toBN("10"),
      spotPriceFeeCoefficient: toBN("0.001"),
    };

    lyraTestSystem = await TestSystem.deploy(deployer, false, false, { pricingParams });

    await TestSystem.seed(deployer, lyraTestSystem, {
      initialBoard: boardParameter,
      initialBasePrice: spotPrice,
      initialPoolDeposit: initialPoolDeposit,
    });

    sUSD = lyraTestSystem.snx.quoteAsset as MockERC20;

    const LyraQuoterFactory = await ethers.getContractFactory("LyraQuoter", {
      libraries: { BlackScholes: lyraTestSystem.blackScholes.address },
    });

    lyraQuoter = (await LyraQuoterFactory.connect(deployer).deploy(
      lyraTestSystem.lyraRegistry.address
    )) as LyraQuoter;

    const LyraBaseETHFactory = await ethers.getContractFactory("LyraBase", {
      libraries: { BlackScholes: lyraTestSystem.blackScholes.address },
    });

    lyraBaseETH = (await LyraBaseETHFactory.connect(deployer).deploy(
      MARKET_KEY_ETH,
      lyraTestSystem.synthetixAdapter.address,
      lyraTestSystem.optionToken.address,
      lyraTestSystem.optionMarket.address,
      lyraTestSystem.liquidityPool.address,
      lyraTestSystem.shortCollateral.address,
      lyraTestSystem.optionMarketPricer.address,
      lyraTestSystem.optionGreekCache.address,
      lyraTestSystem.GWAVOracle.address,
      lyraQuoter.address
    )) as LyraBase;

  });

  before("deploy spread margin contracts", async () => {

    const SpreadLiquidityPool = await ethers.getContractFactory("SpreadLiquidityPool");
    let LPname = 'Otus Spread Liquidity Pool'
    let LPsymbol = 'OSL'

    spreadLiquidityPool = (await SpreadLiquidityPool.connect(deployer).deploy(
      LPname,
      LPsymbol
    )) as SpreadLiquidityPool;

    const SpreadOptionMarket = await ethers.getContractFactory("SpreadOptionMarket");
    spreadOptionMarket = (await SpreadOptionMarket.connect(deployer).deploy()) as SpreadOptionMarket;

    const SpreadOptionToken = await ethers.getContractFactory("SpreadOptionToken");
    let _name = 'Otus Spread Position';
    let _symbol = 'OSP';
    spreadOptionToken = (await SpreadOptionToken.connect(deployer).deploy(_name, _symbol)) as SpreadOptionToken;

    const SpreadMaxLossCollateral = await ethers.getContractFactory("SpreadMaxLossCollateral");
    spreadMaxLossCollateral = (await SpreadMaxLossCollateral.connect(deployer).deploy()) as SpreadMaxLossCollateral;

    await spreadOptionMarket.connect(deployer).initialize(
      lyraTestSystem.snx.quoteAsset.address,
      lyraBaseETH.address,
      lyraBaseETH.address,
      spreadMaxLossCollateral.address,
      spreadOptionToken.address,
      spreadLiquidityPool.address
    );

    await spreadLiquidityPool.connect(deployer).initialize(
      spreadOptionMarket.address,
      lyraTestSystem.snx.quoteAsset.address
    );

    await spreadOptionToken.connect(deployer).initialize(
      spreadOptionMarket.address,
      lyraBaseETH.address,
      lyraBaseETH.address,
    );

    await spreadMaxLossCollateral.connect(deployer).initialize(
      lyraTestSystem.snx.quoteAsset.address,
      spreadOptionMarket.address,
      spreadLiquidityPool.address
    );

  });

  before("mint susd for depositors", async () => {
    await sUSD.mint(depositor1.address, toBN("60000"));
    await sUSD.mint(depositor2.address, toBN("84000"));
    await sUSD.mint(depositor3.address, toBN("90000"));
  });

  before("mint susd for traders", async () => {
    await sUSD.mint(trader1.address, toBN("182000"));
    await sUSD.mint(trader2.address, toBN("182000"));
  });

  before("approve option market for traders", async () => {
    await sUSD.connect(trader1).approve(spreadOptionMarket.address, toBN('182000'));
    await sUSD.connect(trader2).approve(spreadOptionMarket.address, toBN('182000'));
  })

  describe("deposit into lp and attempt to open spread position", () => {

    let startLPBalance = 0;
    let boardId = toBN("0");
    let strikes: BigNumber[] = [];

    before("init board", async () => {

      const boards = await lyraTestSystem.optionMarket.getLiveBoards();
      boardId = boards[0];

      await lyraTestSystem.optionGreekCache.updateBoardCachedGreeks(boardId);

      await lyraEvm.fastForward(600);

    })

    before("set strikes array", async () => {
      strikes = await lyraTestSystem.optionMarket.getBoardStrikes(boardId);
    });

    before("depositors deposit into liquidity pool", async () => {

      await sUSD.connect(depositor1).approve(spreadLiquidityPool.address, toBN('5000'));
      await spreadLiquidityPool.connect(depositor1).initiateDeposit(depositor1.address, toBN('5000'));

      await sUSD.connect(depositor2).approve(spreadLiquidityPool.address, toBN('12000'));
      await spreadLiquidityPool.connect(depositor2).initiateDeposit(depositor1.address, toBN('12000'));

      await sUSD.connect(depositor3).approve(spreadLiquidityPool.address, toBN('3000'));
      await spreadLiquidityPool.connect(depositor3).initiateDeposit(depositor1.address, toBN('3000'));

      startLPBalance = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)))

    });

    it("should be able to open a simple trade long call", async () => {

      const optionMarketBalanceBeforeTrade = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      const strikeTrade1: ITradeTypes.TradeInputParametersStruct = await buildOrderWithQuote(
        strikes[2],
        0,// option type (long call 0),
        toBN('3'),
        0
      );

      const strikeTrades: ITradeTypes.TradeInputParametersStruct[] = [strikeTrade1];

      const maxLossPosted = strikeTrade1.maxTotalCost; // max loss is + maxloss + maxcost - premium + spread fee
      try {
        await spreadOptionMarket.connect(trader1).openPosition({ positionId: 0, market: MARKET_KEY_ETH }, strikeTrades, maxLossPosted);
      } catch (error) {
        console.log({ error })
      }

      const position = await spreadOptionToken.getOwnerPositions(trader1.address);

      expect(position.length).to.be.eq(1);

      // market should not hold any funds after completing trade
      const optionMarketBalanceAfterTrade = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));
      expect(optionMarketBalanceAfterTrade).to.be.eq(optionMarketBalanceBeforeTrade);

    });

    it('should revert spread trade exceeding cost', async () => {

      const strikeTrade1: ITradeTypes.TradeInputParametersStruct = await buildOrderWithQuote(
        strikes[6],
        0,// option type (long call 0),
        toBN('4'),
        0
      );

      const strikeTrade2: ITradeTypes.TradeInputParametersStruct = await buildOrderWithQuote(
        strikes[2],
        3, // option type (short call 3)
        toBN('2'),
        0
      )

      const strikeTrade3: ITradeTypes.TradeInputParametersStruct = await buildOrderWithQuote(
        strikes[3],
        3, // option type (short call 3)
        toBN('2'),
        0
      )

      const strikeTrades: ITradeTypes.TradeInputParametersStruct[] = [strikeTrade1, strikeTrade2, strikeTrade3];
      console.log({ maxLossPostedCollateral: fromBN('1310799713173767155407') })
      await expect(
        spreadOptionMarket.connect(trader1).openPosition(
          { positionId: 0, market: MARKET_KEY_ETH },
          strikeTrades,
          toBN('150')
        )
      ).to.be.revertedWith(
        'MaxLossRequirementNotMet',
      );

      const position = await spreadOptionToken.getOwnerPositions(trader1.address);

      expect(position.length).to.be.eq(1);

    });

    it('should do a simple check on spread trade validity', async () => {

      const optionMarketBalanceBeforeTrade = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      const strikeTrade1: ITradeTypes.TradeInputParametersStruct = await buildOrderWithQuote(
        strikes[2],
        0,// option type (long call 0),
        toBN('5'),
        0
      );

      const strikeTrade2: ITradeTypes.TradeInputParametersStruct = await buildOrderWithQuote(
        strikes[2],
        3, // option type (short call 3)
        toBN('2'),
        0
      )

      const strikeTrade3: ITradeTypes.TradeInputParametersStruct = await buildOrderWithQuote(
        strikes[3],
        3, // option type (short call 3)
        toBN('1'),
        0
      )

      const strikeTrades: ITradeTypes.TradeInputParametersStruct[] = [strikeTrade1, strikeTrade2, strikeTrade3];
      await spreadOptionMarket.connect(trader1).openPosition({ positionId: 0, market: MARKET_KEY_ETH }, strikeTrades, toBN('3680'));

      // get position id and event
      const position = await spreadOptionToken.getOwnerPositions(trader1.address);

      expect(position.length).to.be.eq(2);

      // market should not hold any funds after completing trade
      const optionMarketBalanceAfterTrade = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));
      expect(optionMarketBalanceAfterTrade).to.be.eq(optionMarketBalanceBeforeTrade);

    });

    it('should settle positions and return collateral to liquidity pool with fee 1', async () => {

      // Wait till board expires
      await lyraEvm.fastForward(lyraConstants.MONTH_SEC);

      // Mock sETH price
      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("2100"), 'sETH');

      const totalPositions = (await lyraTestSystem.optionToken.nextId()).sub(1).toNumber();

      const lpBalanceBeforeSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)));
      const optionMarketBalanceBeforeSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      const idsToSettle = Array.from({ length: totalPositions }, (_, i) => i + 1); // create array of [1... totalPositions]
      await lyraTestSystem.optionMarket.settleExpiredBoard(boardId);
      await lyraTestSystem.shortCollateral.settleOptions(idsToSettle);

      const positionIds = await spreadOptionToken.getPositionIds();

      await spreadOptionMarket.settleOption(positionIds[0]);
      await spreadOptionMarket.settleOption(positionIds[1]);

      const lpBalanceAfterSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)));
      const optionMarketAfterOtusSpreadSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      expect(lpBalanceAfterSettlement).to.be.greaterThanOrEqual(startLPBalance);
      expect(lpBalanceAfterSettlement).to.be.greaterThanOrEqual(lpBalanceBeforeSettlement);
      expect(optionMarketAfterOtusSpreadSettlement).to.be.eq(optionMarketBalanceBeforeSettlement);

    })
  });

  describe("deposit into lp and attempt to open spread position - different strike prices", () => {

    let startLPBalance = 0;
    let boardId = toBN("0");
    let strikes: BigNumber[] = [];

    before("init board", async () => {

      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("1950"), 'sETH');

      await TestSystem.marketActions.createBoard(lyraTestSystem, {
        expiresIn: lyraConstants.DAY_SEC * 7,
        baseIV: "0.6",
        strikePrices: ["1700", "1800", "1900", "2000", "2100", "2200"],
        skews: ["1.2", "1.2", "1.1", "1", "1.1", "1.2"],
      })

    })

    before("set board id", async () => {

      const boards = await lyraTestSystem.optionMarket.getLiveBoards();
      boardId = boards[0];

      await lyraTestSystem.optionGreekCache.updateBoardCachedGreeks(boardId);

      await lyraEvm.fastForward(600);

    })

    before("set strikes array", async () => {
      strikes = await lyraTestSystem.optionMarket.getBoardStrikes(boardId);
    });

    before("depositors deposit into liquidity pool", async () => {

      const startTrade = parseInt(fromBN(await sUSD.balanceOf(trader1.address)))

      const optionMarketBalance = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      await sUSD.connect(depositor1).approve(spreadLiquidityPool.address, toBN('5000'));
      await spreadLiquidityPool.connect(depositor1).initiateDeposit(depositor1.address, toBN('5000'));

      await sUSD.connect(depositor2).approve(spreadLiquidityPool.address, toBN('12000'));
      await spreadLiquidityPool.connect(depositor2).initiateDeposit(depositor1.address, toBN('12000'));

      await sUSD.connect(depositor3).approve(spreadLiquidityPool.address, toBN('3000'));
      await spreadLiquidityPool.connect(depositor3).initiateDeposit(depositor1.address, toBN('3000'));

      startLPBalance = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)))

    });

    it('should do a simple check on spread trade validity - test', async () => {

      const strikeTrade1: ITradeTypes.TradeInputParametersStruct = await buildOrderWithQuote(
        strikes[4],
        0,// option type (long call 0),
        toBN('22'),
        0
      );
      const strikeTrade2: ITradeTypes.TradeInputParametersStruct = await buildOrderWithQuote(
        strikes[1],
        3, // option type (short call 3)
        toBN('11'),
        0
      )

      const strikeTrades: ITradeTypes.TradeInputParametersStruct[] = [strikeTrade1, strikeTrade2];
      await spreadOptionMarket.connect(trader1).openPosition({ positionId: 0, market: MARKET_KEY_ETH }, strikeTrades, toBN('3500'));

      // get position id and event
      const position = await spreadOptionToken.getOwnerPositions(trader1.address);
      expect(position.length).to.be.eq(1);

    });

    it('should settle positions and return collateral to liquidity pool with fee - 2', async () => {

      // Wait till board expires
      await lyraEvm.fastForward(lyraConstants.MONTH_SEC);

      // Mock sETH price
      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("2050"), 'sETH');

      // const totalPositions = (await lyraTestSystem.optionToken.nextId()).sub(1).toNumber();

      const beforeSettlementTraderBalance = parseInt(fromBN(await sUSD.balanceOf(trader1.address)))
      const maxLossCollateralBefore = parseInt(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));
      expect(maxLossCollateralBefore).to.be.greaterThan(0);

      const lpBalanceBeforeSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)));
      const optionMarketBalanceBeforeSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      // const idsToSettle = Array.from({ length: totalPositions }, (_, i) => i + 1); // create array of [1... totalPositions]
      await lyraTestSystem.optionMarket.settleExpiredBoard(boardId);

      await lyraTestSystem.shortCollateral.settleOptions([5, 6]);

      const positionIds = await spreadOptionToken.getPositionIds();

      await spreadOptionMarket.settleOption(positionIds[0]);

      const maxLossCollateralAfter = parseInt(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));
      const lpBalanceAfterSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)));
      const optionMarketAfterOtusSpreadSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));
      const afterSettlementTraderBalance = parseInt(fromBN(await sUSD.balanceOf(trader1.address)));

      expect(maxLossCollateralAfter).to.be.eq(toBN('0'));
      expect(beforeSettlementTraderBalance).to.be.lessThan(afterSettlementTraderBalance);
      expect(lpBalanceAfterSettlement).to.be.greaterThanOrEqual(startLPBalance);
      expect(lpBalanceAfterSettlement).to.be.greaterThanOrEqual(lpBalanceBeforeSettlement);
      expect(optionMarketAfterOtusSpreadSettlement).to.be.eq(optionMarketBalanceBeforeSettlement);

    })
  });

  describe("deposit into lp open and close a position after spot price moves significantly up", () => {

    let startLPBalance = 0;
    let startTraderBalance = 0;
    let strikeTrade1: ITradeTypes.TradeInputParametersStruct;
    let strikeTrade2: ITradeTypes.TradeInputParametersStruct;
    let strikeTrade3: ITradeTypes.TradeInputParametersStruct;

    let tradeResults: any[];

    let boardId = toBN("0");
    let strikes: BigNumber[] = [];

    before("init board", async () => {

      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("3000"), 'sETH');

      await TestSystem.marketActions.createBoard(lyraTestSystem, {
        expiresIn: lyraConstants.DAY_SEC * 7,
        baseIV: "0.8",
        strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
        skews: ["1.3", "1.2", "1.1", "1", "1.1", "1.3", "1.3"],
      })

    })

    before("set board id", async () => {
      const boards = await lyraTestSystem.optionMarket.getLiveBoards();
      boardId = boards[0];

      await lyraTestSystem.optionGreekCache.updateBoardCachedGreeks(boardId);

      await lyraEvm.fastForward(600);
    })

    before("set strikes array", async () => {
      strikes = await lyraTestSystem.optionMarket.getBoardStrikes(boardId);
    });

    before("depositors deposit into liquidity pool", async () => {

      await sUSD.connect(depositor1).approve(spreadLiquidityPool.address, toBN('5000'));
      await spreadLiquidityPool.connect(depositor1).initiateDeposit(depositor1.address, toBN('5000'));

      await sUSD.connect(depositor2).approve(spreadLiquidityPool.address, toBN('12000'));
      await spreadLiquidityPool.connect(depositor2).initiateDeposit(depositor1.address, toBN('12000'));

      await sUSD.connect(depositor3).approve(spreadLiquidityPool.address, toBN('3000'));
      await spreadLiquidityPool.connect(depositor3).initiateDeposit(depositor1.address, toBN('3000'));

      startLPBalance = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)));

      startTraderBalance = parseInt(fromBN(await sUSD.balanceOf(trader1.address)))

    });

    it("should do a simple check on spread trade validity", async () => {

      strikeTrade1 = await buildOrderWithQuote(
        strikes[2],
        0,// option type (long call 0),
        toBN('5'),
        0
      );
      strikeTrade2 = await buildOrderWithQuote(
        strikes[2],
        3, // option type (short call 3)
        toBN('2'),
        0
      )

      strikeTrade3 = await buildOrderWithQuote(
        strikes[3],
        3, // option type (short call 3)
        toBN('1'),
        0
      )

      const strikeTrades: ITradeTypes.TradeInputParametersStruct[] = [strikeTrade1, strikeTrade2, strikeTrade3];
      const tx = await spreadOptionMarket.connect(trader1).openPosition({ positionId: 0, market: MARKET_KEY_ETH }, strikeTrades, toBN('1780'));

      const rc = await tx.wait(); // 0ms, as tx is already confirmed
      const event = rc.events?.find(
        (event: { event: string }) => event.event === "Trade"
      );
      // @ts-ignore
      const [
        trader,
        sellResults,
        buyResults,
        totalCollateralToAdd, // borrowed
        fee,
        maxCost
      ] = event?.args;

      // convert trade results for future close
      tradeResults = convertResultToTradeParams([...sellResults, ...buyResults])

      // get position id and event
      const position = await spreadOptionToken.getOwnerPositions(trader1.address);

      expect(position.length).to.be.eq(1);

    })

    it("should revert if not owner attempting to close position", async () => {
      const positions = await spreadOptionToken.getOwnerPositions(trader1.address);
      const position = positions[0];

      await expect(
        spreadOptionMarket.closePosition(position.market, position.positionId, [strikeTrade1, strikeTrade2, strikeTrade3])).to.be.revertedWith(
          'OnlyOwnerCanClose',
        );

    });

    it("should be able to close position on lyra and settle on otus", async () => {

      const optionMarketBeforeClose = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));
      expect(optionMarketBeforeClose).to.be.eq(toBN('0'));
      const traderBalanceBeforeClose = parseInt(fromBN(await sUSD.balanceOf(trader1.address)))

      // big profit on buys
      // big loss on sells (lp must recover)
      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("1000"), 'sETH');

      const positions = await spreadOptionToken.getOwnerPositions(trader1.address);
      const position = positions[0];

      await spreadOptionMarket.connect(trader1).closePosition(position.market, position.positionId, tradeResults);

      const traderBalance = parseInt(fromBN(await sUSD.balanceOf(trader1.address)))
      const endLPBalance = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)))
      const maxLossCollateralAfter = parseInt(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));
      const optionMarketAfterClose = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      // lp recovers funds 
      expect(maxLossCollateralAfter).to.be.eq(toBN('0'));
      expect(endLPBalance).to.be.greaterThanOrEqual(startLPBalance);
      expect(traderBalance).to.be.greaterThan(traderBalanceBeforeClose);
      expect(optionMarketAfterClose).to.be.eq(toBN('0'));

    });


  });

  describe("deposit into lp open and close a position after spot price moves significantly down", () => {

    let startLPBalance = 0;
    let strikeTrade1: ITradeTypes.TradeInputParametersStruct;
    let strikeTrade2: ITradeTypes.TradeInputParametersStruct;
    let strikeTrade3: ITradeTypes.TradeInputParametersStruct;

    let tradeResults: any[];

    let boardId = toBN("0");
    let strikes: BigNumber[] = [];

    before("init board", async () => {

      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("3000"), 'sETH');

      await TestSystem.marketActions.createBoard(lyraTestSystem, {
        expiresIn: lyraConstants.DAY_SEC * 7,
        baseIV: "0.8",
        strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
        skews: ["1.3", "1.2", "1.1", "1", "1.1", "1.3", "1.3"],
      })

    })

    before("set board id", async () => {
      const boards = await lyraTestSystem.optionMarket.getLiveBoards();
      boardId = boards[0];

      await lyraTestSystem.optionGreekCache.updateBoardCachedGreeks(boardId);

      await lyraEvm.fastForward(600);
    })

    before("set strikes array", async () => {
      strikes = await lyraTestSystem.optionMarket.getBoardStrikes(boardId);
    });

    before("depositors deposit into liquidity pool", async () => {

      await sUSD.connect(depositor1).approve(spreadLiquidityPool.address, toBN('5000'));
      await spreadLiquidityPool.connect(depositor1).initiateDeposit(depositor1.address, toBN('5000'));

      await sUSD.connect(depositor2).approve(spreadLiquidityPool.address, toBN('12000'));
      await spreadLiquidityPool.connect(depositor2).initiateDeposit(depositor1.address, toBN('12000'));

      await sUSD.connect(depositor3).approve(spreadLiquidityPool.address, toBN('3000'));
      await spreadLiquidityPool.connect(depositor3).initiateDeposit(depositor1.address, toBN('3000'));


    });

    it("should do a simple check on spread trade validity", async () => {

      strikeTrade1 = await buildOrderWithQuote(
        strikes[2],
        0,// option type (long call 0),
        toBN('5'),
        0
      );

      strikeTrade2 = await buildOrderWithQuote(
        strikes[2],
        3, // option type (short call 3)
        toBN('2'),
        0
      )

      strikeTrade3 = await buildOrderWithQuote(
        strikes[3],
        3, // option type (short call 3)
        toBN('1'),
        0
      )

      const strikeTrades: ITradeTypes.TradeInputParametersStruct[] = [strikeTrade1, strikeTrade2, strikeTrade3];
      const tx = await spreadOptionMarket.connect(trader1).openPosition({ positionId: 0, market: MARKET_KEY_ETH }, strikeTrades, toBN('1780'));

      const rc = await tx.wait(); // 0ms, as tx is already confirmed
      const event = rc.events?.find(
        (event: { event: string }) => event.event === "Trade"
      );
      // @ts-ignore
      const [
        trader,
        sellResults,
        buyResults,
        totalCollateralToAdd, // borrowed
        fee,
        maxCost
      ] = event?.args;


      // convert trade results for future close
      tradeResults = convertResultToTradeParams([...sellResults, ...buyResults])

      // get position id and event
      const position = await spreadOptionToken.getOwnerPositions(trader1.address);

      expect(position.length).to.be.eq(1);

    })

    it("should revert if not owner attempting to close position", async () => {
      const positions = await spreadOptionToken.getOwnerPositions(trader1.address);
      const position = positions[0];

      await expect(
        spreadOptionMarket.closePosition(position.market, position.positionId, [strikeTrade1, strikeTrade2, strikeTrade3])).to.be.revertedWith(
          'OnlyOwnerCanClose',
        );

    });

    it("should be able to close position on lyra and settle on otus", async () => {

      const optionMarketBeforeClose = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));
      expect(optionMarketBeforeClose).to.be.eq(toBN('0'));
      const traderBalanceBeforeClose = parseInt(fromBN(await sUSD.balanceOf(trader1.address)))

      // big profit on buys
      // big loss on sells (lp must recover)
      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("1200"), 'sETH');
      await lyraEvm.fastForward(60000);


      const positions = await spreadOptionToken.getOwnerPositions(trader1.address);
      const position = positions[0];

      await spreadOptionMarket.connect(trader1).closePosition(position.market, position.positionId, tradeResults);

      const traderBalance = parseInt(fromBN(await sUSD.balanceOf(trader1.address)))
      const endLPBalance = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)))
      const maxLossCollateralAfter = parseInt(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));
      const optionMarketAfterClose = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      // lp recovers funds 
      expect(endLPBalance).to.be.greaterThanOrEqual(startLPBalance);
      // max loss posted already but may need to recover fees form user
      expect(traderBalance).to.be.greaterThan(traderBalanceBeforeClose);
      expect(maxLossCollateralAfter).to.be.eq(toBN('0'));
      expect(optionMarketAfterClose).to.be.eq(toBN('0'));

    });

  });

  describe("deposit into lp open, modify and settle position", () => {

    let startLPBalance = 0;
    let traderStart = 0;
    let strikeTrade1: ITradeTypes.TradeInputParametersStruct;
    let strikeTrade2: ITradeTypes.TradeInputParametersStruct;
    let strikeTrade3: ITradeTypes.TradeInputParametersStruct;
    let spreadPositionId: BigNumber;

    let tradeResults: any[];
    let updatedResults: any[];

    let boardId = toBN("0");
    let strikes: BigNumber[] = [];

    before("init board", async () => {

      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("3000"), 'sETH');

      await TestSystem.marketActions.createBoard(lyraTestSystem, {
        expiresIn: lyraConstants.DAY_SEC * 7,
        baseIV: "0.8",
        strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
        skews: ["1.3", "1.2", "1.1", "1", "1.1", "1.3", "1.3"],
      })

    })

    before("set board id", async () => {
      const boards = await lyraTestSystem.optionMarket.getLiveBoards();
      boardId = boards[0];

      await lyraTestSystem.optionGreekCache.updateBoardCachedGreeks(boardId);

      await lyraEvm.fastForward(600);
    })

    before("set strikes array", async () => {
      strikes = await lyraTestSystem.optionMarket.getBoardStrikes(boardId);
    });

    before("depositors deposit into liquidity pool", async () => {

      await sUSD.connect(depositor1).approve(spreadLiquidityPool.address, toBN('5000'));
      await spreadLiquidityPool.connect(depositor1).initiateDeposit(depositor1.address, toBN('5000'));

      await sUSD.connect(depositor2).approve(spreadLiquidityPool.address, toBN('12000'));
      await spreadLiquidityPool.connect(depositor2).initiateDeposit(depositor1.address, toBN('12000'));

      await sUSD.connect(depositor3).approve(spreadLiquidityPool.address, toBN('3000'));
      await spreadLiquidityPool.connect(depositor3).initiateDeposit(depositor1.address, toBN('3000'));

    });

    it("should do a simple check on spread trade validity", async () => {

      traderStart = parseInt(fromBN(await sUSD.balanceOf(trader1.address)))

      strikeTrade1 = await buildOrderWithQuote(
        strikes[2],
        0,// option type (long call 0),
        toBN('5'),
        0
      );

      strikeTrade2 = await buildOrderWithQuote(
        strikes[2],
        3, // option type (short call 3)
        toBN('2'),
        0
      )

      strikeTrade3 = await buildOrderWithQuote(
        strikes[3],
        3, // option type (short call 3)
        toBN('1'),
        0
      )

      const strikeTrades: ITradeTypes.TradeInputParametersStruct[] = [strikeTrade1, strikeTrade2, strikeTrade3];
      const tx = await spreadOptionMarket.connect(trader1).openPosition({ positionId: 0, market: MARKET_KEY_ETH }, strikeTrades, toBN('1780'));

      const rc = await tx.wait(); // 0ms, as tx is already confirmed
      const event = rc.events?.find(
        (event: { event: string }) => event.event === "Trade"
      );
      // @ts-ignore
      const [
        trader,
        sellResults,
        buyResults,
        totalCollateralToAdd, // borrowed
        fee,
        maxCost
      ] = event?.args;

      // convert trade results for future close
      tradeResults = convertResultToTradeParams([...sellResults, ...buyResults])

      // get position id and event
      const position = await spreadOptionToken.getOwnerPositions(trader1.address);

      spreadPositionId = position[0].positionId;

      expect(position.length).to.be.eq(1);

    })

    it("should revert an update on previous spread trade when no lyra position id", async () => {

      strikeTrade1 = await buildOrderWithQuote(
        strikes[2],
        0,// option type (long call 0),
        toBN('5'),
        0
      );

      strikeTrade2 = await buildOrderWithQuote(
        strikes[2],
        3, // option type (short call 3)
        toBN('2'),
        0
      )

      strikeTrade3 = await buildOrderWithQuote(
        strikes[3],
        3, // option type (short call 3)
        toBN('1'),
        0
      )

      const strikeTrades: ITradeTypes.TradeInputParametersStruct[] = [strikeTrade1, strikeTrade2, strikeTrade3];

      await expect(
        spreadOptionMarket.connect(trader1).openPosition({ positionId: spreadPositionId, market: MARKET_KEY_ETH }, strikeTrades, toBN('1780'))).to.be.revertedWith(
          'NotValidIncrease',
        );

    })

    it("should update on previous spread trade", async () => {

      strikeTrade1 = await buildOrderWithQuote(
        strikes[2],
        0,// option type (long call 0),
        toBN('2'),
        15
      );

      strikeTrade2 = await buildOrderWithQuote(
        strikes[2],
        3, // option type (short call 3)
        toBN('1'),
        13
      )

      strikeTrade3 = await buildOrderWithQuote(
        strikes[3],
        3, // option type (short call 3)
        toBN('1'),
        14
      )

      const strikeTrades: ITradeTypes.TradeInputParametersStruct[] = [strikeTrade1, strikeTrade2, strikeTrade3];

      // console.log({
      //   tradeResults: tradeResults.map(trade => {
      //     return fromBN(trade.positionId);
      //   })
      // })

      // await expect(
      //  ).to.be.revertedWith(
      //     'NotValidIncrease',
      //   );
      const tx = await spreadOptionMarket.connect(trader1).openPosition({ positionId: spreadPositionId, market: MARKET_KEY_ETH }, strikeTrades, toBN('1780'))

      const rc = await tx.wait(); // 0ms, as tx is already confirmed
      const event = rc.events?.find(
        (event: { event: string }) => event.event === "Trade"
      );
      // @ts-ignore
      const [
        trader,
        sellResults,
        buyResults,
        totalCollateralToAdd, // borrowed
        fee,
        maxCost
      ] = event?.args;

      // convert trade results for future close
      updatedResults = convertResultToTradeParams([...sellResults, ...buyResults]);

    })

    it('should settle positions and return collateral to liquidity pool with fee - 3', async () => {

      // Wait till board expires
      await lyraEvm.fastForward(lyraConstants.MONTH_SEC);

      // Mock sETH price
      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("2050"), 'sETH');

      const beforeSettlementTraderBalance = parseInt(fromBN(await sUSD.balanceOf(trader1.address)))
      const maxLossCollateralBefore = parseInt(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));
      expect(maxLossCollateralBefore).to.be.greaterThan(0);

      const lpBalanceBeforeSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)));
      const optionMarketBalanceBeforeSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      await lyraTestSystem.optionMarket.settleExpiredBoard(boardId);

      await lyraTestSystem.shortCollateral.settleOptions([13, 14, 15]);

      const positionIds = await spreadOptionToken.getPositionIds();
      await spreadOptionMarket.settleOption(positionIds[0]);
      const maxLossCollateralAfter = parseInt(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));
      const lpBalanceAfterSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)));
      const optionMarketAfterOtusSpreadSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));
      const afterSettlementTraderBalance = parseInt(fromBN(await sUSD.balanceOf(trader1.address)));

      expect(maxLossCollateralAfter).to.be.eq(toBN('0'));
      expect(beforeSettlementTraderBalance).to.be.lessThan(afterSettlementTraderBalance);
      expect(lpBalanceAfterSettlement).to.be.greaterThanOrEqual(startLPBalance);
      expect(lpBalanceAfterSettlement).to.be.greaterThanOrEqual(lpBalanceBeforeSettlement);
      expect(optionMarketAfterOtusSpreadSettlement).to.be.eq(optionMarketBalanceBeforeSettlement);

    })

    // it("should be able to close position on lyra after it is updated and settle on otus", async () => {

    //   const optionMarketBeforeClose = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));
    //   expect(optionMarketBeforeClose).to.be.eq(toBN('0'));
    //   const traderBalanceBeforeClose = parseInt(fromBN(await sUSD.balanceOf(trader1.address)))

    //   // big profit on buys
    //   // big loss on sells (lp must recover)
    //   await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("1200"), 'sETH');
    //   await lyraEvm.fastForward(60000);


    //   const positions = await spreadOptionToken.getOwnerPositions(trader1.address);
    //   const position = positions[0];
    //   console.log({ positions })
    //   // console.log({
    //   //   tradeResults: tradeResults.map(trade => {
    //   //     return { positionId: fromBN(trade.positionId), amount: fromBN(trade.amount) };
    //   //   })
    //   // })

    //   // let closeResults = tradeResults.map(tradeResult => {
    //   //   const positionId = tradeResult
    //   //   return
    //   // })

    //   const amounts: Record<string, BigNumber> = {
    //     '0.000000000000000013': toBN('3'),
    //     '0.000000000000000014': toBN('2'),
    //     '0.000000000000000015': toBN('7'),
    //   }

    //   tradeResults = tradeResults.map((tradeResult) => {
    //     console.log(tradeResult.positionId)
    //     return { ...tradeResult, amount: amounts[fromBN(tradeResult.positionId)] }
    //   })

    //   await spreadOptionMarket.connect(trader1).closePosition(position.market, position.positionId, false, tradeResults);

    //   const traderBalance = parseInt(fromBN(await sUSD.balanceOf(trader1.address)))
    //   const endLPBalance = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)))
    //   const maxLossCollateralAfter = parseInt(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));
    //   const optionMarketAfterClose = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

    //   console.log({
    //     traderStart,
    //     traderBalance,
    //     endLPBalance,
    //     maxLossCollateralAfter,
    //     optionMarketAfterClose
    //   })

    //   // lp recovers funds 
    //   expect(endLPBalance).to.be.greaterThanOrEqual(startLPBalance);
    //   // max loss posted already but may need to recover fees form user
    //   expect(traderBalance).to.be.greaterThan(traderBalanceBeforeClose);
    //   expect(optionMarketAfterClose).to.be.eq(toBN('0'));
    //   expect(maxLossCollateralAfter).to.be.eq(toBN('0'));

    // });

  });

  describe("deposit into lp open and close part of a position after spot price moves significantly", () => {

    let startLPBalance = 0;
    let strikeTrade1: ITradeTypes.TradeInputParametersStruct;
    let strikeTrade2: ITradeTypes.TradeInputParametersStruct;
    let strikeTrade3: ITradeTypes.TradeInputParametersStruct;

    let tradeResults: any[];

    let boardId = toBN("0");
    let strikes: BigNumber[] = [];

    before("init board", async () => {

      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("3000"), 'sETH');

      await TestSystem.marketActions.createBoard(lyraTestSystem, {
        expiresIn: lyraConstants.DAY_SEC * 7,
        baseIV: "0.8",
        strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
        skews: ["1.3", "1.2", "1.1", "1", "1.1", "1.3", "1.3"],
      })

    })

    before("set board id", async () => {
      const boards = await lyraTestSystem.optionMarket.getLiveBoards();
      boardId = boards[2];
      console.log({ boardId, boards })
      await lyraTestSystem.optionGreekCache.updateBoardCachedGreeks(boardId);

      await lyraEvm.fastForward(600);
    })

    before("set strikes array", async () => {
      strikes = await lyraTestSystem.optionMarket.getBoardStrikes(boardId);
    });

    before("depositors deposit into liquidity pool", async () => {

      await sUSD.connect(depositor1).approve(spreadLiquidityPool.address, toBN('5000'));
      await spreadLiquidityPool.connect(depositor1).initiateDeposit(depositor1.address, toBN('5000'));

      await sUSD.connect(depositor2).approve(spreadLiquidityPool.address, toBN('12000'));
      await spreadLiquidityPool.connect(depositor2).initiateDeposit(depositor1.address, toBN('12000'));

      await sUSD.connect(depositor3).approve(spreadLiquidityPool.address, toBN('3000'));
      await spreadLiquidityPool.connect(depositor3).initiateDeposit(depositor1.address, toBN('3000'));


    });

    it("should do a simple check on spread trade validity", async () => {

      strikeTrade1 = await buildOrderWithQuote(
        strikes[2],
        0,// option type (long call 0),
        toBN('5'),
        0
      );

      strikeTrade2 = await buildOrderWithQuote(
        strikes[2],
        3, // option type (short call 3)
        toBN('2'),
        0
      )

      strikeTrade3 = await buildOrderWithQuote(
        strikes[3],
        3, // option type (short call 3)
        toBN('1'),
        0
      )

      const strikeTrades: ITradeTypes.TradeInputParametersStruct[] = [strikeTrade1, strikeTrade2, strikeTrade3];
      const tx = await spreadOptionMarket.connect(trader1).openPosition({ positionId: 0, market: MARKET_KEY_ETH }, strikeTrades, toBN('1780'));

      const rc = await tx.wait(); // 0ms, as tx is already confirmed
      const event = rc.events?.find(
        (event: { event: string }) => event.event === "Trade"
      );
      // @ts-ignore
      const [
        trader,
        sellResults,
        buyResults,
        totalCollateralToAdd, // borrowed
        fee,
        maxCost
      ] = event?.args;


      // convert trade results for future close
      tradeResults = convertResultToTradeParams([...sellResults, ...buyResults])

      // get position id and event
      const position = await spreadOptionToken.getOwnerPositions(trader1.address);

      expect(position.length).to.be.eq(1);

    })

    it("should be able to partially close position on spread market and lyra option markets without settling", async () => {

      // const positions = await spreadOptionToken.getOwnerPositions(trader1.address);
      // const position = positions[0];
      // await spreadOptionMarket.connect(trader1).closePosition(position.market, position.positionId, true, tradeResults.map(result => ({ ...result, amount: toBN('.1') })));

    })

    // it("should be able to close position on lyra and settle on otus", async () => {

    //   const optionMarketBeforeClose = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));
    //   expect(optionMarketBeforeClose).to.be.eq(toBN('0'));
    //   const traderBalanceBeforeClose = parseInt(fromBN(await sUSD.balanceOf(trader1.address)))

    //   // big profit on buys
    //   // big loss on sells (lp must recover)
    //   await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("1200"), 'sETH');
    //   await lyraEvm.fastForward(60000);


    //   const positions = await spreadOptionToken.getOwnerPositions(trader1.address);
    //   const position = positions[0];

    //   await spreadOptionMarket.connect(trader1).closePosition(position.market, position.positionId, true, tradeResults.map(result => ({ ...result, amount: toBN('.1') })));

    //   const traderBalance = parseInt(fromBN(await sUSD.balanceOf(trader1.address)))
    //   const endLPBalance = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)))
    //   const maxLossCollateralAfter = parseInt(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));
    //   const optionMarketAfterClose = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

    //   // lp recovers funds 
    //   expect(endLPBalance).to.be.greaterThanOrEqual(startLPBalance);
    //   // max loss posted already but may need to recover fees form user
    //   expect(traderBalance).to.be.greaterThan(traderBalanceBeforeClose);
    //   expect(maxLossCollateralAfter).to.be.eq(toBN('0'));
    //   expect(optionMarketAfterClose).to.be.eq(toBN('0'));

    // });

  });
});

const convertResultToTradeParams = (results: any[]): any[] => {
  return results.map((param: any) => {
    return {
      strikeId: param.strikeId,
      positionId: param.positionId,
      iterations: 1,
      optionType: param.optionType,
      amount: param.amount,
      setCollateralTo: toBN('0'),
      minTotalCost: toBN('0'),
      maxTotalCost: toBN('100000'),
      rewardRecipient: ZERO_ADDRESS,
    }
  })
}

const buildOrderWithQuote = async (
  strikeId: BigNumberish,
  optionType: number,
  amount: BigNumber,
  positionId: number,
): Promise<ITradeTypes.TradeInputParametersStruct> => {

  const quote = await lyraBaseETH.getQuote(
    strikeId,
    1, // iterations
    optionType, // option type
    amount,
    0, // open
    false // is force close
  );

  const maxCostQuote = isLong(optionType) ?
    toBN((parseInt(fromBN(quote.totalPremium.add(quote.totalFee))) * 1.1).toString()) :
    toBN((parseInt(fromBN(quote.totalPremium.add(quote.totalFee))) * .9).toString()); //add slippage

  return {
    strikeId: strikeId,
    positionId: positionId,
    iterations: 1,
    optionType: optionType,
    amount: amount,
    setCollateralTo: toBN('0'),
    minTotalCost: isLong(optionType) ? toBN('0') : maxCostQuote,
    maxTotalCost: isLong(optionType) ? maxCostQuote : MAX_UINT,
    rewardRecipient: ZERO_ADDRESS,
  }
}

const isLong = (optionType: number) => {
  switch (optionType) {
    case 0:
    case 1:
      return true;
    case 3:
    case 4:
      return false;
    default:
      return false;
      break;
  }
}
