import { getGlobalDeploys, getMarketDeploys, lyraConstants } from "@lyrafinance/protocol";
import { MAX_UINT, ZERO_ADDRESS, fromBN, toBN } from "@lyrafinance/protocol/dist/scripts/util/web3utils";
import { ethers } from "hardhat";
import { ITradeTypes } from "../../typechain-types/contracts/SpreadOptionMarket";
import { BigNumber, BigNumberish } from "ethers";
import { mockPrice } from "@lyrafinance/protocol/dist/test/utils/seedTestSystem";
import { deployTestSystem } from "@lyrafinance/protocol/dist/test/utils/deployTestSystem";
import { DEFAULT_OPTION_MARKET_PARAMS } from "@lyrafinance/protocol/dist/test/utils/defaultParams";

const otusAMMAddr = '0x0dcd1bf9a1b36ce34237eeafef220932846bcd82';

const create = async () => {

  try {

    const [deployer, lyra, , , owner] = await ethers.getSigners();

    let lyraGlobal: any = getGlobalDeploys('local');
    let lyraMarket: any = getMarketDeploys('local', 'sETH');

    const optionMarket = await ethers.getContractAt(lyraMarket.OptionMarket.abi, lyraMarket.OptionMarket.address);
    let liveBoards = await optionMarket.getLiveBoards();
    let boardId = liveBoards[0];
    let strikes = await optionMarket.getBoardStrikes(boardId);

    console.log({
      boardId, strikes
    })
    const otusAMM = await ethers.getContractAt('OtusAMM', otusAMMAddr);

    const MARKET_KEY_ETH = ethers.utils.formatBytes32String("ETH");

    // strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
    // SET ranged market POSITION IN => iron condor or iron butterfly
    const strikeTradesIN: ITradeTypes.TradeInputParametersStruct[] = await buildStrikesIN(strikes, toBN('0'));

    const strikeTradesOUT: ITradeTypes.TradeInputParametersStruct[] = await buildStrikesOUT(strikes, toBN('0'));

    const rangedMarketTx = await otusAMM.connect(deployer).createRangedMarket(MARKET_KEY_ETH, lyraConstants.DAY_SEC * 14, strikeTradesIN, strikeTradesOUT);
    const rc = await rangedMarketTx.wait();

    const event = rc.events?.find(
      (event: { event: string }) => event.event === "NewRangedMarket"
    );
    console.log({ event })

    const rangedMarketInfo = event?.args;

    const rangedMarketInstance = (await ethers.getContractAt(
      "RangedMarket",
      rangedMarketInfo[0]
    ));

    const slippage = toBN('.05');

    const [price2, _strikeTradesOUT2] = await rangedMarketInstance.getOutPricing({
      amount: toBN('1'),
      slippage,
      tradeDirection: 0,
      forceClose: false
    });

    console.log({ price2: fromBN(price2) })

    // const exportAddresses = true;

    // let localTestSystem = await deployTestSystem(lyra, false, exportAddresses, {
    //   mockSNX: true,
    //   compileSNX: false,
    //   optionMarketParams: { ...DEFAULT_OPTION_MARKET_PARAMS, feePortionReserved: toBN('0.05') },
    // });

    // await mockPrice(localTestSystem, toBN('2900'), 'sETH');

    // await lyraMarket.marketActions.mockPrice(localTestSystem, toBN("2800"), 'sETH');

  } catch (error) {
    console.log({ error })
  }

}

async function main() {
  await create();
  console.log("✅ Generate local ranged markets for local testing.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

const buildStrikesIN = async (strikes: Array<BigNumber>, amount: BigNumber): Promise<Array<ITradeTypes.TradeInputParametersStruct>> => {
  // strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],

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


  const strikeTradeOUT1: ITradeTypes.TradeInputParametersStruct = buildOrder(
    strikes[5],
    0,// option type (long call 0),
    toBN('0'),
  );

  // SET ranged market POSITION OUT 
  const strikeTradeOUT2: ITradeTypes.TradeInputParametersStruct = buildOrder(
    strikes[1],
    1,// option type (long put 1),
    toBN('0'),
  );


  return [strikeTradeOUT1, strikeTradeOUT2];
}

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