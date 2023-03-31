import { getGlobalDeploys } from "@lyrafinance/protocol";
import { ethers } from "hardhat";
import { HardhatRuntimeEnvironment } from "hardhat/types";

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy, all } = deployments;
    const { deployer } = await getNamedAccounts();
    const lyraGlobal = getGlobalDeploys('local');

    const deployed = await all();
    const lyraBaseETH = deployed["LyraBaseETH"];
    const lyraBaseBTC = deployed["LyraBaseBTC"];

    const GELATO_OPS = "0x340759c8346A1E6Ed92035FB8B6ec57cE1D82c2c";

    const accountOrderImpl = await ethers.getContract('AccountOrder');

    await deploy("AccountFactory", {
        from: deployer,
        args: [
            accountOrderImpl.address,
            lyraGlobal.QuoteAsset.address,
            lyraBaseETH.address, // synthetix adapter
            lyraBaseBTC.address,
            GELATO_OPS
        ],
        log: true
    });

};
module.exports.tags = ["local"];
