import { HardhatRuntimeEnvironment } from "hardhat/types";
import { initMarkets } from '../../scripts/init/initOptionMarketContracts';

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    await deploy("OtusOptionMarket", {
        from: deployer,
        args: [],
        log: true
    });

    await deploy("SpreadMarket", {
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

    let name = 'Otus Option Position';
    let symbol = 'OOP';

    await deploy("OtusOptionToken", {
        from: deployer,
        args: [name, symbol],
        log: true
    });

    await deploy("SpreadMaxLossCollateral", {
        from: deployer,
        args: [],
        log: true
    });

    await deploy("MaxLossCalculator", {
        from: deployer,
        args: [],
        log: true
    });

    await deploy("SettlementCalculator", {
        from: deployer,
        args: [],
        log: true
    });

    await initMarkets();

};
module.exports.tags = ["arbitrum"];