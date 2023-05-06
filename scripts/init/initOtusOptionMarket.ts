import { ZERO_ADDRESS } from '@lyrafinance/protocol/dist/scripts/util/web3utils';
import hre, { ethers } from 'hardhat';

export const initOtusOptionMarket = async () => {

  try {

    const quoteAsset = '0x041f37A8DcB578Cbe1dE7ed098fd0FE2B7A79056';

    const { deployments } = hre;
    const { all } = deployments;

    const [deployer, lyra, , , owner] = await ethers.getSigners();

    const deployed = await all();

    const otusOptionMarket = deployed["OtusOptionMarket"];

    const lyraBaseETH = deployed["LyraBaseETH"];
    const lyraBaseBTC = deployed["LyraBaseBTC"];

    const otusOptionMarketContract = await ethers.getContractAt(otusOptionMarket.abi, otusOptionMarket.address);

    console.log("✅ Start INIT OTUS OPTION MARKET.");

    console.log({
      quoteAsset: quoteAsset,
      lyraBaseETH: lyraBaseETH.address,
      lyraBaseBTC: lyraBaseBTC.address,
      feeCounter: ZERO_ADDRESS
    })

    await otusOptionMarketContract.connect(deployer).initialize(
      quoteAsset,
      lyraBaseETH.address,
      lyraBaseBTC.address,
      ZERO_ADDRESS // feeCounter
    );

    console.log("✅ Init OTUS OPTION MARKET.");

  } catch (error) {
    console.log({ error })
  }

}