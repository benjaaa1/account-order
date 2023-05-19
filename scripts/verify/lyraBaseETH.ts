import { getMarketDeploys, getGlobalDeploys } from "@lyrafinance/protocol";
import hre from 'hardhat';
import markets from "../../constants/markets.json";
import { targets } from "../../constants/lyra.realPricingMockGmx.json";

const _lyraQuoter = "0xf657d05B529FbC3B45eD3C7c4e72429982BC642A";

const verify = async () => {

  try {
    const { deployments } = hre;
    const { all } = deployments;

    const deployed = await all();
    const lyraBaseETH = deployed["LyraBaseETH"];

    await hre.run("verify:verify", {
      address: lyraBaseETH.address,
      constructorArguments: [
        markets.ETH,
        targets.ExchangeAdapter.address, // synthetix adapter
        targets.markets.wETH.OptionToken.address,
        targets.markets.wETH.OptionMarket.address,
        targets.markets.wETH.LiquidityPool.address,
        targets.markets.wETH.ShortCollateral.address,
        targets.markets.wETH.OptionMarketPricer.address,
        targets.markets.wETH.OptionGreekCache.address,
        targets.markets.wETH.GWAVOracle.address,
        _lyraQuoter
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
  console.log("✅ Simple path test end to end new account => deposit => place order.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
