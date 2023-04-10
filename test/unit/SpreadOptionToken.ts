import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  lyraConstants,
  TestSystem,
  getGlobalDeploys,
} from "@lyrafinance/protocol";
import { fromBN, toBN, ZERO_ADDRESS } from "@lyrafinance/protocol/dist/scripts/util/web3utils";
import { DEFAULT_PRICING_PARAMS } from "@lyrafinance/protocol/dist/test/utils/defaultParams";
import { TestSystemContractsType } from "@lyrafinance/protocol/dist/test/utils/deployTestSystem";
import { PricingParametersStruct } from "@lyrafinance/protocol/dist/typechain-types/OptionMarketViewer";
import {
  LyraBase,
  MockERC20,
  SpreadLiquidityPool,
  SpreadOptionMarket,
  SpreadOptionToken,
  SpreadMaxLossCollateral
} from "../../typechain-types";
import { LyraGlobal } from "@lyrafinance/protocol/dist/test/utils/package/parseFiles";

let sUSD: MockERC20;
let lyraTestSystem: TestSystemContractsType;

// spread market contracts
let spreadOptionMarket: SpreadOptionMarket;
let spreadLiquidityPool: SpreadLiquidityPool;
let spreadOptionToken: SpreadOptionToken;
let spreadMaxLossCollateral: SpreadMaxLossCollateral;

let deployer: SignerWithAddress;
let owner: SignerWithAddress;
let depositor1: SignerWithAddress;
let depositor2: SignerWithAddress;
let depositor3: SignerWithAddress;

let lyraGlobal: LyraGlobal;
const boardParameter = {
  expiresIn: lyraConstants.DAY_SEC * 7,
  baseIV: "0.8",
  strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
  skews: ["1.3", "1.2", "1.1", "1", "1.1", "1.3", "1.3"],
};

const spotPrice = toBN("3000");

// 1.5m lyra pool
const initialPoolDeposit = toBN("1500000");

describe("spread option token testing", async () => {

  before("assign roles", async () => {
    [deployer, owner, depositor1, depositor2, depositor3] = await ethers.getSigners();
  });

  before("deploy lyra test", async () => {
    lyraGlobal = getGlobalDeploys("local");

    const pricingParams: PricingParametersStruct = {
      ...DEFAULT_PRICING_PARAMS,
      standardSize: toBN("10"),
      spotPriceFeeCoefficient: toBN("0.001"),
    };

    lyraTestSystem = await TestSystem.deploy(deployer, false, false, { pricingParams });

    await TestSystem.seed(deployer, lyraTestSystem, {
      initialBoard: boardParameter,
      initialBasePrice: spotPrice,
      initialPoolDeposit: initialPoolDeposit,
    });

    sUSD = lyraTestSystem.snx.quoteAsset as MockERC20;

  });

  before("deploy spread margin contracts", async () => {

    const SpreadLiquidityPool = await ethers.getContractFactory("SpreadLiquidityPool");
    let LPname = 'Otus Spread Liquidity Pool'
    let LPsymbol = 'OSL'

    spreadLiquidityPool = (await SpreadLiquidityPool.connect(deployer).deploy(
      LPname,
      LPsymbol
    )) as SpreadLiquidityPool;

    const SpreadOptionMarket = await ethers.getContractFactory("SpreadOptionMarket");
    spreadOptionMarket = (await SpreadOptionMarket.connect(deployer).deploy()) as SpreadOptionMarket;

    const SpreadOptionToken = await ethers.getContractFactory("SpreadOptionToken");
    let _name = 'Otus Spread Position';
    let _symbol = 'OSP';
    spreadOptionToken = (await SpreadOptionToken.connect(deployer).deploy(_name, _symbol)) as SpreadOptionToken;

    const SpreadMaxLossCollateral = await ethers.getContractFactory("SpreadMaxLossCollateral");
    spreadMaxLossCollateral = (await SpreadMaxLossCollateral.connect(deployer).deploy()) as SpreadMaxLossCollateral;

    await spreadOptionMarket.connect(deployer).initialize(
      lyraTestSystem.snx.quoteAsset.address,
      ZERO_ADDRESS,
      ZERO_ADDRESS,
      spreadMaxLossCollateral.address,
      spreadOptionToken.address,
      spreadLiquidityPool.address
    );

    await spreadLiquidityPool.connect(deployer).initialize(
      spreadOptionMarket.address,
      lyraTestSystem.snx.quoteAsset.address
    );

    await spreadOptionToken.connect(deployer).initialize(
      spreadOptionMarket.address,
      ZERO_ADDRESS,
      ZERO_ADDRESS,
    );

    await spreadMaxLossCollateral.connect(deployer).initialize(
      lyraTestSystem.snx.quoteAsset.address,
      spreadOptionMarket.address,
      spreadLiquidityPool.address
    );

  });

  before("mint susd for depositors", async () => {
    await sUSD.mint(depositor1.address, toBN("200"));
    await sUSD.mint(depositor2.address, toBN("100"));
    await sUSD.mint(depositor3.address, toBN("300"));
  });

  describe("", () => {

  })

});
