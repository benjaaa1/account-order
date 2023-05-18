import { getGlobalDeploys } from "@lyrafinance/protocol";
import { HardhatRuntimeEnvironment } from "hardhat/types";

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts, getChainId } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const lyraGlobal = getGlobalDeploys('goerli-ovm');
    const OPTIMISM_GOERLI_LYRA_REGISTRY = '0x752Ab8bd950afb428Ffa7B91517Cd95A05ab8fF9';

    console.log({ bs: lyraGlobal.BlackScholes.address })
    await deploy("LyraQuoter", {
        from: deployer,
        args: [
            OPTIMISM_GOERLI_LYRA_REGISTRY
        ],
        log: true,
        libraries: {
            BlackScholes: lyraGlobal.BlackScholes.address
        }
    });


};
module.exports.tags = ["optimism-goerli"];
