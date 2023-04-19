import hre from 'hardhat';
import markets from "../../constants/markets.json";
import { targets } from "../../constants/lyra.realPricingMockGmx.json";


const verify = async () => {

  try {

    const { deployments } = hre;
    const { all } = deployments;

    const deployed = await all();
    const lyraBaseETH = deployed["LyraBaseETH"];
    const lyraQuoter = deployed["LyraQuoter"];
    console.log({ lyraBaseETH: lyraBaseETH.address, lyraQuoter: lyraQuoter.address })
    await hre.run("verify:verify", {
      address: lyraBaseETH.address,
      constructorArguments: [
        markets.ETH,
        targets.ExchangeAdapter.address,
        targets.markets.wETH.OptionToken.address,
        targets.markets.wETH.OptionMarket.address,
        targets.markets.wETH.LiquidityPool.address,
        targets.markets.wETH.ShortCollateral.address,
        targets.markets.wETH.OptionMarketPricer.address,
        targets.markets.wETH.OptionGreekCache.address,
        targets.markets.wETH.GWAVOracle.address,
        lyraQuoter.address
      ],
      libraries: {
        BlackScholes: targets.BlackScholes.address
      }
    })

  } catch (error) {
    console.warn({ error });

  }
}

async function main() {
  await verify();
  console.log("✅ Verify Lyra Base ETH .");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
