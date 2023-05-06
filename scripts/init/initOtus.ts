
import hre, { ethers } from 'hardhat';

export const initOtus = async () => {

  try {

    const { deployments } = hre;
    const { all } = deployments;

    const [deployer, lyra, , , owner] = await ethers.getSigners();

    const deployed = await all();
    const otusManager = deployed["OtusManager"];
    const lyraBaseETH = deployed["LyraBaseETH"];
    const lyraBaseBTC = deployed["LyraBaseBTC"];

    const otusManagerContract = await ethers.getContractAt(otusManager.abi, otusManager.address);

    await otusManagerContract.connect(deployer).initialize(
      lyraBaseETH.address,
      lyraBaseBTC.address
    );

    console.log("✅ Init OTUS Manager.");

  } catch (error) {
    console.log({ error })
  }

}
