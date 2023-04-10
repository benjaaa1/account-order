
import { getGlobalDeploys } from "@lyrafinance/protocol";
import { toBN } from "@lyrafinance/protocol/dist/scripts/util/web3utils";
import hre, { ethers } from 'hardhat';

export const initOtus = async () => {

  try {

    const lyraGlobal = getGlobalDeploys('local'); // mainnet-ovm
    const quoteAsset = lyraGlobal.QuoteAsset.address;

    const { deployments } = hre;
    const { all } = deployments;

    const [deployer, lyra, , , owner] = await ethers.getSigners();


    const deployed = await all();

    const otusAMM = deployed["OtusAMM"];
    const spreadOptionMarket = deployed["SpreadOptionMarket"];
    const rangedMarket = deployed["RangedMarket"];
    const rangedMarketToken = deployed["RangedMarketToken"];
    const positionMarket = deployed["PositionMarket"];
    const lyraBaseETH = deployed["LyraBaseETH"];
    const lyraBaseBTC = deployed["LyraBaseBTC"];

    const otusAMMContract = await ethers.getContractAt(otusAMM.abi, otusAMM.address);

    await otusAMMContract.connect(deployer).initialize(
      spreadOptionMarket.address,
      quoteAsset,
      positionMarket.address,
      rangedMarket.address,
      rangedMarketToken.address,
      lyraBaseETH.address,
      lyraBaseBTC.address
    );

    console.log("✅ Init OTUS AMM.");

  } catch (error) {
    console.log({ error })
  }

}
