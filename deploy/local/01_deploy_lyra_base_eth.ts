import { getMarketDeploys, getGlobalDeploys } from "@lyrafinance/protocol";
import markets from "../../constants/markets.json";
import { ethers } from "hardhat";
import { HardhatRuntimeEnvironment } from "hardhat/types";

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const lyraMarket = getMarketDeploys('local', 'sETH');
    const lyraGlobal = getGlobalDeploys('local');

    const _lyraQuoter = await ethers.getContract('LyraQuoter');

    await deploy("LyraBaseETH", {
        from: deployer,
        contract: 'LyraBase',
        args: [
            markets.ETH,
            lyraGlobal.SynthetixAdapter.address, // synthetix adapter
            lyraMarket.OptionToken.address,
            lyraMarket.OptionMarket.address,
            lyraMarket.LiquidityPool.address,
            lyraMarket.ShortCollateral.address,
            lyraMarket.OptionMarketPricer.address,
            lyraMarket.OptionGreekCache.address,
            lyraMarket.GWAVOracle.address,
            _lyraQuoter.address
        ],
        log: true,
        libraries: {
            BlackScholes: lyraGlobal.BlackScholes.address
        }
    });

};
module.exports.tags = ["local"];
