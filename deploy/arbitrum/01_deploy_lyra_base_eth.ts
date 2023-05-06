import markets from "../../constants/markets.json";
import { ethers } from "hardhat";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { targets } from "../../constants/lyra.realPricingMockGmx.json";

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const _lyraQuoter = await ethers.getContract('LyraQuoter');

    await deploy("LyraBaseETH", {
        from: deployer,
        contract: 'LyraBase',
        args: [
            markets.ETH,
            targets.ExchangeAdapter.address, // synthetix adapter
            targets.markets.wETH.OptionToken.address,
            targets.markets.wETH.OptionMarket.address,
            targets.markets.wETH.LiquidityPool.address,
            targets.markets.wETH.ShortCollateral.address,
            targets.markets.wETH.OptionMarketPricer.address,
            targets.markets.wETH.OptionGreekCache.address,
            targets.markets.wETH.GWAVOracle.address,
            _lyraQuoter.address
        ],
        log: true,
        libraries: {
            BlackScholes: targets.BlackScholes.address
        }
    });

};
module.exports.tags = ["arbitrum"];