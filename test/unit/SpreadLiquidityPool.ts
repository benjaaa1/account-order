import { expect } from "chai";
import hre from "hardhat";
const { ethers } = hre;
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  lyraConstants,
  TestSystem,
  getGlobalDeploys,
} from "@lyrafinance/protocol";
import { DAY_SEC, fromBN, MONTH_SEC, toBN, YEAR_SEC, ZERO_ADDRESS } from "@lyrafinance/protocol/dist/scripts/util/web3utils";
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
import { impersonateAccount, time } from "@nomicfoundation/hardhat-network-helpers";

let sUSD: MockERC20;
let lyraTestSystem: TestSystemContractsType;

// spread market contracts
let spreadOptionMarket: SpreadOptionMarket;
let spreadLiquidityPool: SpreadLiquidityPool;
let spreadOptionToken: SpreadOptionToken;
let spreadMaxLossCollateral: SpreadMaxLossCollateral;

let deployer: SignerWithAddress;
let guardian: SignerWithAddress;
let depositor1: SignerWithAddress;
let depositor2: SignerWithAddress;
let depositor3: SignerWithAddress;
let trader1: SignerWithAddress;

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

describe("liquidity pool testing", async () => {

  before("assign roles", async () => {
    [deployer, guardian, depositor1, depositor2, depositor3, trader1] = await ethers.getSigners();
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
    await sUSD.mint(depositor1.address, toBN("3000"));
    await sUSD.mint(depositor2.address, toBN("1000"));
    await sUSD.mint(depositor3.address, toBN("3000"));
    await sUSD.mint(trader1.address, toBN("1000"));

  });

  describe("deposit to liquidity pool and get lp tokens", () => {

    it("deposits immediately for first depositor", async () => {
      await sUSD.connect(depositor1).approve(spreadLiquidityPool.address, toBN('3000'));
      await spreadLiquidityPool.connect(depositor1).initiateDeposit(depositor1.address, toBN('1000'));
      expect(await sUSD.balanceOf(spreadLiquidityPool.address)).to.be.eq(toBN('1000'));
      expect(await spreadLiquidityPool.balanceOf(depositor1.address)).to.be.eq(toBN('1000'));

      expect(await sUSD.balanceOf(depositor1.address)).to.be.eq(toBN('2000'));
      expect(await sUSD.balanceOf(depositor2.address)).to.be.eq(toBN('1000'));
    });

    it("only depositor should be able to withdraw immediately", async () => {

      await expect(
        spreadLiquidityPool.connect(depositor2).initiateWithdraw(depositor1.address, toBN('500'))).to.be.revertedWith(
          'ERC20: burn amount exceeds balance',
        );

      await spreadLiquidityPool.connect(depositor1).initiateWithdraw(depositor1.address, toBN('500'));
      expect(await sUSD.balanceOf(depositor1.address)).to.be.eq(toBN('2500'));
      expect(await spreadLiquidityPool.balanceOf(depositor1.address)).to.be.eq(toBN('500'));

    })

  });

  describe("token price with no option market transactions or withdrawals", () => {

    it("has token price of 1 with no deposits", async () => {
      const tokenPrice = await spreadLiquidityPool.getTokenPrice();
      expect(tokenPrice).to.be.eq(toBN('1'))
    })

    before("deposit funds in liquidity pool", async () => {
      await sUSD.connect(depositor1).approve(spreadLiquidityPool.address, toBN('1000'));
      await spreadLiquidityPool.connect(depositor1).initiateDeposit(depositor1.address, toBN('1000'));
      expect(await sUSD.balanceOf(depositor1.address)).to.be.eq(toBN('1500'));
    })

    it("has token price of 1 with only deposits and deposits equal to quote funds", async () => {
      const tokenPrice = await spreadLiquidityPool.getTokenPrice();
      expect(tokenPrice).to.be.eq(toBN('1'));

      const lpTokenSupply = await spreadLiquidityPool.getTotalTokenSupply();
      expect(lpTokenSupply).to.be.eq(toBN('1500'));
    })
  });

  describe("set liquidity pools", () => {
    it("should be able to set valid parameters", async () => {
      await spreadLiquidityPool.connect(deployer).setLiquidityPoolParameters({
        minDepositWithdraw: toBN('10'),
        withdrawalDelay: toBN('0'),
        withdrawalFee: toBN('0'),
        guardianDelay: toBN('0'),
        cap: toBN('0'),
        fee: toBN('0.12'), // 20 % yearly
        guardianMultisig: guardian.address
      });
    })
  });

  describe("should correctly revert on only spread option market functionality", () => {
    it("should revert on attempt to transfer collateral", async () => {

      await expect(
        spreadLiquidityPool.connect(deployer).transferShortCollateral(toBN('150'))).to.be.revertedWith(
          'OnlySpreadOptionMarket',
        );

    })

    it("should revert on attempt to free locked liquidity", async () => {

      await expect(
        spreadLiquidityPool.connect(deployer).freeLockedLiquidity(toBN('150'))).to.be.revertedWith(
          'OnlySpreadOptionMarket',
        );

    })
  })

  describe("should correctly revert on only spread option market functionality", () => {
    it("should revert on attempt to transfer more collateral than free liquidity", async () => {

      await deployer.sendTransaction({
        to: spreadOptionMarket.address,
        value: toBN('1'), // Sends exactly 1.0 ether
      });

      await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [spreadOptionMarket.address],
      });

      const market = await ethers.getSigner(spreadOptionMarket.address)

      await expect(
        spreadLiquidityPool.connect(market).transferShortCollateral(toBN('1550'))).to.be.revertedWith(
          'LockingMoreQuoteThanIsFree',
        );

    })

  })

  describe("calculate fees", () => {
    it("calculate fees for 1 year", async () => {
      const _time = await time.latest();
      const fee = await spreadLiquidityPool.calculateCollateralFee(toBN('1000'), (YEAR_SEC) + _time);
      console.log({ fee })
      expect(fee).to.be.eq(toBN('120')); // 1000 * .12
    });

    it("token price should be constant after locking liquidity", async () => {

      // deposit more funds 
      await sUSD.connect(depositor1).approve(spreadLiquidityPool.address, toBN('500'));
      await spreadLiquidityPool.connect(depositor1).initiateDeposit(depositor1.address, toBN('500'));

      // get token price 
      expect(await sUSD.balanceOf(spreadLiquidityPool.address)).to.be.eq(toBN('2000'));

      const tokenPrice = await spreadLiquidityPool.getTokenPrice();
      expect(tokenPrice).to.be.eq(toBN('1'))

      // borrow collateral from option market
      await deployer.sendTransaction({
        to: spreadOptionMarket.address,
        value: toBN('1'), // Sends exactly 1.0 ether
      });

      await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [spreadOptionMarket.address],
      });

      const market = await ethers.getSigner(spreadOptionMarket.address)

      await spreadLiquidityPool.connect(market).transferShortCollateral(toBN('500'));

      // locked liquidity needs to be equal to transferred collateral
      const lockedLiquidity = await spreadLiquidityPool.lockedLiquidity();
      expect(lockedLiquidity).to.be.eq(toBN('500'));

      // token price should be more 
      const tokenPriceAfter = await spreadLiquidityPool.getTokenPrice();
      expect(tokenPriceAfter).to.be.eq(toBN('1'))

    })


    it("token price should increase after collecting fees", async () => {

      // deposit more funds 
      await sUSD.connect(depositor1).approve(spreadLiquidityPool.address, toBN('500'));
      await spreadLiquidityPool.connect(depositor1).initiateDeposit(depositor1.address, toBN('500'));

      // get token price 
      expect(await sUSD.balanceOf(spreadLiquidityPool.address)).to.be.eq(toBN('2000'));

      const tokenPrice = await spreadLiquidityPool.getTokenPrice();
      expect(tokenPrice).to.be.eq(toBN('1'))

      // borrow collateral from option market
      await deployer.sendTransaction({
        to: spreadOptionMarket.address,
        value: toBN('1'), // Sends exactly 1.0 ether
      });

      await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [spreadOptionMarket.address],
      });

      const market = await ethers.getSigner(spreadOptionMarket.address)

      await spreadLiquidityPool.connect(market).transferShortCollateral(toBN('500'));

      // locked liquidity needs to be equal to transferred collateral
      const lockedLiquidity = await spreadLiquidityPool.lockedLiquidity();
      expect(lockedLiquidity).to.be.eq(toBN('1000'));

      // return funds with fees
      // trader1 pays fee
      const _time = await time.latest();
      const fee = await spreadLiquidityPool.calculateCollateralFee(toBN('500'), (YEAR_SEC) + _time);
      console.log({ fee })
      await sUSD.connect(trader1).approve(spreadOptionMarket.address, fee);
      await sUSD.connect(market).transfer(spreadLiquidityPool.address, fee);

      // locked liquidity needs to decrease after paying back
      const lockedLiquidityAfter = await spreadLiquidityPool.lockedLiquidity();
      expect(lockedLiquidityAfter).to.be.eq(toBN('1000'));

      // token price should be more 
      const tokenPriceAfter = await spreadLiquidityPool.getTokenPrice();
      console.log({ tokenPriceAfter })
      expect(parseFloat(fromBN(tokenPriceAfter))).to.be.greaterThan(1);

    });

    it("initiate withdrawal below min set param should revert ", async () => {

      await expect(
        spreadLiquidityPool.connect(depositor1).initiateWithdraw(depositor1.address, toBN('1'))).to.be.revertedWith(
          'MinimumWithdrawNotMet',
        );

    })

    it("initiate withdrawal should add withdraw to queue", async () => {

      expect(await sUSD.balanceOf(depositor1.address)).to.be.eq(toBN('500'));
      await spreadLiquidityPool.connect(depositor1).initiateWithdraw(depositor1.address, toBN('100'));
      const lockedLiquidity = await spreadLiquidityPool.lockedLiquidity();
      expect(lockedLiquidity).to.be.eq(toBN('1000'));
      expect(await sUSD.balanceOf(depositor1.address)).to.be.eq(toBN('500'));

    })

  });

  describe("calculate available funds", () => {

  });


});
