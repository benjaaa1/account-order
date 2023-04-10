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
import { days } from "@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time/duration";

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
    await sUSD.mint(depositor1.address, toBN("10000"));
    await sUSD.mint(depositor2.address, toBN("10000"));
    await sUSD.mint(depositor3.address, toBN("10000"));
    await sUSD.mint(spreadOptionMarket.address, toBN("10000"));
  });

  describe("deposit to liquidity pool and get lp tokens", () => {

    it("deposits immediately for first depositor", async () => {
      await sUSD.connect(depositor1).approve(spreadLiquidityPool.address, toBN('5000'));
      await spreadLiquidityPool.connect(depositor1).initiateDeposit(depositor1.address, toBN('5000'));

      expect(await sUSD.balanceOf(spreadLiquidityPool.address)).to.be.eq(toBN('5000'));
      expect(await spreadLiquidityPool.balanceOf(depositor1.address)).to.be.eq(toBN('5000'));

      expect(await sUSD.balanceOf(depositor1.address)).to.be.eq(toBN('5000'));
      expect(await sUSD.balanceOf(depositor2.address)).to.be.eq(toBN('10000'));
    });

    it("only depositor should be able to withdraw immediately", async () => {

      await expect(
        spreadLiquidityPool.connect(depositor2).initiateWithdraw(depositor1.address, toBN('5000'))).to.be.revertedWith(
          'ERC20: burn amount exceeds balance',
        );

      await spreadLiquidityPool.connect(depositor1).initiateWithdraw(depositor1.address, toBN('5000'));
      expect(await sUSD.balanceOf(depositor1.address)).to.be.eq(toBN('10000'));
      expect(await spreadLiquidityPool.balanceOf(depositor1.address)).to.be.eq(toBN('0'));

    })

  });

  describe("token price with no option market transactions or withdrawals", () => {

    it("has token price of 1 with no deposits", async () => {
      const tokenPrice = await spreadLiquidityPool.getTokenPrice();
      expect(tokenPrice).to.be.eq(toBN('1'))
    })

    it("token price of 1 with only deposits", async () => {

      await sUSD.connect(depositor1).approve(spreadLiquidityPool.address, toBN('1000'));
      await spreadLiquidityPool.connect(depositor1).initiateDeposit(depositor1.address, toBN('1000'));
      expect(await sUSD.balanceOf(depositor1.address)).to.be.eq(toBN('9000'));

      const tokenPrice = await spreadLiquidityPool.getTokenPrice();
      expect(tokenPrice).to.be.eq(toBN('1'));

      const lpTokenSupply = await spreadLiquidityPool.getTotalTokenSupply();
      expect(lpTokenSupply).to.be.eq(toBN('1000'));

      await spreadLiquidityPool.connect(depositor1).initiateWithdraw(depositor1.address, toBN('1000'));
      expect(await sUSD.balanceOf(depositor1.address)).to.be.eq(toBN('10000'));
    })

  });

  describe("set liquidity pools and circuit breakers", () => {
    it("should be able to set valid parameters", async () => {
      await spreadLiquidityPool.connect(deployer).setLiquidityPoolParameters({
        minDepositWithdraw: toBN('10'),
        withdrawalDelay: toBN('0'),
        withdrawalFee: toBN('0'),
        guardianDelay: toBN('0'),
        cap: toBN('0'),
        fee: toBN('0.10'), // 10 % yearly
        guardianMultisig: guardian.address
      });
    })

    it("should be able to set circuit breaker parameters", async () => {
      await spreadLiquidityPool.connect(deployer).setCircuiteBreakerParemeters({
        liquidityCBThreshold: toBN('.03'),
        liquidityCBTimeout: DAY_SEC * 3
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
      expect(fee).to.be.eq(toBN('100')); // 1000 * .1
    });
  });

  describe("lock liquidity", () => {
    it("token price should be constant after locking liquidity w/o fees", async () => {

      // deposit more funds 
      await sUSD.connect(depositor1).approve(spreadLiquidityPool.address, toBN('5000'));
      await spreadLiquidityPool.connect(depositor1).initiateDeposit(depositor1.address, toBN('5000'));

      // check pool balance 
      expect(await sUSD.balanceOf(spreadLiquidityPool.address)).to.be.eq(toBN('5000'));

      // token price is constant w/o option market txs
      const tokenPrice = await spreadLiquidityPool.getTokenPrice();
      expect(tokenPrice).to.be.eq(toBN('1'))

      // option market tx - borrow collateral from option market
      await deployer.sendTransaction({
        to: spreadOptionMarket.address,
        value: toBN('1'), // Sends exactly 1.0 ether
      });

      await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [spreadOptionMarket.address],
      });

      const market = await ethers.getSigner(spreadOptionMarket.address)

      await spreadLiquidityPool.connect(market).transferShortCollateral(toBN('1000'));

      // locked liquidity needs to be equal to transferred collateral
      const lockedLiquidity = await spreadLiquidityPool.lockedLiquidity();
      expect(lockedLiquidity).to.be.eq(toBN('1000'));

      // token price should be constant (no fees paid);  
      const tokenPriceAfter = await spreadLiquidityPool.getTokenPrice();
      expect(tokenPriceAfter).to.be.eq(toBN('1'))

    })
  })

  describe("lp token price - collecting fees", () => {

    it("token price should increase", async () => {
      const tokenPrice = await spreadLiquidityPool.getTokenPrice();
      expect(tokenPrice).to.be.eq(toBN('1'));

      // return funds with fees
      // trader1 pays fee
      const _time = await time.latest();
      const fee = await spreadLiquidityPool.calculateCollateralFee(toBN('1000'), (YEAR_SEC) + _time);

      await deployer.sendTransaction({
        to: spreadOptionMarket.address,
        value: toBN('1'), // Sends exactly 1.0 ether
      });

      await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [spreadOptionMarket.address],
      });

      const market = await ethers.getSigner(spreadOptionMarket.address)
      await sUSD.connect(market).transfer(spreadLiquidityPool.address, fee);

      const tokenPriceAfterFee = await spreadLiquidityPool.getTokenPrice();
      expect(tokenPriceAfterFee).to.be.gt(toBN('1'));

    });

  });

  describe("queued withdraws - fees", () => {

    it("initiate withdrawal should add withdraw to queue", async () => {

      const lockedLiquidityBefore = await spreadLiquidityPool.lockedLiquidity();
      expect(lockedLiquidityBefore).to.be.eq(toBN('1000'));

      expect(await sUSD.balanceOf(depositor1.address)).to.be.eq(toBN('5000'));

      await spreadLiquidityPool.connect(depositor1).initiateWithdraw(depositor1.address, toBN('1000'));

      const lockedLiquidity = await spreadLiquidityPool.lockedLiquidity();
      expect(lockedLiquidity).to.be.eq(toBN('1000'));

    })

    it("should store the token price at withdrawal", async () => {

      const tokenPrice = await spreadLiquidityPool.getTokenPrice();

      const queuedWithdrawalHead = await spreadLiquidityPool.queuedWithdrawalHead();
      expect(queuedWithdrawalHead).to.be.eq(1);

      const queuedWithdrawal = await spreadLiquidityPool.queuedWithdrawals(queuedWithdrawalHead);
      expect(queuedWithdrawal.tokenPriceAtWithdrawal).to.be.eq(tokenPrice);

    })

    it("token price remains constant after adding deposits but no fees", async () => {
      // deposit more funds depositor2
      const depositor2USDBalanceBefore = await sUSD.balanceOf(depositor2.address);
      expect(depositor2USDBalanceBefore).to.be.eq(toBN('10000'));

      await sUSD.connect(depositor2).approve(spreadLiquidityPool.address, toBN('5000'));
      await spreadLiquidityPool.connect(depositor2).initiateDeposit(depositor2.address, toBN('5000'));

      const tokenPrice = await spreadLiquidityPool.getTokenPrice();

      const queuedWithdrawalHead = await spreadLiquidityPool.queuedWithdrawalHead();
      const queuedWithdrawal = await spreadLiquidityPool.queuedWithdrawals(queuedWithdrawalHead);

      expect(queuedWithdrawal.tokenPriceAtWithdrawal).to.be.eq(tokenPrice);

      // free locked liquidity
      await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [spreadOptionMarket.address],
      });

      const market = await ethers.getSigner(spreadOptionMarket.address)
      const lockedLiquidity = await spreadLiquidityPool.lockedLiquidity();

      // to mock freeing locked liquidity make sure to send quote asset to pool
      await sUSD.connect(market).transfer(spreadLiquidityPool.address, lockedLiquidity);
      await spreadLiquidityPool.connect(market).freeLockedLiquidity(lockedLiquidity);

      // initiate instant withdrawal will be same as original depositor 2 deposit
      const depositor2USDBalance = await sUSD.balanceOf(depositor2.address);
      expect(depositor2USDBalance).to.be.eq(toBN('5000'));

      const lpTokenBalanceDepositor2 = await spreadLiquidityPool.balanceOf(depositor2.address);
      await spreadLiquidityPool.connect(depositor2).initiateWithdraw(depositor2.address, lpTokenBalanceDepositor2);

      const depositor2USDBalanceAfterWithdrawal = await sUSD.balanceOf(depositor2.address);
      const lpTokenBalanceDepositorAfterWithdraw2 = await spreadLiquidityPool.balanceOf(depositor2.address);

      expect(lpTokenBalanceDepositorAfterWithdraw2).to.be.eq(toBN('0'));
      // expect(depositor2USDBalanceAfterWithdrawal).to.be.eq(depositor2USDBalanceBefore);
    })

    it("processing withdrawal should collect original deposit + all fees - depositor 1", async () => {

      const depositor1USDBalanceBefore = await sUSD.balanceOf(depositor1.address);
      expect(depositor1USDBalanceBefore).to.be.eq(toBN('5000'));

      const queuedWithdrawalHead = await spreadLiquidityPool.queuedWithdrawalHead();
      const queuedWithdrawal = await spreadLiquidityPool.queuedWithdrawals(queuedWithdrawalHead);

      // process withdrawal 
      await spreadLiquidityPool.processWithdrawalQueue(queuedWithdrawalHead);
      const depositor1USDBalanceAfter = await sUSD.balanceOf(depositor1.address);

      const totalExpectWithdrawalAmount = parseFloat(fromBN(queuedWithdrawal.amountTokens)) * parseFloat(fromBN(queuedWithdrawal.tokenPriceAtWithdrawal));
      const expectedTotalBalance = totalExpectWithdrawalAmount + parseInt(fromBN(depositor1USDBalanceBefore));

      expect(depositor1USDBalanceAfter).to.be.eq(toBN(expectedTotalBalance.toString()));

      const lpTokenBalanceDepositor1 = await spreadLiquidityPool.balanceOf(depositor1.address);

      // depositor 1 should have 100 usd profit from fees after withdrawal
      // should withdraw immediately
      await spreadLiquidityPool.connect(depositor1).initiateWithdraw(depositor1.address, lpTokenBalanceDepositor1);
      const depositor1USDBalanceAfterFinal = await sUSD.balanceOf(depositor1.address);

      expect(depositor1USDBalanceAfterFinal).to.be.eq(toBN('10100'))

    });
  })
});