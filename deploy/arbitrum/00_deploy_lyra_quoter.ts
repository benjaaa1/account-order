import { HardhatRuntimeEnvironment } from "hardhat/types";
import { targets } from "../../constants/lyra.realPricingMockGmx.json";

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    console.log({ bs: targets.BlackScholes.address })
    await deploy("LyraQuoter", {
        from: deployer,
        args: [
            targets.LyraRegistry.address //lyraGlobal.LyraRegistry.address
        ],
        log: true,
        libraries: {
            BlackScholes: targets.BlackScholes.address
        }
    });

};
module.exports.tags = ["arbitrum"];