import { HardhatRuntimeEnvironment } from "hardhat/types";
import { initMarkets } from '../../scripts/init/initOptionMarketContracts';

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const otusVault = (await deployments.get("OtusVault")).address;
    const strategy = (await deployments.get("Strategy")).address;
    const otusManager = (await deployments.get("OtusManager")).address;

    await deploy("OtusFactory", {
        from: deployer,
        args: [otusVault, strategy, otusManager],
        log: true
    });

};
module.exports.tags = ["arbitrum-vault-factory"];