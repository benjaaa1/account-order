
import hre, { ethers } from 'hardhat';
import { parseUnits } from 'ethers/lib/utils'

export const initSpread = async () => {

  try {

    const quoteAsset = '0x041f37A8DcB578Cbe1dE7ed098fd0FE2B7A79056';// lyraGlobal.QuoteAsset.address;

    const { deployments, getNamedAccounts } = hre;
    const { all } = deployments;

    const [deployer, lyra, , , owner] = await ethers.getSigners();

    const deployed = await all();
    const lyraBaseETH = deployed["LyraBaseETH"];
    const lyraBaseBTC = deployed["LyraBaseBTC"];

    const spreadOptionMarket = deployed["SpreadOptionMarket"];
    const spreadLiquidityPool = deployed["SpreadLiquidityPool"];
    const spreadOptionToken = deployed["SpreadOptionToken"];
    const spreadMaxLossCollateral = deployed["SpreadMaxLossCollateral"];

    const spreadOptionMarketContract = await ethers.getContractAt(spreadOptionMarket.abi, spreadOptionMarket.address);
    const spreadLiquidityPoolContract = await ethers.getContractAt(spreadLiquidityPool.abi, spreadLiquidityPool.address);
    const spreadOptionTokenContract = await ethers.getContractAt(spreadOptionToken.abi, spreadOptionToken.address);
    const spreadMaxLossCollateralContract = await ethers.getContractAt(spreadMaxLossCollateral.abi, spreadMaxLossCollateral.address);

    console.log("✅ Start Init spread market contracts.");

    await spreadOptionMarketContract.connect(deployer).initialize(
      quoteAsset,
      lyraBaseETH.address,
      lyraBaseBTC.address,
      spreadMaxLossCollateral.address,
      spreadOptionToken.address,
      spreadLiquidityPool.address
    );

    await spreadOptionTokenContract.connect(deployer).initialize(
      spreadOptionMarket.address,
      lyraBaseETH.address,
      lyraBaseBTC.address
    );

    await spreadLiquidityPoolContract.connect(deployer).initialize(
      spreadOptionMarket.address,
      quoteAsset
    );

    await spreadLiquidityPoolContract.connect(deployer).setLiquidityPoolParameters({
      minDepositWithdraw: toBN('10'),
      withdrawalDelay: toBN('0'),
      withdrawalFee: toBN('0'),
      guardianDelay: toBN('0'),
      cap: toBN('5000'), // $5,000 usdc
      fee: toBN('0.12'), // 12 % yearly
      guardianMultisig: deployer.address
    });

    await spreadMaxLossCollateralContract.connect(deployer).initialize(
      quoteAsset,
      spreadOptionMarket.address,
      spreadLiquidityPool.address

    );

    console.log("✅ Init spread market contracts.");

  } catch (error) {
    console.log({ error })
  }

}

export const toBN = (val: string) => {
  // multiplier is to handle decimals
  if (val.includes('e')) {
    if (parseFloat(val) > 1) {
      const x = val.split('.')
      {/* @ts-ignore */ }
      const y = x[1].split('e+')
      {/* @ts-ignore */ }
      const exponent = parseFloat(y[1])
      {/* @ts-ignore */ }
      const newVal = x[0] + y[0] + '0'.repeat(exponent - y[0].length)
      console.warn(
        `Warning: toBN of val with exponent, converting to string. (${val}) converted to (${newVal})`
      )
      val = newVal
    } else {
      console.warn(
        `Warning: toBN of val with exponent, converting to float. (${val}) converted to (${parseFloat(
          val
        ).toFixed(18)})`
      )
      val = parseFloat(val).toFixed(18)
    }
    {/* @ts-ignore */ }
  } else if (val.includes('.') && val.split('.')[1].length > 18) {
    console.warn(
      `Warning: toBN of val with more than 18 decimals. Stripping excess. (${val})`
    )
    const x = val.split('.')
    {/* @ts-ignore */ }
    x[1] = x[1].slice(0, 18)
    val = x[0] + '.' + x[1]
  }
  return parseUnits(val, 18)
}
