import { HardhatRuntimeEnvironment } from "hardhat/types";
import { initMarkets } from '../../scripts/init/initOptionMarketContracts';

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const vault = (await deployments.get("Vault")).address;
    const vaultLifeCycle = (await deployments.get("VaultLifeCycle")).address;
    const otusOptionMarket = (await deployments.get("OtusOptionMarket")).address;

    await deploy("OtusVault", {
        from: deployer,
        args: [],
        log: true,
        libraries: {
            Vault: vault,
            VaultLifeCycle: vaultLifeCycle
        }
    });

    await deploy("Strategy", {
        from: deployer,
        args: [otusOptionMarket],
        log: true
    });

};
module.exports.tags = ["arbitrum-vault"];