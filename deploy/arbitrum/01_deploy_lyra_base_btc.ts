import markets from "../../constants/markets.json";
import { ethers } from "hardhat";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { targets } from "../../constants/lyra.realPricingMockGmx.json";

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const _lyraQuoter = await ethers.getContract('LyraQuoter');

    await deploy("LyraBaseBTC", {
        from: deployer,
        contract: 'LyraBase',
        args: [
            markets.BTC,
            targets.ExchangeAdapter.address,
            targets.markets.wBTC.OptionToken.address, // lyraMarket.OptionToken.address, 
            targets.markets.wBTC.OptionMarket.address,
            targets.markets.wBTC.LiquidityPool.address,
            targets.markets.wBTC.ShortCollateral.address,
            targets.markets.wBTC.OptionMarketPricer.address,
            targets.markets.wBTC.OptionGreekCache.address,
            targets.markets.wBTC.GWAVOracle.address,
            _lyraQuoter.address
        ],
        log: true,
        libraries: {
            BlackScholes: targets.BlackScholes.address
        }
    });

};
module.exports.tags = ["arbitrum"];
