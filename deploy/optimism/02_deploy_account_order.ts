import { HardhatRuntimeEnvironment } from "hardhat/types";

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    await deploy("AccountOrder", {
        from: deployer,
        args: [],
        log: true
    });

};
module.exports.tags = ["AccountOrder"];
