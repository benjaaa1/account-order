import { HardhatRuntimeEnvironment } from "hardhat/types";
import { initSpread } from '../../scripts/init/initSpreadMarketContracts';

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    await deploy("SpreadOptionMarket", {
        from: deployer,
        args: [],
        log: true
    });

    let LPname = 'Otus Spread Liquidity Pool'
    let LPsymbol = 'OSL'

    await deploy("SpreadLiquidityPool", {
        from: deployer,
        args: [LPname, LPsymbol],
        log: true
    });

    let name = 'Otus Spread Position';
    let symbol = 'OSP';

    await deploy("SpreadOptionToken", {
        from: deployer,
        args: [name, symbol],
        log: true
    });

    await deploy("SpreadMaxLossCollateral", {
        from: deployer,
        args: [],
        log: true
    });

    await initSpread();

};
module.exports.tags = ["arbitrum"];
