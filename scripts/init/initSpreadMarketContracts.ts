
import { getGlobalDeploys } from "@lyrafinance/protocol";
import { toBN } from "@lyrafinance/protocol/dist/scripts/util/web3utils";
import hre, { ethers } from 'hardhat';

export const initSpread = async () => {

  try {

    const lyraGlobal = getGlobalDeploys('local'); // mainnet-ovm
    const quoteAsset = lyraGlobal.QuoteAsset.address;

    const { deployments, getNamedAccounts } = hre;
    const { all } = deployments;

    const [deployer, lyra, , , owner] = await ethers.getSigners();


    const deployed = await all();
    const lyraBaseETH = deployed["LyraBaseETH"];
    const lyraBaseBTC = deployed["LyraBaseBTC"];

    const spreadOptionMarket = deployed["SpreadOptionMarket"];
    const spreadLiquidityPool = deployed["SpreadLiquidityPool"];
    const spreadOptionToken = deployed["SpreadOptionToken"];
    const spreadMaxLossCollateral = deployed["SpreadMaxLossCollateral"];

    const spreadOptionMarketContract = await ethers.getContractAt(spreadOptionMarket.abi, spreadOptionMarket.address);
    const spreadLiquidityPoolContract = await ethers.getContractAt(spreadLiquidityPool.abi, spreadLiquidityPool.address);
    const spreadOptionTokenContract = await ethers.getContractAt(spreadOptionToken.abi, spreadOptionToken.address);
    const spreadMaxLossCollateralContract = await ethers.getContractAt(spreadMaxLossCollateral.abi, spreadMaxLossCollateral.address);

    await spreadOptionMarketContract.connect(deployer).initialize(
      quoteAsset,
      lyraBaseETH.address,
      lyraBaseBTC.address,
      spreadMaxLossCollateral.address,
      spreadOptionToken.address,
      spreadLiquidityPool.address
    );

    await spreadOptionTokenContract.connect(deployer).initialize(
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

    console.log("✅ Init spread market contracts.");

  } catch (error) {
    console.log({ error })
  }

}
