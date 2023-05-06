
import { ZERO_ADDRESS, toBN } from "@lyrafinance/protocol/dist/scripts/util/web3utils";
import hre, { ethers } from 'hardhat';

export const initMarkets = async () => {

  try {

    const quoteAsset = '0x041f37A8DcB578Cbe1dE7ed098fd0FE2B7A79056';// lyraGlobal.QuoteAsset.address;

    const { deployments, getNamedAccounts } = hre;
    const { all } = deployments;

    const [deployer, lyra, , , owner] = await ethers.getSigners();


    const deployed = await all();
    const lyraBaseETH = deployed["LyraBaseETH"];
    const lyraBaseBTC = deployed["LyraBaseBTC"];

    const otusManager = deployed["OtusManager"];
    const otusOptionMarket = deployed["OtusOptionMarket"];
    const spreadOptionMarket = deployed["SpreadMarket"];
    const spreadLiquidityPool = deployed["SpreadLiquidityPool"];
    const spreadMaxLossCollateral = deployed["SpreadMaxLossCollateral"];

    const otusOptionToken = deployed["OtusOptionToken"];
    const maxLossCalculator = deployed["MaxLossCalculator"];
    const settlementCalculator = deployed["SettlementCalculator"];

    const otusOptionMarketContract = await ethers.getContractAt(otusOptionMarket.abi, otusOptionMarket.address);
    const spreadOptionMarketContract = await ethers.getContractAt(spreadOptionMarket.abi, spreadOptionMarket.address);
    const spreadLiquidityPoolContract = await ethers.getContractAt(spreadLiquidityPool.abi, spreadLiquidityPool.address);
    const otusOptionTokenContract = await ethers.getContractAt(otusOptionToken.abi, otusOptionToken.address);
    const spreadMaxLossCollateralContract = await ethers.getContractAt(spreadMaxLossCollateral.abi, spreadMaxLossCollateral.address);

    await otusOptionMarketContract.connect(deployer).initialize(
      otusManager.address,
      quoteAsset,
      lyraBaseETH.address,
      lyraBaseBTC.address,
      ZERO_ADDRESS,
      otusOptionToken.address,
      settlementCalculator.address
    );

    await spreadOptionMarketContract.connect(deployer).initialize(
      otusManager.address,
      quoteAsset,
      lyraBaseETH.address,
      lyraBaseBTC.address,
      spreadMaxLossCollateral.address,
      otusOptionToken.address,
      spreadLiquidityPool.address,
      maxLossCalculator.address,
      settlementCalculator.address
    );

    await otusOptionTokenContract.connect(deployer).initialize(
      otusOptionMarket.address,
      spreadOptionMarket.address,
      lyraBaseETH.address,
      lyraBaseBTC.address
    );

    await spreadLiquidityPoolContract.connect(deployer).initialize(
      spreadOptionMarket.address,
      quoteAsset
    );

    await spreadLiquidityPoolContract.connect(deployer).setLiquidityPoolParameters({
      minDepositWithdraw: toBN('10'),
      withdrawalDelay: toBN('0'),
      withdrawalFee: toBN('0'),
      guardianDelay: toBN('0'),
      cap: toBN('5000'), // $5,000 usd
      fee: toBN('0.12'), // 12 % yearly
      guardianMultisig: deployer.address
    });

    await spreadMaxLossCollateralContract.connect(deployer).initialize(
      quoteAsset,
      spreadOptionMarket.address,
      spreadLiquidityPool.address

    );

    console.log("✅ Init market contracts.");

  } catch (error) {
    console.log({ error })
  }

}
