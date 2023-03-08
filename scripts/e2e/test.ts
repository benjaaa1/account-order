import { toBN } from "@lyrafinance/protocol/dist/scripts/util/web3utils";
import { ethers, getNamedAccounts, getChainId, deployments } from "hardhat";

const _accountFactory = "0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6";

const test = async () => {
  try {
    console.info('---------- LOCAL INTEGRATION TEST ---------');

    // get account factory
    const [deployer, lyra, gelato, usd, owner] = await ethers.getSigners();

    const factory = await ethers.getContractAt('AccountFactory', _accountFactory)
    console.log({ factory })
    const ownerBalance = await owner.getBalance();
    console.log({ owner, ownerBalance })

    const newAccountTx = await factory.connect(owner).newAccount();
    console.log({ newAccountTx })
    const newAccount = await newAccountTx.wait();
    console.log({ newAccount })
    console.log("Delayed for 5 second.");

    await timeout(5000)

    const event = newAccount.events?.find(
      (event: { event: string }) => event.event === "NewAccount"
    );
    console.log({ event })

    // create new account 
    // create new account 

    // mint usd (susd or usdc) usd to owner

    // deposit usd 

    // place order 

    // execute order 


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