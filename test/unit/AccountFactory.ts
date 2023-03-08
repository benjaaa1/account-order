import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
    AccountFactory,
    AccountOrder,
    AccountOrder__factory,
    LyraBase,
} from "../../typechain-types";
import { ZERO_ADDRESS } from "@lyrafinance/protocol/dist/scripts/util/web3utils";

const SUSD_PROXY = "0x8c6f28f2F1A3C87F0f938b96d27520d9751ec8d9";

const GELATO_OPS = "0xB3f5503f93d5Ef84b06993a1975B9D21B962892F";

let accountFactory: AccountFactory;
let accountOrderImpl: AccountOrder;
let accountOrder: AccountOrder;

describe("AccountFactory", async () => {
    let deployer: SignerWithAddress;
    let owner: SignerWithAddress;

    before("assign roles", async () => {
        [deployer, owner] = await ethers.getSigners();
    });

    before("deploy account order implementation", async () => {
        const AccountOrder = await ethers.getContractFactory("AccountOrder");
        accountOrderImpl = await AccountOrder.connect(deployer).deploy();
    })

    before("deploy account order factory", async () => {
        const AccountFactoryFactory = await ethers.getContractFactory("AccountFactory");
        accountFactory = await AccountFactoryFactory.connect(deployer).deploy(
            accountOrderImpl.address,
            SUSD_PROXY,
            ZERO_ADDRESS,
            ZERO_ADDRESS,
            GELATO_OPS
        );
    });

    describe("Account factory settings", function () {
        it("Should set correct quoteAsset", async () => {
            const quoteAsset = await accountFactory.quoteAsset();

            expect(quoteAsset).to.equal(SUSD_PROXY);
        });

        it("Should set the lyra bases", async () => {
            const _ethLyraBase = await accountFactory.ethLyraBase();
            expect(_ethLyraBase).to.equal(ZERO_ADDRESS);
        });
    });

    describe("Create new account", function () {
        it("Should create and set the right owner", async () => {
            const _accountOrderImpl = await accountFactory.implementation();
            const tx = await accountFactory.connect(owner).newAccount();
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
        });
    });
});
