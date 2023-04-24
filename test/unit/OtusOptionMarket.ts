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
  OtusOptionMarket
} from "../../typechain-types";
import { LyraGlobal } from "@lyrafinance/protocol/dist/test/utils/package/parseFiles";
import { BigNumber, BigNumberish } from "ethers";
import { ITradeTypes } from "../../typechain-types/contracts/SpreadOptionMarket";
import { OptionToken } from "@lyrafinance/protocol/dist/typechain-types";

const MARKET_KEY_ETH = ethers.utils.formatBytes32String("ETH");

let sUSD: MockERC20;
let lyraTestSystem: TestSystemContractsType;
let lyraBaseETH: LyraBase;
let lyraQuoter: LyraQuoter;
let optionToken: OptionToken;

// otus option market contracts
let otusOptionMarket: OtusOptionMarket;

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

  before("deploy spread option market contracts", async () => {

    const OtusOptionMarket = await ethers.getContractFactory("OtusOptionMarket");
    otusOptionMarket = (await OtusOptionMarket.connect(deployer).deploy()) as OtusOptionMarket;

    await otusOptionMarket.connect(deployer).initialize(
      lyraTestSystem.snx.quoteAsset.address,
      lyraBaseETH.address,
      lyraBaseETH.address,
      ZERO_ADDRESS
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
    await sUSD.connect(trader1).approve(otusOptionMarket.address, toBN('182000'));
    await sUSD.connect(trader2).approve(otusOptionMarket.address, toBN('182000'));
  })

  describe("trade combo of strikes", () => {

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
      console.log({ strikes })
    });

    it("should be able to open a simple trade long call", async () => {

      const strikeTrade1: ITradeTypes.TradeInputParametersStruct = await buildOrderWithQuote(
        strikes[2],
        0,// option type (long call 0),
        toBN('3'),
        0
      );

      // const strikeTrade2: ITradeTypes.TradeInputParametersStruct = await buildOrderWithQuote(
      //   strikes[3],
      //   3,// option type (long call 0),
      //   toBN('1'),
      //   0
      // );

      try {
        await otusOptionMarket.connect(trader1).openLyraPosition(MARKET_KEY_ETH, [], [strikeTrade1]);
      } catch (error) {
        console.log({ error })
      }

      const positionsOfOtusMarket = await lyraTestSystem.optionToken.getOwnerPositions(otusOptionMarket.address);
      const positionsOfTrader = await lyraTestSystem.optionToken.getOwnerPositions(trader1.address);

      console.log({
        positionsOfOtusMarket, positionsOfTrader
      })

      const bal = await sUSD.connect(trader1).balanceOf(trader1.address);
      console.log({ bal: fromBN(bal) })

    });


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
