import { getGlobalDeploys, getMarketDeploys, lyraConstants } from '@lyrafinance/protocol';
import { toBN } from '@lyrafinance/protocol/dist/scripts/util/web3utils';
import { TestSystemContractsType, addNewMarketSystem, deployGlobalTestContracts, deployMarketTestContracts, deployTestSystem } from '@lyrafinance/protocol/dist/test/utils/deployTestSystem';
import { ethers } from 'hardhat';

import { DEFAULT_OPTION_MARKET_PARAMS } from '@lyrafinance/protocol/dist/test/utils/defaultParams';
import { seedNewMarketSystem, seedTestSystem } from '@lyrafinance/protocol/dist/test/utils/seedTestSystem';
import { TestSystemContractsTypeGMX, deployGMXTestSystem } from '@lyrafinance/protocol/dist/test/utils/deployTestSystemGMX';
import { seedTestSystemGMX } from '@lyrafinance/protocol/dist/test/utils/seedTestSystemGMX';

const boardParameterETH = {
  expiresIn: lyraConstants.DAY_SEC * 7,
  baseIV: "0.7",
  strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
  skews: [".9", "1", "1", "1", "1", "1", "1.1"],
};

const boardParameterBTC = {
  expiresIn: lyraConstants.DAY_SEC * 7,
  baseIV: "0.7",
  strikePrices: ["25000", "26000", "27000", "28000", "29000", "30000", "31000"],
  skews: [".9", "1", "1", "1", "1", "1", "1.1"],
};

const spotPriceETH = toBN("2800");
const spotPriceBTC = toBN("28000");

const initialPoolDepositETH = toBN("15000000");
const initialPoolDepositBTC = toBN("15000000");

// run this script using `yarn hardhat run --network local` if running directly from repo (not @lyrafinance/protocol)
// otherwise OZ will think it's deploying to hardhat network and not local
async function main() {
  // 1. get deployer and network
  const [deployer, lyra, , , owner] = await ethers.getSigners();

  const provider = new ethers.providers.JsonRpcProvider();

  provider.getGasPrice = async () => {
    return ethers.BigNumber.from('0');
  };
  provider.estimateGas = async () => {
    return ethers.BigNumber.from(15000000);
  };
  // max limit to prevent run out of gas errors

  // 2. deploy and seed market
  const exportAddresses = true;
  // let localTestSystem23 = await deployGMXTestSystem(lyra, false, exportAddresses, {});

  let localTestSystem = (await deployGMXTestSystem(lyra, false, true, {
    useGMX: true,
    compileGMX: false,
    optionMarketParams: { ...DEFAULT_OPTION_MARKET_PARAMS, feePortionReserved: toBN('0.05') },
  })) as TestSystemContractsTypeGMX;

  // let localTestSystem2 = await deployTestSystem(lyra, false, exportAddresses, {
  //   mockSNX: true,
  //   compileSNX: false,
  //   optionMarketParams: { ...DEFAULT_OPTION_MARKET_PARAMS, feePortionReserved: toBN('0.05') },
  // });

  // await seedTestSystemGM 
  // await seedTestSystem(lyra, localTestSystem, {
  //   initialBoard: boardParameterETH,
  //   initialBasePrice: spotPriceETH,
  //   initialPoolDeposit: initialPoolDepositETH,
  // });

  await seedTestSystemGMX(lyra, localTestSystem, {})

  let ethAddr = localTestSystem.gmx.eth.address;
  let vaultAddr = localTestSystem.gmx.vault.address;
  let usdcAddr = localTestSystem.gmx.USDC.address;

  // 4. get global contracts
  // let lyraGlobal: any = getGlobalDeploys('local');
  // const susd = lyraGlobal.QuoteAsset.address;
  // const susdAbi = lyraGlobal.QuoteAsset.abi;

  // const susdContract = await ethers.getContractAt(susdAbi, susd);
  // await susdContract.connect(lyra).mint(deployer.address, toBN('1000000'));
  // await susdContract.connect(lyra).mint(owner.address, toBN('100000'));
  // // 5. get market contracts
  // let lyraMarket: any = getMarketDeploys('local', 'sETH');
  // console.log('contract name:', lyraMarket.OptionMarket.contractName);
  // console.log('address:', lyraMarket.OptionMarket.address);
  // console.log('bytecode:', lyraMarket.OptionMarket.bytecode.slice(0, 20) + '...');
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
