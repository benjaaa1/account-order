import { HardhatRuntimeEnvironment } from "hardhat/types";
import { initOtus } from '../../scripts/init/initOtusAMM';
import { ethers } from "hardhat";

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    await deploy("OtusAMM", {
        from: deployer,
        args: [],
        log: true
    });

    const spreadOptionMarket = await ethers.getContract('SpreadOptionMarket');

    const otusAMM = await ethers.getContract('OtusAMM');

    await deploy("RangedMarket", {
        from: deployer,
        args: [spreadOptionMarket.address, otusAMM.address],
        log: true
    });

    await deploy("RangedMarketToken", {
        from: deployer,
        args: [18], // decimals
        log: true
    });

    await deploy("PositionMarket", {
        from: deployer,
        args: [],
        log: true
    });

    await initOtus();

};
module.exports.tags = ["arbitrum"];
