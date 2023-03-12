import { getMarketDeploys, getGlobalDeploys } from "@lyrafinance/protocol";
import hre from 'hardhat';
import markets from "../../constants/markets.json";

const _lyraQuoter = "0xa60D490C1984D91AB2E43e5b891b2AB8Ab790752";

const verify = async () => {

  try {

    const lyraMarket = getMarketDeploys('mainnet-ovm', 'sETH');
    const lyraGlobal = getGlobalDeploys('mainnet-ovm');

    const { deployments } = hre;
    const { all } = deployments;

    const deployed = await all();
    const lyraBaseETH = deployed["LyraBaseETH"];

    await hre.run("verify:verify", {
      address: lyraBaseETH.address,
      constructorArguments: [
        markets.ETH,
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
      libraries: {
        BlackScholes: lyraGlobal.BlackScholes.address
      }
    })

  } catch (error) {
    console.warn({ error });

  }
}

async function main() {
  await verify();
  console.log("✅ Simple path test end to end new account => deposit => place order.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
