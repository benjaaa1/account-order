import hre from 'hardhat';
import markets from "../../constants/markets.json";
import { targets } from "../../constants/lyra.realPricingMockGmx.json";


const verify = async () => {

  try {

    const { deployments } = hre;
    const { all } = deployments;

    const deployed = await all();
    const spreadOptionMarket = deployed["SpreadOptionMarket"];
    const spreadLiquidityPool = deployed["SpreadLiquidityPool"];
    const spreadOptionToken = deployed["SpreadOptionToken"];
    const spreadMaxLossCollateral = deployed["SpreadMaxLossCollateral"];
    const otusAMM = deployed["OtusAMM"];
    const rangedMarket = deployed["RangedMarket"];
    const rangedMarketToken = deployed["RangedMarketToken"];
    const positionMarket = deployed["PositionMarket"];

    // spread option market
    await hre.run("verify:verify", {
      address: spreadOptionMarket.address,
      constructorArguments: [],
    })

    // spread liquidity pool
    let LPname = 'Otus Spread Liquidity Pool'
    let LPsymbol = 'OSL'
    await hre.run("verify:verify", {
      address: spreadLiquidityPool.address,
      constructorArguments: [LPname, LPsymbol],
    })

    // // spread option token
    // let name = 'Otus Spread Position';
    // let symbol = 'OSP';

    // await hre.run("verify:verify", {
    //   address: spreadOptionToken.address,
    //   constructorArguments: [name, symbol],
    // })

    // // spread max loss collateral
    // await hre.run("verify:verify", {
    //   address: spreadMaxLossCollateral.address,
    //   constructorArguments: [],
    // })

    // // otus amm
    // await hre.run("verify:verify", {
    //   address: otusAMM.address,
    //   constructorArguments: [],
    // })

    // // ranged market
    // await hre.run("verify:verify", {
    //   address: rangedMarket.address,
    //   constructorArguments: [spreadOptionMarket.address, otusAMM.address],
    // })

    // // ranged market token
    // await hre.run("verify:verify", {
    //   address: rangedMarketToken.address,
    //   constructorArguments: [18], // not used - @dev remove from constructor
    //   libraries: {

    //   }
    // })

    // // position market
    // await hre.run("verify:verify", {
    //   address: positionMarket.address,
    //   constructorArguments: [],
    //   libraries: {

    //   }
    // })

  } catch (error) {
    console.warn({ error });

  }
}

async function main() {
  await verify();
  console.log("✅ Verify Arbitrum .");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
