import * as dotenv from "dotenv";
import "hardhat-deploy";
import "@typechain/hardhat";
import "@nomiclabs/hardhat-ethers";
import "hardhat-dependency-compiler";
import "@nomiclabs/hardhat-waffle";
import { lyraContractPaths } from "@lyrafinance/protocol/dist/test/utils/package/index-paths";
// import 'hardhat-ethernal';

dotenv.config();

const defaultNetwork = "localhost";

const config = {
    defaultNetwork,
    solidity: {
        compilers: [
            {
                version: "0.8.16",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 1,
                    },
                },
            },
            {
                version: "0.8.9",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 1,
                    },
                },
            },
            {
                version: "^0.8.9",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 1,
                    },
                },
            },
        ],
    },
    networks: {
        hardhat: {
            saveDeployments: true,
            forking: {
                url: process.env.NODE_URL_L2,
                blockNumber: 20000000
            },
            accounts: {
                count: 10,
                accountsBalance: "10000000000000000000000", // 10ETH (Default)
            },
            deploy: ['deploy/local'],
            deployments: ['deployments']
        }
    },
    namedAccounts: {
        deployer: {
            default: 0, // here this will by default take the first account as deployer
        },
        lyra: {
            default: 1
        },
        gelato: {
            default: 2
        },
        usd: {
            default: 3
        },
        owner: {
            default: 4
        }
    },
    dependencyCompiler: {
        paths: lyraContractPaths,
    },
    ethernal: {
        email: process.env.ETHERNAL_EMAIL,
        password: process.env.ETHERNAL_PASSWORD,
    }
};

export default config;
