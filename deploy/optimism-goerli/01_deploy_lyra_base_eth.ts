import { getGlobalDeploys } from "@lyrafinance/protocol";
import markets from "../../constants/markets.json";
import { HardhatRuntimeEnvironment } from "hardhat/types";

module.exports = async (hre: HardhatRuntimeEnvironment) => {
    const { deployments, getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    console.log({ deployer })
    const lyraGlobal = getGlobalDeploys('mainnet-ovm');

    const { deploy, all } = deployments;

    const deployed = await all();

    const lyraQuoter = deployed["LyraQuoter"];

    const OPTIMISM_GOERLI_EXCHANGE_ADAPTER = '0x3581DcAb9f570F1f47B6A5395CAC428E159a8779';
    const OPTIMISM_GOERLI_OPTION_TOKEN = '0x06C182F91f607bD1F0c7A1df1bA658002a5eafAB';
    const OPTIMISM_GOERLI_OPTION_MARKET = '0x4879E2720FEC3b24c3c0D923423BCD3781aa6314';
    const OPTIMISM_GOERLI_LIQUIDITY_POOL = '0xf4A56e64bAb72032A59466a9873464EfE0E76c75';
    const OPTIMISM_GOERLI_SHORT_COLLATERAL = '0xB9c59D09daf7fe51263dCb5fb86659B2e638427B';
    const OPTIMISM_GOERLI_OPTION_MARKET_PRICER = '0xadfe15EBF7f3485BbAFa31BAA4b15d4042362D53';
    const OPTIMISM_GOERLI_OPTION_GREEK_CACHE = '0xAF8FB3BAe848d285cd67fD695633b0212913E11E';
    const OPTIMISM_GOERLI_GWAV_ORACLE = '0x3f21fD7d908bFF85510Ed1E03Cda14374E59D550';

    await deploy("LyraBaseETH", {
        from: deployer,
        contract: 'LyraBase',
        args: [
            markets.ETH,
            OPTIMISM_GOERLI_EXCHANGE_ADAPTER, // synthetix adapter
            OPTIMISM_GOERLI_OPTION_TOKEN,
            OPTIMISM_GOERLI_OPTION_MARKET,
            OPTIMISM_GOERLI_LIQUIDITY_POOL,
            OPTIMISM_GOERLI_SHORT_COLLATERAL,
            OPTIMISM_GOERLI_OPTION_MARKET_PRICER,
            OPTIMISM_GOERLI_OPTION_GREEK_CACHE,
            OPTIMISM_GOERLI_GWAV_ORACLE,
            lyraQuoter.address
        ],
        log: true,
        libraries: {
            BlackScholes: lyraGlobal.BlackScholes.address
        }
    });

};

module.exports.tags = ["optimism-goerli"];