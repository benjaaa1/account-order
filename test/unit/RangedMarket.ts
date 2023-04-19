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
import { DEFAULT_OPTION_MARKET_PARAMS, DEFAULT_PRICING_PARAMS } from "@lyrafinance/protocol/dist/test/utils/defaultParams";
import { TestSystemContractsType } from "@lyrafinance/protocol/dist/test/utils/deployTestSystem";
import { PricingParametersStruct } from "@lyrafinance/protocol/dist/typechain-types/OptionMarketViewer";
import {
  LyraBase,
  LyraQuoter,
  MockERC20,
  OtusAMM,
  PositionMarket,
  RangedMarket,
  RangedMarketToken,
  SpreadLiquidityPool,
  SpreadMaxLossCollateral,
  SpreadOptionMarket,
  SpreadOptionToken
} from "../../typechain-types";
import { LyraGlobal } from "@lyrafinance/protocol/dist/test/utils/package/parseFiles";
import { BigNumber, BigNumberish } from "ethers";
import { ITradeTypes } from "../../typechain-types/contracts/SpreadOptionMarket";
import { Address } from "hardhat-deploy/types";

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
let rangedMarket: RangedMarket;
let rangedMarketToken: RangedMarketToken;
let otusAMM: OtusAMM;
let positionMarket: PositionMarket;
let rangedMarketInstance: RangedMarket;

let deployer: SignerWithAddress;
let owner: SignerWithAddress;
let lyra: SignerWithAddress;

let depositor1: SignerWithAddress;
let depositor2: SignerWithAddress;
let depositor3: SignerWithAddress;
let trader1: SignerWithAddress;
let trader2: SignerWithAddress;

let lyraGlobal: LyraGlobal;

const boardParameter = {
  expiresIn: lyraConstants.DAY_SEC * 7,
  baseIV: "0.7",
  strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
  skews: [".9", "1", "1", "1", "1", "1", "1.1"],
};

const spotPrice = toBN("2800");
const initialPoolDeposit = toBN("15000000");

describe("ranged market", async () => {

  before("assign roles", async () => {
    [deployer, lyra, owner, depositor1, depositor2, depositor3, trader1, trader2] = await ethers.getSigners();
  });

  before("deploy lyra test", async () => {
    lyraGlobal = getGlobalDeploys("local");

    lyraTestSystem = await TestSystem.deploy(lyra, false, false, {
      mockSNX: true,
      compileSNX: false,
      optionMarketParams: { ...DEFAULT_OPTION_MARKET_PARAMS, feePortionReserved: toBN('0.05') },
    });

    await TestSystem.seed(lyra, lyraTestSystem, {
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

    const OtusAMM = await ethers.getContractFactory("OtusAMM");
    otusAMM = (await OtusAMM.connect(deployer).deploy()) as OtusAMM;

    const RangedMarket = await ethers.getContractFactory("RangedMarket");
    rangedMarket = (await RangedMarket.connect(deployer).deploy(spreadOptionMarket.address, otusAMM.address)) as RangedMarket;

    const RangedMarketToken = await ethers.getContractFactory("RangedMarketToken");
    rangedMarketToken = (await RangedMarketToken.connect(deployer).deploy(18)) as RangedMarketToken;

    const PositionMarket = await ethers.getContractFactory("PositionMarket");
    positionMarket = (await PositionMarket.connect(deployer).deploy()) as PositionMarket;

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

    await otusAMM.connect(deployer).initialize(
      spreadOptionMarket.address,
      lyraTestSystem.snx.quoteAsset.address,
      positionMarket.address,
      rangedMarket.address,
      rangedMarketToken.address,
      lyraBaseETH.address,
      lyraBaseETH.address,
    );

  });

  before("mint susd for depositors", async () => {
    await sUSD.mint(depositor1.address, toBN("40000"));
    await sUSD.mint(depositor2.address, toBN("64000"));
    await sUSD.mint(depositor3.address, toBN("70000"));
  });

  before("mint susd for traders", async () => {
    await sUSD.mint(trader1.address, toBN("200"));
    await sUSD.mint(trader2.address, toBN("200"));
  });

  before("approve option market for traders", async () => {
    await sUSD.connect(trader1).approve(spreadOptionMarket.address, toBN('200'));
    await sUSD.connect(trader2).approve(spreadOptionMarket.address, toBN('200'));
  })

  describe("deposit into lp and attempt to trade in ranged maret token", () => {

    let startLPBalance = 0;
    let boardId = toBN("0");
    let strikes: BigNumber[] = [];
    let rangedMarketInfo: Address[] = [];

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

    it("should be able to INIT and SET a simple range market 1 iron butterfly (ranged market in)", async () => {

      // strikePrices: ["2700", ""2800", "2900", "3000", "3100", "3200", "3300"],
      // SET ranged market POSITION IN => iron condor or iron butterfly
      const strikeTradesIN: ITradeTypes.TradeInputParametersStruct[] = await buildStrikesIN(strikes, toBN('0'));

      const strikeTradesOUT: ITradeTypes.TradeInputParametersStruct[] = await buildStrikesOUT(strikes, toBN('0'));

      const rangedMarketTx = await otusAMM.connect(owner).createRangedMarket(MARKET_KEY_ETH, boardParameter.expiresIn, strikeTradesIN, strikeTradesOUT);
      const rc = await rangedMarketTx.wait();


      const lyraBase = await otusAMM.lyraBase(MARKET_KEY_ETH);

      const event = rc.events?.find(
        (event: { event: string }) => event.event === "NewRangedMarket"
      );

      rangedMarketInfo = event?.args;

      rangedMarketInstance = (await ethers.getContractAt(
        "RangedMarket",
        rangedMarketInfo[0]
      )) as RangedMarket;

      // pricing
      const amount = toBN('1');
      const slippage = toBN('.05');
      // get in pricing buy - 
      const [price, _strikeTradesIN] = await rangedMarketInstance.getInPricing({
        amount,
        slippage,
        tradeDirection: 0,
        forceClose: false
      });

      console.log({ price: fromBN(price) })

      // // get in pricing sell 
      console.log({
        premium: fromBN('69027297380006241855'),
        premium1: fromBN('10838059583964023064'),
        premium02: fromBN('61754928978171323474'),
        premium12: fromBN('3871651535724033022')
      })
      const [price1, _strikeTradesIN1] = await rangedMarketInstance.getInPricing({
        amount,
        slippage,
        tradeDirection: 1,
        forceClose: false
      });

      console.log({ price1: fromBN(price1) })

      // get out pricing buy
      const [price2, _strikeTradesOUT2] = await rangedMarketInstance.getOutPricing({
        amount: toBN('1'),
        slippage,
        tradeDirection: 0,
        forceClose: false
      });

      console.log({ price2: fromBN(price2) })
      // get out pricing sell 
      // get out pricing buy
      const [price3, _strikeTradesOUT3] = await rangedMarketInstance.getOutPricing({
        amount: toBN('1'),
        slippage,
        tradeDirection: 1,
        forceClose: false
      });

      console.log({ price3: fromBN(price3) })
    });

    it("trader 1 should be able to buy a minimum set amount", async () => {

      const optionMarketBalanceBeforeTrade = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      rangedMarketInstance = (await ethers.getContractAt(
        "RangedMarket",
        rangedMarketInfo[0]
      )) as RangedMarket;

      const inRange = 0;
      const slippage = .05;
      const amount = toBN('.5');

      const [price, strikeTradesIN] = await rangedMarketInstance.getInPricing({
        amount,
        slippage: toBN(slippage.toString()),
        tradeDirection: 0,
        forceClose: false
      });

      // approve in market
      await sUSD.connect(trader1).approve(rangedMarketInfo[3], price);

      await otusAMM.connect(trader1).buy(
        inRange,
        rangedMarketInfo[0],
        amount,
        price,
        strikeTradesIN
      );

      const endLPBalance = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)))

      const optionMarketBalanceAfterTrade = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      const maxLossCollateralAfter = parseInt(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));

      expect(optionMarketBalanceAfterTrade).to.be.eq(optionMarketBalanceBeforeTrade);
      expect(maxLossCollateralAfter).to.be.greaterThan(0);

      expect(endLPBalance).to.be.lessThan(startLPBalance);

    })

    it("trader 1 should be able to sell part of IN tokens previous amount", async () => {

      // the final bit can be taken from traders profit
      rangedMarketInstance = (await ethers.getContractAt(
        "RangedMarket",
        rangedMarketInfo[0]
      )) as RangedMarket;

      const inRange = 0;
      const slippage = .043;
      const amount1 = toBN('.31');

      const [price1, strikeTradesINSells1] = await rangedMarketInstance.getInPricing({
        amount: amount1,
        slippage: toBN(slippage.toString()),
        tradeDirection: 1,
        forceClose: false
      });

      const [price1Open, strikeTradesIN1] = await rangedMarketInstance.getInPricing({
        amount: amount1,
        slippage: toBN(slippage.toString()),
        tradeDirection: 0,
        forceClose: false
      });

      // commented out to find the last max loss collateral balance origin
      await otusAMM.connect(trader1).sell(inRange, rangedMarketInfo[0], amount1, price1, strikeTradesINSells1);

    })

    it("trader 2 should be able to buy a minimum set amount", async () => {

      const optionMarketBalanceBeforeTrade = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      rangedMarketInstance = (await ethers.getContractAt(
        "RangedMarket",
        rangedMarketInfo[0]
      )) as RangedMarket;

      const inRange = 0;
      const slippage = .015;
      const amount = toBN('.1');

      const [price, strikeTradesIN] = await rangedMarketInstance.getInPricing({
        amount,
        slippage: toBN(slippage.toString()),
        tradeDirection: 0,
        forceClose: false
      });

      // approve the position market for trader - IN
      await sUSD.connect(trader2).approve(rangedMarketInfo[3], price);

      await otusAMM.connect(trader2).buy(
        inRange,
        rangedMarketInfo[0],
        amount,
        price,
        strikeTradesIN
      );

      const endLPBalance = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)))
      const optionMarketBalanceAfterTrade = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));
      const maxLossCollateralAfter = parseInt(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));

      expect(optionMarketBalanceAfterTrade).to.be.eq(optionMarketBalanceBeforeTrade);
      expect(maxLossCollateralAfter).to.be.greaterThan(0);
      expect(endLPBalance).to.be.lessThan(startLPBalance);

    })

    it("should settle positions on lyra / spread market return profits to trader and burn token", async () => {

      const trader1BalanceBeforeSettelement = parseInt(fromBN(await sUSD.balanceOf(trader1.address)));

      const trader2BalanceBeforeSettelement = parseInt(fromBN(await sUSD.balanceOf(trader2.address)));

      // Wait till board expires
      await lyraEvm.fastForward(lyraConstants.MONTH_SEC);

      // Mock sETH price
      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("2800"), 'sETH');

      const totalPositions = (await lyraTestSystem.optionToken.nextId()).sub(1).toNumber();

      const lpBalanceBeforeSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)));
      const optionMarketBalanceBeforeSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      const idsToSettle = Array.from({ length: totalPositions }, (_, i) => i + 1); // create array of [1... totalPositions]
      await lyraTestSystem.optionMarket.settleExpiredBoard(boardId);

      await lyraTestSystem.shortCollateral.settleOptions(idsToSettle);

      const positionIds = await spreadOptionToken.getPositionIds();

      await spreadOptionMarket.settleOption(positionIds[0]);

      await rangedMarketInstance.connect(trader1).exerciseRangedPositions();
      await rangedMarketInstance.connect(trader2).exerciseRangedPositions();

      const rangedMarketInstanceBalance = parseInt(fromBN(await sUSD.balanceOf(rangedMarketInstance.address)));

      const lpBalanceAfterSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)));
      const optionMarketAfterOtusSpreadSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));
      const trader1BalanceAfterSettelement = parseInt(fromBN(await sUSD.balanceOf(trader1.address)));
      const trader2BalanceAfterSettelement = parseInt(fromBN(await sUSD.balanceOf(trader2.address)));

      const maxLossCollateralAfter = parseInt(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));

      expect(maxLossCollateralAfter).to.be.eq(0);

      expect(lpBalanceAfterSettlement).to.be.greaterThanOrEqual(startLPBalance);
      expect(lpBalanceAfterSettlement).to.be.greaterThanOrEqual(lpBalanceBeforeSettlement);
      expect(optionMarketAfterOtusSpreadSettlement).to.be.eq(optionMarketBalanceBeforeSettlement);

    })

  });

  describe("should be able to INIT and SET a simple range market 1 buy put and 1 buy call (ranged in)", () => {

    let startLPBalance = 0;
    let boardId = toBN("0");
    let strikes: BigNumber[] = [];
    let rangedMarketInfo: Address[] = [];

    before("init board", async () => {

      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("2800"), 'sETH');

      await TestSystem.marketActions.createBoard(lyraTestSystem, {
        expiresIn: lyraConstants.DAY_SEC * 28,
        baseIV: "0.9",
        strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
        skews: ["1.3", "1.2", "1.1", "1", "1.1", "1.2", "1.3"],
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

      startLPBalance = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)))

    });

    it("should be able to INIT and SET a simple range market 1 buy put and 1 buy call - out", async () => {

      // strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
      // SET ranged market POSITION IN => iron condor or iron butterfly
      const strikeTradeIN1: ITradeTypes.TradeInputParametersStruct = buildOrder(
        strikes[5],
        0,// option type (long call 0),
        toBN('0'),
      );

      const strikeTradeIN2: ITradeTypes.TradeInputParametersStruct = buildOrder(
        strikes[1],
        1,// option type (long put 0),
        toBN('0'),
      );

      const strikeTradeIN3: ITradeTypes.TradeInputParametersStruct = buildOrder(
        strikes[3],
        3,// option type (short call),
        toBN('0'),
      );

      const strikeTradeIN4: ITradeTypes.TradeInputParametersStruct = buildOrder(
        strikes[3],
        4,// option type (short put 0),
        toBN('0'),
      );

      // SET ranged market POSITION OUT 
      const strikeTradeOUT1: ITradeTypes.TradeInputParametersStruct = buildOrder(
        strikes[1],
        1,// option type (long put 1),
        toBN('0'),
      );

      const strikeTradeOUT2: ITradeTypes.TradeInputParametersStruct = buildOrder(
        strikes[5],
        0,// option type (long call 0),
        toBN('0'),
      );

      const strikeTradesIN: ITradeTypes.TradeInputParametersStruct[] = [strikeTradeIN1, strikeTradeIN2, strikeTradeIN3, strikeTradeIN4];

      const strikeTradesOUT: ITradeTypes.TradeInputParametersStruct[] = [strikeTradeOUT1, strikeTradeOUT2];

      const rangedMarketTx = await otusAMM.connect(owner).createRangedMarket(MARKET_KEY_ETH, boardParameter.expiresIn, strikeTradesIN, strikeTradesOUT);
      const rc = await rangedMarketTx.wait();

      const event = rc.events?.find(
        (event: { event: string }) => event.event === "NewRangedMarket"
      );

      rangedMarketInfo = event?.args;

    });

    it("trader 1 should be able to buy a minimum set amount - out", async () => {

      const maxLossCollateralBefore = parseFloat(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));


      expect(maxLossCollateralBefore).to.be.eq(0);

      const trader1BalanceBeforeBuy = parseInt(fromBN(await sUSD.balanceOf(trader1.address)));

      const optionMarketBalanceBeforeTrade = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      rangedMarketInstance = (await ethers.getContractAt(
        "RangedMarket",
        rangedMarketInfo[0]
      )) as RangedMarket;

      const inRange = 1;
      const slippage = .01;
      const amount = toBN('.21');

      const [price, strikeTradesOUT] = await rangedMarketInstance.getOutPricing({
        amount,
        slippage: toBN(slippage.toString()),
        tradeDirection: 0,
        forceClose: false
      });

      // approve OUT market
      await sUSD.connect(trader1).approve(rangedMarketInfo[4], price);

      await otusAMM.connect(trader1).buy(
        inRange,
        rangedMarketInfo[0],
        amount,
        price,
        strikeTradesOUT
      );

      const endLPBalance = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)))

      const optionMarketBalanceAfterTrade = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      const maxLossCollateralAfter = parseFloat(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));
      // expect(maxLossCollateralAfter).to.be.eq(0);

      expect(optionMarketBalanceAfterTrade).to.be.eq(optionMarketBalanceBeforeTrade);
      expect(endLPBalance).to.be.eq(startLPBalance);

    })

    it("trader 1 should be able to sell part of OUT tokens previous amount", async () => {

      // this is considered an increase 
      // need to set the lyra position ids on the ranged market side after the first trade 
      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("3160"), 'sETH');

      const trader1BalanceBefore = parseInt(fromBN(await sUSD.balanceOf(trader1.address)));

      const optionMarketBalanceBeforeTrade = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      rangedMarketInstance = (await ethers.getContractAt(
        "RangedMarket",
        rangedMarketInfo[0]
      )) as RangedMarket;

      const inRange = 1;
      const slippage = .02;
      const amount1 = toBN('.02');

      const [price1, strikeTradesOUTSells1] = await rangedMarketInstance.getOutPricing({
        amount: amount1,
        slippage: toBN(slippage.toString()),
        tradeDirection: 1,
        forceClose: false
      });

      await otusAMM.connect(trader1).sell(inRange, rangedMarketInfo[0], amount1, price1, strikeTradesOUTSells1);

      const amount2 = toBN('.05');

      const [price2, strikeTradesOUTSells2] = await rangedMarketInstance.getOutPricing({
        amount: amount2,
        slippage: toBN(slippage.toString()),
        tradeDirection: 1,
        forceClose: false
      });

      await otusAMM.connect(trader1).sell(inRange, rangedMarketInfo[0], amount2, price2, strikeTradesOUTSells2);

      const endLPBalance = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)))
      const optionMarketBalanceAfterTrade = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));
      const positionMarketBalanceAfter = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));
      const trader1Balance = parseInt(fromBN(await sUSD.balanceOf(trader1.address)));

      const maxLossCollateralAfter = parseInt(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));
      // expect(maxLossCollateralAfter).to.be.eq(0);

      expect(optionMarketBalanceAfterTrade).to.be.eq(optionMarketBalanceBeforeTrade);
      expect(endLPBalance).to.be.eq(startLPBalance);
      expect(positionMarketBalanceAfter).to.be.eq(0);
      expect(trader1BalanceBefore).to.be.lessThan(trader1Balance);

    })

    it("should settle positions on lyra / spread market return profits to trader and burn token", async () => {
      const trader1BalanceBeforeSettelement = parseInt(fromBN(await sUSD.balanceOf(trader1.address)));

      // Wait till board expires
      await lyraEvm.fastForward(lyraConstants.MONTH_SEC);

      // Mock sETH price
      await TestSystem.marketActions.mockPrice(lyraTestSystem, toBN("2800"), 'sETH');

      const totalPositions = (await lyraTestSystem.optionToken.nextId()).sub(1).toNumber();

      const lpBalanceBeforeSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)));
      const optionMarketBalanceBeforeSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));

      await lyraTestSystem.optionMarket.settleExpiredBoard(boardId);

      await lyraTestSystem.shortCollateral.settleOptions([5, 6]);

      const positionIds = await spreadOptionToken.getPositionIds();

      await spreadOptionMarket.settleOption(positionIds[0]);

      await rangedMarketInstance.connect(trader1).exerciseRangedPositions();

      const lpBalanceAfterSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadLiquidityPool.address)));
      const optionMarketAfterOtusSpreadSettlement = parseInt(fromBN(await sUSD.balanceOf(spreadOptionMarket.address)));
      const trader1BalanceAfterSettelement = parseInt(fromBN(await sUSD.balanceOf(trader1.address)));

      const maxLossCollateralAfter = parseInt(fromBN(await sUSD.balanceOf(spreadMaxLossCollateral.address)));
      expect(maxLossCollateralAfter).to.be.eq(0);
      expect(lpBalanceAfterSettlement).to.be.greaterThanOrEqual(startLPBalance);
      expect(lpBalanceAfterSettlement).to.be.greaterThanOrEqual(lpBalanceBeforeSettlement);
      expect(optionMarketAfterOtusSpreadSettlement).to.be.eq(optionMarketBalanceBeforeSettlement);

    })

  });

});

const buildOrder = (
  strikeId: BigNumberish,
  optionType: number,
  amount: BigNumber
): ITradeTypes.TradeInputParametersStruct => {

  return {
    strikeId: strikeId,
    positionId: 0,
    iterations: 1,
    optionType: optionType,
    amount: amount,
    setCollateralTo: toBN('0'),
    minTotalCost: toBN('0'),
    maxTotalCost: MAX_UINT,
    rewardRecipient: ZERO_ADDRESS,
  }

}

const buildStrikesIN = async (strikes: Array<BigNumber>, amount: BigNumber): Promise<Array<ITradeTypes.TradeInputParametersStruct>> => {

  const strikeTradeIN1: ITradeTypes.TradeInputParametersStruct = buildOrder(
    strikes[5],
    0,// option type (long call 0),
    amount,
  );

  const strikeTradeIN2: ITradeTypes.TradeInputParametersStruct = buildOrder(
    strikes[1],
    1,// option type (long put 0),
    amount,
  );

  const strikeTradeIN3: ITradeTypes.TradeInputParametersStruct = buildOrder(
    strikes[3],
    3,// option type (short call),
    amount,
  );

  const strikeTradeIN4: ITradeTypes.TradeInputParametersStruct = buildOrder(
    strikes[3],
    4,// option type (short put 0),
    amount,
  );

  return [strikeTradeIN1, strikeTradeIN2, strikeTradeIN3, strikeTradeIN4];
}

const buildStrikesOUT = async (strikes: Array<BigNumber>, amount: BigNumber): Promise<Array<ITradeTypes.TradeInputParametersStruct>> => {

  // SET ranged market POSITION OUT 
  // SET ranged market POSITION OUT 
  const strikeTradeOUT1: ITradeTypes.TradeInputParametersStruct = buildOrder(
    strikes[1],
    1,// option type (long put 1),
    toBN('0'),
  );

  const strikeTradeOUT2: ITradeTypes.TradeInputParametersStruct = buildOrder(
    strikes[5],
    0,// option type (long call 0),
    toBN('0'),
  );


  return [strikeTradeOUT1, strikeTradeOUT2];
}

const isLong = (optionType: BigNumberish | Promise<BigNumberish>) => {
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
