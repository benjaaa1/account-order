import { getMarketDeploys, getGlobalDeploys } from "@lyrafinance/protocol";
import markets from "../../constants/markets.json";
import { HardhatRuntimeEnvironment } from "hardhat/types";

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const lyraMarket = getMarketDeploys('mainnet-ovm', 'sBTC');
    const lyraGlobal = getGlobalDeploys('mainnet-ovm');
    // https://github.com/blue-searcher/lyra-quoter
    const _lyraQuoter = "0xa60D490C1984D91AB2E43e5b891b2AB8Ab790752";
    await deploy("LyraBaseBTC", {
        from: deployer,
        contract: 'LyraBase',
        args: [
            markets.BTC,
            lyraGlobal.SynthetixAdapter.address, // synthetix adapter
            lyraMarket.OptionToken.address,
            lyraMarket.OptionMarket.address,
            lyraMarket.LiquidityPool.address,
            lyraMarket.ShortCollateral.address,
            lyraMarket.OptionMarketPricer.address,
            lyraMarket.OptionGreekCache.address,
            lyraMarket.GWAVOracle.address,
            _lyraQuoter
        ],
        log: true,
        libraries: {
            BlackScholes: lyraGlobal.BlackScholes.address
        }
    });

};
module.exports.tags = ["AccountFactory"];
