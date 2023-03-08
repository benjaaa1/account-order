import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
    lyraConstants,
    TestSystem,
    getMarketDeploys,
    getGlobalDeploys,
} from "@lyrafinance/protocol";
import { toBN } from "@lyrafinance/protocol/dist/scripts/util/web3utils";
import { DEFAULT_PRICING_PARAMS } from "@lyrafinance/protocol/dist/test/utils/defaultParams";
import { TestSystemContractsType } from "@lyrafinance/protocol/dist/test/utils/deployTestSystem";
import { PricingParametersStruct } from "@lyrafinance/protocol/dist/typechain-types/OptionMarketViewer";
import { LyraBase, LyraQuoter } from "../../typechain-types";
import { LyraGlobal, LyraMarket } from "@lyrafinance/protocol/dist/test/utils/package/parseFiles";

const MARKET_KEY_ETH = ethers.utils.formatBytes32String("ETH");

let lyraTestSystem: TestSystemContractsType;
let lyraBaseETH: LyraBase;
let lyraQuoter: LyraQuoter;

let deployer: SignerWithAddress;
let owner: SignerWithAddress;

let lyraMarket: LyraMarket;
let lyraGlobal: LyraGlobal;

const boardParameter = {
    expiresIn: lyraConstants.DAY_SEC * 7,
    baseIV: "0.8",
    strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
    skews: ["1.3", "1.2", "1.1", "1", "1.1", "1.3", "1.3"],
};

const spotPrice = toBN("3000");

const initialPoolDeposit = toBN("1500000"); // 1.5m

describe("lyra base", async () => {
    before("assign roles", async () => {
        [deployer, owner] = await ethers.getSigners();
    });

    before("deploy lyra base eth", async () => {
        lyraGlobal = getGlobalDeploys("local");
        lyraMarket = getMarketDeploys("local", "sETH");

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

        const LyraQuoterFactory = await ethers.getContractFactory("LyraQuoter", {
            libraries: { BlackScholes: lyraTestSystem.blackScholes.address },
        });

        lyraQuoter = await LyraQuoterFactory.connect(deployer).deploy(
            lyraTestSystem.lyraRegistry.address
        );

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
    });

    describe("Lyra addresses are set correctly", () => {
        it("correct option market", async () => {
            const optionMarket = await lyraBaseETH.getOptionMarket();
            expect(optionMarket).to.be.eq(lyraTestSystem.optionMarket.address);
        });
    });
});
