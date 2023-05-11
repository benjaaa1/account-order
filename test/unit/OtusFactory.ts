import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
    OtusFactory,
    OtusOptionMarket,
    OtusVault,
    Strategy,
    OtusManager,
    MockERC20
} from "../../typechain-types";
import {
    lyraConstants,
    TestSystem,
    getGlobalDeploys,
    lyraEvm,
} from "@lyrafinance/protocol";
import { DEFAULT_PRICING_PARAMS } from "@lyrafinance/protocol/dist/test/utils/defaultParams";
import { TestSystemContractsType } from "@lyrafinance/protocol/dist/test/utils/deployTestSystem";
import { PricingParametersStruct } from "@lyrafinance/protocol/dist/typechain-types/OptionMarketViewer";
import { LyraGlobal } from "@lyrafinance/protocol/dist/test/utils/package/parseFiles";
import { ZERO_ADDRESS, toBN } from "@lyrafinance/protocol/dist/scripts/util/web3utils";
import { formatBytes32String } from "ethers/lib/utils";
import { Vault } from "../../typechain-types/contracts/OtusFactory";

let sUSD: MockERC20;
let otusManager: OtusManager;
let otusFactory: OtusFactory;
let otusVault: OtusVault;
let otusOptionMarket: OtusOptionMarket;
let strategy: Strategy;
let lyraTestSystem: TestSystemContractsType;

let lyraGlobal: LyraGlobal;

const boardParameter = {
    expiresIn: lyraConstants.DAY_SEC * 7,
    baseIV: "0.8",
    strikePrices: ["2500", "2600", "2700", "2800", "2900", "3000", "3100"],
    skews: ["1.3", "1.2", "1.1", "1", "1.1", "1.3", "1.3"],
};

const spotPrice = toBN("3000");

const initialPoolDeposit = toBN("1500000");

describe("OtusFactory", async () => {
    let deployer: SignerWithAddress;
    let owner: SignerWithAddress;

    before("assign roles", async () => {
        [deployer, owner] = await ethers.getSigners();
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

    before("deploy otus manager", async () => {
        const OtusManagerFactory = await ethers.getContractFactory("OtusManager");
        otusManager = (await OtusManagerFactory.connect(deployer).deploy()) as OtusManager;

        await otusManager.connect(deployer).initialize(ZERO_ADDRESS, ZERO_ADDRESS);
    })

    before("deploy otus option market", async () => {
        const OtusOptionMarketFactory = await ethers.getContractFactory("OtusOptionMarket");
        otusOptionMarket = (await OtusOptionMarketFactory.connect(deployer).deploy()) as OtusOptionMarket;
    })

    before("deploy otus vault implementation", async () => {
        const OtusVaultFactory = await ethers.getContractFactory("OtusVault");
        otusVault = (await OtusVaultFactory.connect(deployer).deploy()) as OtusVault;
    })

    before("deploy strategy implementation", async () => {
        const StrategyFactory = await ethers.getContractFactory("Strategy");
        strategy = (await StrategyFactory.connect(deployer).deploy(otusOptionMarket.address)) as Strategy;
    })

    before("deploy otus factory", async () => {
        const OtusFactoryFactory = await ethers.getContractFactory("OtusFactory");
        otusFactory = (await OtusFactoryFactory.connect(deployer).deploy(
            otusVault.address,
            strategy.address,
            otusManager.address
        )) as OtusFactory;
    })

    describe("Otus factory deploy", function () {
        it("Should be able to create a new vault", async () => {

            const vaultParams: Vault.VaultParamsStruct = {
                decimals: 18,
                cap: toBN('5000000'),
                asset: sUSD.address,
            };

            const tx = await otusFactory.connect(deployer).newVault(
                formatBytes32String("VAULT-1"),
                'Otus Vault V1 X1',
                'OTUSV1X1',
                vaultParams
            );

            const rc = await tx.wait(); // 0ms, as tx is already confirmed
            const event = rc.events?.find(
                (event: { event: string }) => event.event === "NewVault"
            );

            console.log({ event })

        });
    });

});
