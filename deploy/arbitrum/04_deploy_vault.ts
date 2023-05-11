import { HardhatRuntimeEnvironment } from "hardhat/types";

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    await deploy("Vault", {
        from: deployer,
        log: true,
    });

    await deploy("VaultLifeCycle", {
        from: deployer,
        log: true,
    });

};
module.exports.tags = ["arbitrum-vault"];