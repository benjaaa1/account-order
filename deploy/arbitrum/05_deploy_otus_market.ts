import { HardhatRuntimeEnvironment } from "hardhat/types";
import { initOtusOptionMarket } from '../../scripts/init/initOtusOptionMarket';

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    await deploy("OtusOptionMarket", {
        from: deployer,
        args: [],
        log: true
    });

    await initOtusOptionMarket();

};
module.exports.tags = ["arbitrum"];
