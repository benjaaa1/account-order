import hre from 'hardhat';
import markets from "../../constants/markets.json";
import { targets } from "../../constants/lyra.realPricingMockGmx.json";


const verify = async () => {

  try {

    const { deployments } = hre;
    const { all } = deployments;

    const deployed = await all();
    const lyraBaseBTC = deployed["LyraBaseBTC"];
    const lyraQuoter = deployed["LyraQuoter"];
    console.log({ lyraBaseBTC: lyraBaseBTC.address, lyraQuoter: lyraQuoter.address })
    await hre.run("verify:verify", {
      address: lyraBaseBTC.address,
      constructorArguments: [
        markets.BTC,
        targets.ExchangeAdapter.address,
        targets.markets.wBTC.OptionToken.address,
        targets.markets.wBTC.OptionMarket.address,
        targets.markets.wBTC.LiquidityPool.address,
        targets.markets.wBTC.ShortCollateral.address,
        targets.markets.wBTC.OptionMarketPricer.address,
        targets.markets.wBTC.OptionGreekCache.address,
        targets.markets.wBTC.GWAVOracle.address,
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
  console.log("✅ Verify Lyra Base BTC .");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
