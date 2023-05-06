import { HardhatRuntimeEnvironment } from "hardhat/types";
import { initOtus } from '../../scripts/init/initOtus';
import { ethers } from "hardhat";

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    await deploy("OtusManager", {
        from: deployer,
        args: [],
        log: true
    });

    await initOtus();

};
module.exports.tags = ["arbitrum"];