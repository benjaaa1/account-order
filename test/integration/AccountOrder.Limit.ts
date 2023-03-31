import { expect } from "chai";
import { ethers, network, waffle } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  lyraConstants,
  TestSystem,
  getMarketDeploys,
  getGlobalDeploys,
  lyraEvm,
} from "@lyrafinance/protocol";
import { fromBN, toBN } from "@lyrafinance/protocol/dist/scripts/util/web3utils";
import { DEFAULT_PRICING_PARAMS } from "@lyrafinance/protocol/dist/test/utils/defaultParams";
import { TestSystemContractsType } from "@lyrafinance/protocol/dist/test/utils/deployTestSystem";
import { PricingParametersStruct } from "@lyrafinance/protocol/dist/typechain-types/OptionMarketViewer";
import {
  AccountFactory,
  AccountOrder,
  AccountOrder__factory,
  IOps__factory,
  LyraBase,
  LyraQuoter,
  MockERC20,
  SpreadOptionMarket,
} from "../../typechain-types";
import { LyraGlobal } from "@lyrafinance/protocol/dist/test/utils/package/parseFiles";
import { impersonateAccount, setBalance } from "@nomicfoundation/hardhat-network-helpers";
import {
  BigNumber,
  Contract,
  ContractTransaction,
  PopulatedTransaction,
  Transaction,
} from "ethers";
import { Address } from "hardhat-deploy/types";
import { ITradeTypes } from "../../typechain-types/contracts/AccountOrder";

const MARKET_KEY_ETH = ethers.utils.formatBytes32String("ETH");

let sUSD: MockERC20;
let lyraTestSystem: TestSystemContractsType;
let lyraBaseETH: LyraBase;
let lyraQuoter: LyraQuoter;

let accountFactory: AccountFactory;
let accountOrderImpl: AccountOrder;
let accountOrder: AccountOrder;
let spreadOptionMarket: SpreadOptionMarket;

let deployer: SignerWithAddress;
let owner: SignerWithAddress;

let lyraGlobal: LyraGlobal;
let gelatoOps: Contract;

let _accountOrderImpl: Address;
let tx: ContractTransaction;

const boardParameter = {
  expiresIn: lyraConstants.DAY_SEC * 7,
  baseIV: "0.8",
  strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
  skews: ["1.3", "1.2", "1.1", "1", "1.1", "1.3", "1.3"],
};

const spotPrice = toBN("3000");

// 1.5m lyra pool
const initialPoolDeposit = toBN("1500000");

const GELATO_OPS = "0x340759c8346A1E6Ed92035FB8B6ec57cE1D82c2c";
const GELATO_ETH = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";

let boardId = toBN("0");
let strikes: BigNumber[] = [];

const ACCOUNT_SUSD_AMOUNT = toBN("1000000");
const DEPOSIT_SUSD_AMOUNT = toBN("10000");

describe("account order integration", async () => {
  before("assign roles", async () => {
    [deployer, owner] = await ethers.getSigners();
  });

  before("deploy gelato for integration testing", async () => {
    await forkAtBlock(20000000);
    const OPS_ABI = IOps__factory.abi;
    gelatoOps = new ethers.Contract(GELATO_OPS, OPS_ABI, waffle.provider);
  });

  before("deploy lyra base eth", async () => {
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

    const LyraQuoterFactory = await ethers.getContractFactory("LyraQuoter", {
      libraries: { BlackScholes: lyraTestSystem.blackScholes.address },
    });

    lyraQuoter = (await LyraQuoterFactory.connect(deployer).deploy(
      lyraTestSystem.lyraRegistry.address
    )) as LyraQuoter;

    const LyraBaseETHFactory = await ethers.getContractFactory("LyraBase", {
      libraries: { BlackScholes: lyraTestSystem.blackScholes.address },
    });

    lyraBaseETH = (await LyraBaseETHFactory.connect(deployer).deploy(
      MARKET_KEY_ETH,
      lyraTestSystem.synthetixAdapter.address,
      lyraTestSystem.optionToken.address,
      lyraTestSystem.optionMarket.address,
      lyraTestSystem.liquidityPool.address,
      lyraTestSystem.shortCollateral.address,
      lyraTestSystem.optionMarketPricer.address,
      lyraTestSystem.optionGreekCache.address,
      lyraTestSystem.GWAVOracle.address,
      lyraQuoter.address
    )) as LyraBase;

    const boards = await lyraTestSystem.optionMarket.getLiveBoards();

    boardId = boards[0];

    await lyraTestSystem.optionGreekCache.updateBoardCachedGreeks(boardId);

    await lyraEvm.fastForward(600);
  });

  before("set strikes array", async () => {
    strikes = await lyraTestSystem.optionMarket.getBoardStrikes(boardId);
  });

  before("deploy account order implementation", async () => {
    const AccountOrder = await ethers.getContractFactory("AccountOrder");
    accountOrderImpl = (await AccountOrder.connect(deployer).deploy()) as AccountOrder;
  })

  before("deploy spread option market", async () => {
    const SpreadOptionMarket = await ethers.getContractFactory("SpreadOptionMarket");
    spreadOptionMarket = (await SpreadOptionMarket.connect(deployer).deploy()) as SpreadOptionMarket;
  })
  before("deploy account order factory", async () => {
    const AccountOrderFactory = await ethers.getContractFactory("AccountFactory");
    accountFactory = (await AccountOrderFactory.connect(deployer).deploy(
      accountOrderImpl.address,
      lyraTestSystem.snx.quoteAsset.address,
      lyraBaseETH.address,
      lyraBaseETH.address,
      spreadOptionMarket.address,
      GELATO_OPS
    )) as AccountFactory;
  });

  before("setup new account", async () => {
    _accountOrderImpl = await accountFactory.implementation();
    tx = await accountFactory.connect(owner).newAccount();
  });

  before("mint susd for owner", async () => {
    await sUSD.mint(owner.address, ACCOUNT_SUSD_AMOUNT);
  });

  describe("test new account create", function () {
    it("should create and set the right owner", async () => {
      const rc = await tx.wait(); // 0ms, as tx is already confirmed
      const event = rc.events?.find(
        (event: { event: string }) => event.event === "NewAccount"
      );
      const [user, accountOrderAddress] = event?.args;

      accountOrder = (await ethers.getContractAt(
        "AccountOrder",
        accountOrderAddress
      )) as AccountOrder;

      expect(accountOrderAddress).to.not.equal(_accountOrderImpl);
      expect(accountOrder.address).to.exist;
      expect(user).to.be.equal(owner.address);
      await setBalance(accountOrder.address, 10 ** 18);
    });
  });

  describe("get correct addresses from New Account Order", async () => {
    it("Should get correct lyra base", async () => {
      const _setLyraBase = await accountOrder.lyraBases(MARKET_KEY_ETH);
      expect(_setLyraBase).to.be.equal(lyraBaseETH.address);
    });

    it("Should get gelato ops address", async () => {
      const _ops = await accountOrder.ops();

      expect(_ops).to.be.equal(gelatoOps.address);
    });
  });

  describe("deposit and withdraw from account order", () => {
    it("Should Approve Allowance and Deposit Margin into Account", async () => {
      // approve allowance for marginAccount to spend
      await sUSD.connect(owner).approve(accountOrder.address, ACCOUNT_SUSD_AMOUNT);

      // deposit sUSD into margin account
      await accountOrder.connect(owner).deposit(ACCOUNT_SUSD_AMOUNT);

      // confirm deposit
      const balance = await sUSD.balanceOf(accountOrder.address);
      expect(balance).to.equal(ACCOUNT_SUSD_AMOUNT);
    });

    it("Should Withdraw Margin from Account", async () => {
      const preBalance = await sUSD.balanceOf(owner.address);

      // withdraw sUSD into margin account
      await accountOrder.connect(owner).withdraw(ACCOUNT_SUSD_AMOUNT);

      // confirm withdraw
      const marginAccountBalance = await sUSD.balanceOf(accountOrder.address);
      expect(marginAccountBalance).to.equal(0);

      const postBalance = await sUSD.balanceOf(owner.address);
      expect(preBalance).to.below(postBalance);
    });
  });

  describe("gelato integration: Place and cancel a limit long order", () => {
    let orderId: BigNumber;

    before("deposit user funds", async () => {
      // approve susd
      await sUSD.connect(owner).approve(accountOrder.address, DEPOSIT_SUSD_AMOUNT);

      // deposit sUSD into margin account
      await accountOrder.connect(owner).deposit(DEPOSIT_SUSD_AMOUNT);

    })

    before("place order", async () => {
      const strikeTrade: ITradeTypes.StrikeTradeStruct = buildOrder(
        2,
        toBN("2000"),
        toBN(".80"),
        strikes[2],
        0 // long call
      );

      orderId = await accountOrder.orderId();
      await accountOrder.connect(owner).placeOrder(strikeTrade);

    });

    it("should place an order:  long call order", async () => {

      const order = await accountOrder.connect(owner).orders(orderId);
      expect(order.strikeTrade.market).to.be.equal(MARKET_KEY_ETH);

    });

    it("should cancel order", async () => {
      // attempt to cancel order
      const order = await accountOrder.orders(0);
      await expect(accountOrder.connect(owner).cancelOrder(0))
        .to.emit(gelatoOps, "TaskCancelled")
        .withArgs(order.gelatoTaskId, accountOrder.address);

    });

  });

  describe("gelato integration: Execute limit long order (as Gelato)", () => {
    const gelatoFee = 100;

    beforeEach("deposit funds to account", async () => {
      // approve susd
      await sUSD.connect(owner).approve(accountOrder.address, DEPOSIT_SUSD_AMOUNT);

      // deposit sUSD into margin account
      await accountOrder.connect(owner).deposit(DEPOSIT_SUSD_AMOUNT);

    })

    beforeEach("place limit long order", async () => {
      // submit order to gelato
      const strikeTrade: ITradeTypes.StrikeTradeStruct = buildOrder(
        2, // order type (limitprice 1 limit vol 2)
        toBN("2000"), // target premium
        toBN(".80"), // target volatility
        strikes[2],
        0 // option type (long call 0)
      );

      await accountOrder.connect(owner).placeOrder(strikeTrade);
    });

    it("ExecSuccess emitted from gelato", async () => {

      const { tx, order, executeOrderCalldata } = await executeOrder(
        accountOrder,
        1, // orderId
        gelatoFee
      );

      await expect(tx)
        .to.emit(gelatoOps, "ExecSuccess")
        .withArgs(
          gelatoFee,
          GELATO_ETH,
          accountOrder.address,
          executeOrderCalldata,
          order.gelatoTaskId,
          true
        );
    });

    it("gelato task unregistered", async () => {
      const gelatoTaskId = (await accountOrder.orders(2)).gelatoTaskId;
      // Expect task to be registered
      expect(await gelatoOps.taskCreator(gelatoTaskId)).to.be.equal(accountOrder.address);

      const { tx } = await executeOrder(accountOrder, 2, gelatoFee);
      await tx;

      // Expect that we cancel the task for gelato after execution
      expect(await gelatoOps.taskCreator(gelatoTaskId)).to.be.equal(
        ethers.constants.AddressZero
      );
    });

    it("OrderFilled emitted", async () => {
      const { tx } = await executeOrder(accountOrder, 3, gelatoFee);

      await expect(tx)
        .to.emit(accountOrder, "OrderFilled")
        .withArgs(accountOrder.address, 3);
    });

    it("order 'book' cleared", async () => {
      const { tx } = await executeOrder(accountOrder, 4, gelatoFee);
      await tx;
      expect((await accountOrder.orders(4)).gelatoTaskId).to.be.equal(
        ethers.constants.HashZero
      );
    });
  });

  describe("gelato integration: Place and cancel a limit short order", () => {
    let orderId: BigNumber;

    beforeEach("deposit user funds", async () => {
      // approve susd
      await sUSD.connect(owner).approve(accountOrder.address, DEPOSIT_SUSD_AMOUNT);

      // deposit sUSD into margin account
      await accountOrder.connect(owner).deposit(DEPOSIT_SUSD_AMOUNT);
    });

    before("place order", async () => {
      const strikeTrade: ITradeTypes.StrikeTradeStruct = buildOrder(
        2,
        toBN("2000"),
        toBN(".80"),
        strikes[2],
        3 // short call
      );

      orderId = await accountOrder.orderId();
      await accountOrder.connect(owner).placeOrder(strikeTrade);

    });

    it("should place an order: short call order", async () => {
      const order = await accountOrder.connect(owner).orders(orderId);
      expect(order.strikeTrade.optionType).to.be.equal(3);
    });

    it("Should cancel order", async () => {
      const order = await accountOrder.orders(orderId);
      await expect(accountOrder.connect(owner).cancelOrder(orderId))
        .to.emit(gelatoOps, "TaskCancelled")
        .withArgs(order.gelatoTaskId, accountOrder.address);

    });

  });

  describe("gelato integration: Execute limit short order (as Gelato)", () => {
    let orderId: BigNumber;
    const gelatoFee = 100;

    beforeEach("deposit funds to account", async () => {
      // approve susd
      await sUSD.connect(owner).approve(accountOrder.address, DEPOSIT_SUSD_AMOUNT);

      // deposit sUSD into margin account
      await accountOrder.connect(owner).deposit(DEPOSIT_SUSD_AMOUNT);
    })

    beforeEach("place limit short order", async () => {
      // submit order to gelato
      const strikeTrade: ITradeTypes.StrikeTradeStruct = buildOrder(
        2, // order type (limitprice 1 limit vol 2)
        toBN("2000"), // target premium
        toBN(".95"), // target volatility
        strikes[2],
        3 // option type (long call 0)
      );

      orderId = await accountOrder.orderId();

      await accountOrder.connect(owner).placeOrder(strikeTrade);
    });

    it("ExecSuccess emitted from gelato", async () => {
      const { tx, order, executeOrderCalldata } = await executeOrder(
        accountOrder,
        orderId,
        gelatoFee
      );

      await expect(tx)
        .to.emit(gelatoOps, "ExecSuccess")
        .withArgs(
          gelatoFee,
          GELATO_ETH,
          accountOrder.address,
          executeOrderCalldata,
          order.gelatoTaskId,
          true
        );
    });

    it("gelato task unregistered", async () => {
      const gelatoTaskId = (await accountOrder.orders(orderId)).gelatoTaskId;
      // Expect task to be registered
      expect(await gelatoOps.taskCreator(gelatoTaskId)).to.be.equal(accountOrder.address);

      const { tx } = await executeOrder(accountOrder, orderId, gelatoFee);
      await tx;

      // Expect that we cancel the task for gelato after execution
      expect(await gelatoOps.taskCreator(gelatoTaskId)).to.be.equal(
        ethers.constants.AddressZero
      );
    });

    it("OrderFilled emitted", async () => {
      const { tx } = await executeOrder(accountOrder, orderId, gelatoFee);

      await expect(tx)
        .to.emit(accountOrder, "OrderFilled")
        .withArgs(accountOrder.address, orderId);
    });

    it("order 'book' cleared", async () => {
      const { tx } = await executeOrder(accountOrder, orderId, gelatoFee);
      await tx;
      expect((await accountOrder.orders(orderId)).gelatoTaskId).to.be.equal(
        ethers.constants.HashZero
      );
    });
  });


});

/**
 * @notice fork network at block number given
 */
const forkAtBlock = async (block: number) => {
  await network.provider.request({
    method: "hardhat_reset",
    params: [
      {
        forking: {
          jsonRpcUrl: process.env.NODE_URL_L2,
          blockNumber: block,
        },
      },
    ],
  });
};

/**
 * @notice execute order as gelato
 */
const executeOrder = async (accountOrder: AccountOrder, orderId: number | BigNumber, gelatoFee: number) => {
  const order = await accountOrder.orders(orderId);
  const gelato = await accountOrder.gelato();
  const checkerCalldata = accountOrder.interface.encodeFunctionData("checker", [orderId]);

  const executeOrderCalldata = accountOrder.interface.encodeFunctionData("executeOrder", [
    orderId,
  ]);

  const resolverHash = await gelatoOps.getResolverHash(accountOrder.address, checkerCalldata);

  // execute order as Gelato would
  await impersonateAccount(gelato);
  const tx = gelatoOps.connect(await ethers.getSigner(gelato)).exec(
    gelatoFee,
    GELATO_ETH,
    accountOrder.address,
    false,
    true, // reverts for off-chain sim
    resolverHash,
    accountOrder.address,
    executeOrderCalldata
  );

  return {
    tx,
    order,
    executeOrderCalldata,
  };
};

/**
 * @notice build lyra strike
 */
const buildOrder = (
  orderType: number,
  _targetPrice: BigNumber,
  _targetVol: BigNumber,
  _strikeId: BigNumber,
  _optionType: number
): ITradeTypes.StrikeTradeStruct => {
  return {
    collatPercent: toBN(".45"),
    iterations: 3,
    market: MARKET_KEY_ETH,
    optionType: _optionType, // long call
    strikeId: _strikeId,
    size: toBN("3"),
    positionId: 0,
    orderType: orderType, // LIMIT_PRICE 1 LIMIT_VOL 2
    tradeDirection: 0, // OPEN
    targetPrice: _targetPrice,
    targetVolatility: _targetVol,
    collateralToAdd: toBN('0'),
    setCollateralTo: toBN('0')
  };
};
