import { getGlobalDeploys } from "@lyrafinance/protocol";
import { HardhatRuntimeEnvironment } from "hardhat/types";

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const lyraGlobal = getGlobalDeploys('local');
    console.log({ deployer })
    await deploy("LyraQuoter", {
        from: deployer,
        args: [
            lyraGlobal.LyraRegistry.address
        ],
        log: true,
        libraries: {
            BlackScholes: lyraGlobal.BlackScholes.address
        }
    });

};
module.exports.tags = ["local"];
