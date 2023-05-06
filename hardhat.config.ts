import * as dotenv from "dotenv";
import "hardhat-deploy";
import "@typechain/hardhat";
import "@nomiclabs/hardhat-ethers";
import "hardhat-dependency-compiler";
import "@nomiclabs/hardhat-waffle";
import { lyraContractPaths } from "@lyrafinance/protocol/dist/test/utils/package/index-paths";
import "@nomiclabs/hardhat-etherscan";
import 'solidity-coverage';
import 'hardhat-docgen';

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
            }
        ],
    },
    networks: {
        hardhat: {
            accounts: {
                count: 10,
                accountsBalance: "10000000000000000000000", // 10ETH (Default)
            },
            deploy: ['deploy/local'],
        },
        "optimistic-mainnet": {
            url: process.env.NODE_URL_L2
                ? process.env.NODE_URL_L2
                : "",
            accounts: process.env.MAINNET_DEPLOY_PK
                ? [process.env.MAINNET_DEPLOY_PK]
                : undefined,
            verify: {
                etherscan: {
                    apiUrl: "https://api-optimistic.etherscan.io",
                },
            },
            deploy: ['deploy/optimism'],
        },
        "arbitrum-goerli": {
            url: process.env.NODE_URL_L2_ARB
                ? process.env.NODE_URL_L2_ARB
                : "",
            accounts: process.env.MAINNET_DEPLOY_PK
                ? [process.env.MAINNET_DEPLOY_PK]
                : undefined,
            verify: {
                etherscan: {
                    apiUrl: "https://api-goerli.arbiscan.io/"
                },
            },
            deploy: ['deploy/arbitrum'],
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
        // keep: true
    },
    gasReporter: {
        enabled: true,
        currency: "USD",
    },
    etherscan: {
        apiKey: {
            mainnet: process.env.ETHERSCAN_API_KEY,
            arbitrumGoerli: process.env.TESTNET_API_KEY
        },

    },
    docgen: {
        path: './docs',
        clear: true,
        runOnCompile: true,
    }
};

export default config;