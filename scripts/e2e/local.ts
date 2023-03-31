import { getGlobalDeploys } from "@lyrafinance/protocol";
import { fromBN, toBN } from "@lyrafinance/protocol/dist/scripts/util/web3utils";
import { ethers } from "hardhat";

const _accountFactory = "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82";
const lyraGlobal = getGlobalDeploys('local');

const test = async () => {
  try {
    console.info('------------- LOCAL INTEGRATION TEST -------------');
    // get account factory
    const [deployer, lyra, , , owner] = await ethers.getSigners();

    console.log('--------------- CREATE NEW ACCOUNT ----------------');
    const factory = await ethers.getContractAt('AccountFactory', _accountFactory)

    const newAccountTx = await factory.connect(owner).newAccount();

    const newAccount = await newAccountTx.wait();

    await timeout(5000)
    const event = newAccount.events?.find(
      (event: { event: string }) => {
        console.log({ event })
        return event.event === "NewAccount"
      }
    );

    const [, accountOrderAddress] = event?.args;

    await timeout(5000)

    console.log('--------------- QUOTE & ACCOUNT ORDER INSTANCE----------------');
    // const accountOrderAddress = '0x8acd85898458400f7db866d53fcff6f0d49741ff';
    const quote = await ethers.getContractAt(lyraGlobal.QuoteAsset.abi, lyraGlobal.QuoteAsset.address);
    const accountOrder = await ethers.getContractAt('AccountOrder', accountOrderAddress);
    const quoteContractAddr = await accountOrder.quoteAsset();
    console.log({ quoteContractAddr })
    console.log({ quote: quote.address })
    console.log('--------------- INCREASE ALLOWANCE ----------------');
    const allowanceTx = await quote.connect(owner).approve(accountOrder.address, toBN('1000'));
    await allowanceTx.wait();
    // deposit usd 
    console.log('--------------- DEPOSIT TO ACCOUNT ----------------');
    const depositTx = await accountOrder.connect(owner).deposit(toBN('1000'));
    await depositTx.wait();
    // susd check balance 
    const accountOrderBalance = await quote.balanceOf(accountOrderAddress);
    console.log({ susdContractAddr: quote.address })

    console.log({ accountOrderBalance: fromBN(accountOrderBalance) })
    // place order 
    console.log('----------------- PLACE ORDER ------------------')


    return true;
  } catch (e) {
    console.log(e);
  }
}

async function main() {
  await test();
  console.log("✅ Simple path test end to end new account => deposit => place order.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });


function timeout(ms: number) {
  return new Promise(resolve => setTimeout(resolve, ms));
}