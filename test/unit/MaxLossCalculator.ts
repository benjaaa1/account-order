import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { MaxLossCalculator, MaxLossCalculator__factory } from "../../typechain-types";
import { fromBN, toBN } from "@lyrafinance/protocol/dist/scripts/util/web3utils";

let deployer: SignerWithAddress;
let owner: SignerWithAddress;

let maxLossCalculator: MaxLossCalculator;

describe("max loss calculator", async () => {

    before("assign roles", async () => {
        [deployer, owner] = await ethers.getSigners();
    });

    before("deploy max loss calculator", async () => {
        const MaxLossCalculatorFactory = await ethers.getContractFactory("MaxLossCalculator");
        maxLossCalculator = (await MaxLossCalculatorFactory.connect(deployer).deploy()) as MaxLossCalculator;
    })

    describe("test max loss calculator", () => {
        it("should return correct max loss - single trade", async () => {
            const strike = {
                strikePrice: toBN('3000'),
                amount: toBN('1'),
                premium: toBN('100'),
                optionType: 0
            };

            const maxLoss = await maxLossCalculator.calculate([strike]);
            expect(maxLoss).to.equal(toBN('100'));
        })

        it("should return correct max loss - 2 long calls", async () => {
            const strike1 = {
                strikePrice: toBN('1900'),
                amount: toBN('1'),
                premium: toBN('20'),
                optionType: 0
            };

            const strike2 = {
                strikePrice: toBN('1950'),
                amount: toBN('1'),
                premium: toBN('10'),
                optionType: 0
            };

            const maxLoss = await maxLossCalculator.calculate([strike1, strike2]);
            console.log({ maxLoss: fromBN(maxLoss) })
            expect(maxLoss).to.equal(toBN('30'));
        });

        it("should return correct max loss - bull call spread", async () => {
            const strike1 = {
                strikePrice: toBN('1900'),
                amount: toBN('1'),
                premium: toBN('65'),
                optionType: 0
            };

            const strike2 = {
                strikePrice: toBN('1950'),
                amount: toBN('1'),
                premium: toBN('45'),
                optionType: 3
            };

            const maxLoss = await maxLossCalculator.calculate([strike1, strike2]);
            expect(maxLoss).to.equal(toBN('20'));
        });

        it("should return correct max loss - put credit spread", async () => {
            const strike1 = {
                strikePrice: toBN('1700'),
                amount: toBN('1'),
                premium: toBN('13'),
                optionType: 1
            };

            const strike2 = {
                strikePrice: toBN('1750'),
                amount: toBN('1'),
                premium: toBN('17'),
                optionType: 4
            };

            const maxLoss = await maxLossCalculator.calculate([strike1, strike2]);

            expect(maxLoss).to.equal(toBN('46'));
        });

        it("should return correct max loss - credit spread", async () => {
            const strike1 = {
                strikePrice: toBN('1950'),
                amount: toBN('1'),
                premium: toBN('116'),
                optionType: 1
            };

            const strike2 = {
                strikePrice: toBN('1750'),
                amount: toBN('1'),
                premium: toBN('16'),
                optionType: 4
            };

            const maxLoss = await maxLossCalculator.calculate([strike1, strike2]);

            expect(maxLoss).to.equal(toBN('100'));
        });

        it("should return correct max loss - bear call spread", async () => {
            const strike1 = {
                strikePrice: toBN('1900'),
                amount: toBN('1'),
                premium: toBN('80'),
                optionType: 0
            };

            const strike2 = {
                strikePrice: toBN('1700'),
                amount: toBN('1'),
                premium: toBN('210'),
                optionType: 3
            };

            const maxLoss = await maxLossCalculator.calculate([strike1, strike2]);
            console.log({ maxLoss: fromBN(maxLoss) })

            expect(maxLoss).to.equal(toBN('70'));
        });


        it("should return correct max loss - short call ladder", async () => {

            const strike1 = {
                strikePrice: toBN('1950'),
                amount: toBN('1'),
                premium: toBN('40'),
                optionType: 0
            };

            const strike2 = {
                strikePrice: toBN('2000'),
                amount: toBN('1'),
                premium: toBN('25'),
                optionType: 0
            };

            const strike3 = {
                strikePrice: toBN('1750'),
                amount: toBN('1'),
                premium: toBN('160'),
                optionType: 3
            };

            const maxLoss = await maxLossCalculator.calculate([strike1, strike2, strike3]);

            expect(maxLoss).to.equal(toBN('105'));
        });

        it("should return correct max loss for different sizes ~ bull call spread", async () => {
            const strike1 = {
                strikePrice: toBN('2000'),
                amount: toBN('22'),
                premium: toBN('572'), // total amount paid / received for the option (premium * amount)
                optionType: 0
            };

            const strike2 = {
                strikePrice: toBN('1800'),
                amount: toBN('11'),
                premium: toBN('1276'), // total amount paid / received for the option (premium * amount)
                optionType: 3
            };

            const maxLoss = await maxLossCalculator.calculate([strike1, strike2]);
            console.log({ maxLoss: fromBN(maxLoss) })
            expect(maxLoss).to.equal(toBN('1496'));
        });

        it("should return correct max loss for different sizes ~ bull call spread", async () => {
            const strike1 = {
                strikePrice: toBN('2100'),
                amount: toBN('22'),
                premium: toBN('724'), // total amount paid / received for the option (premium * amount)
                optionType: 0
            };

            const strike2 = {
                strikePrice: toBN('1800'),
                amount: toBN('11'),
                premium: toBN('1705'), // total amount paid / received for the option (premium * amount)
                optionType: 3
            };

            const maxLoss = await maxLossCalculator.calculate([strike1, strike2]);
            console.log({ maxLoss: fromBN(maxLoss) })
            expect(maxLoss).to.equal(toBN('2319'));
        });

    });

});
