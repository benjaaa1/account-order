
import hre, { ethers } from 'hardhat';

export const initOtus = async () => {

  try {

    const quoteAsset = '0x041f37A8DcB578Cbe1dE7ed098fd0FE2B7A79056';

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

    console.log("✅ Start INIT OTUS AMM.");

    console.log({
      otusAMM: otusAMM.address,
      spreadOptionMarket: spreadOptionMarket.address,
      rangedMarket: rangedMarket.address,
      positionMarket: positionMarket.address,
      lyraBaseETH: lyraBaseETH.address,
      lyraBaseBTC: lyraBaseBTC.address
    })

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
