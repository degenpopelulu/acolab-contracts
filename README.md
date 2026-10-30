# Acolab contracts

Smart contracts for **Acolab — Agent Collective Onboarding** on BNB Smart Chain (chain ID 56).

## Current deployment: V6

The current website uses the V6 auction and release design, with **AMarket V2** as its buy-order market. It does not use the historical V5 fixed-price launch design.

Current ACO token: [0x460AE0A8030e614210c4D4b6F02C44FB1B932ac0](https://bscscan.com/address/0x460AE0A8030e614210c4D4b6F02C44FB1B932ac0). The public [deployment map](deployments/bsc-mainnet-v6.json) lists the platform, shared registry, DevPass, implementation addresses, markets and ACO modules. Addresses are a snapshot of the current deployment; future deployments must be checked separately.

| Source | Responsibility | BSC address / Sourcify verification |
| --- | --- | --- |
| [NameRegistry](contracts/NameRegistry.sol) | Shared symbol registration and uniqueness | [0x36f0b61D7c3523dc48309441532557520a91AD14](https://sourcify.dev/#/lookup/0x36f0b61D7c3523dc48309441532557520a91AD14?chainId=56) |
| [DevPass](contracts/DevPass.sol) | Transferable developer revenue rights (ERC-721) | [0x35ae8Bb16d50D7F036E26503436B5Ce75c42c3D7](https://sourcify.dev/#/lookup/0x35ae8Bb16d50D7F036E26503436B5Ce75c42c3D7?chainId=56) |
| [AToken](contracts/v6/AToken.sol) | ERC-20 balances, transfer and trading tax | [0x056d044b8C6091D79FE019EdD3c7C8DbE694d620](https://sourcify.dev/#/lookup/0x056d044b8C6091D79FE019EdD3c7C8DbE694d620?chainId=56) |
| [AAuction](contracts/v6/AAuction.sol) | Mint bids, round settlement, allocations and refunds | [0x4480503805f4615A51B1D6f0775e9B8CE144424d](https://sourcify.dev/#/lookup/0x4480503805f4615A51B1D6f0775e9B8CE144424d?chainId=56) |
| [AOpening](contracts/v6/AOpening.sol) | Graduation and liquidity initialization | [0xDBbae78f69733b13137fdcbA613d967233E3CE77](https://sourcify.dev/#/lookup/0xDBbae78f69733b13137fdcbA613d967233E3CE77?chainId=56) |
| [ALPLocker](contracts/v6/ALPLocker.sol) | Permanent LP custody | [0x6529D02B74ABbD3a5b8d3477c5983e997d85f704](https://sourcify.dev/#/lookup/0x6529D02B74ABbD3a5b8d3477c5983e997d85f704?chainId=56) |
| [ADividend](contracts/v6/ADividend.sol) | Holder rewards and claims | [0xce72531F3e1E113725AC1aDf57e5BB6D950Ba78C](https://sourcify.dev/#/lookup/0xce72531F3e1E113725AC1aDf57e5BB6D950Ba78C?chainId=56) |
| [AStaking](contracts/v6/AStaking.sol) | Stake accounting and reward claims | [0x72A89c4917b05dca1ee561565Ed879df5cE57dBd](https://sourcify.dev/#/lookup/0x72A89c4917b05dca1ee561565Ed879df5cE57dBd?chainId=56) |
| [ARelease](contracts/v6/ARelease.sol) | Scheduled token release | [0x06C8E98FcDEf9f0442d55b4159Fa00aC9A43b2c2](https://sourcify.dev/#/lookup/0x06C8E98FcDEf9f0442d55b4159Fa00aC9A43b2c2?chainId=56) |
| [AOracle](contracts/v6/AOracle.sol) | BNB/USD price feed checks | [0xd0C76dFE6184931D58dE09D1a913a46150a2CB39](https://sourcify.dev/#/lookup/0xd0C76dFE6184931D58dE09D1a913a46150a2CB39?chainId=56) |
| [APlatform](contracts/v6/APlatform.sol) | Asset creation and module deployment | [0x700C8666b7925273DB13Ed1D73FAc1cdF6fDf4D3](https://sourcify.dev/#/lookup/0x700C8666b7925273DB13Ed1D73FAc1cdF6fDf4D3?chainId=56) |
| [AMarket](contracts/v6/AMarket.sol) | Previous buy-order market | [0xA23bF69243E12528369ed63f2a4E6Afa38Ac4983](https://sourcify.dev/#/lookup/0xA23bF69243E12528369ed63f2a4E6Afa38Ac4983?chainId=56) |
| [AMarketV2](contracts/v6/AMarketV2.sol) | Current buy-order market, execution-time matching and BNB claim accounting | [0x5D0E5e1E06852Eb1a7fC4391CD7Dee6Fe77D6C0B](https://sourcify.dev/#/lookup/0x5D0E5e1E06852Eb1a7fC4391CD7Dee6Fe77D6C0B?chainId=56) |

All 13 contracts listed above have exact creation-bytecode and runtime-bytecode matches on Sourcify, checked on 2026-10-31. Their published source files match the verified source bytes. Verification shows correspondence between source and bytecode; it is not an independent security audit.

Per-asset contracts, including ACO, are ERC-1167 minimal proxies. Their logic is in the listed implementations; their individual proxy addresses are **not claimed to have independent Sourcify verification**. The deployment map records which modules correspond to which implementations. BscScan source/proxy badges are a separate explorer process and are not asserted here.

AMarket V1 remains on chain for existing orders and withdrawals. The website routes new market operations to AMarket V2; publication does not migrate or modify old orders.

## Historical V5 sources

The root-level Launchpad, LaunchToken, TaxProcessor, Dividend and KeeperRewardAccount sources remain available for historical deployments. The NameRegistry, DevPass and symbol libraries are shared by the published generations. Git history preserves the original V5 publication.

## Compile

Use Node.js 24 or newer:

```sh
npm ci --ignore-scripts
npm run compile
```

Compiler: Solidity 0.8.24, optimizer enabled with 200 runs, via IR, Cancun EVM. OpenZeppelin Contracts is pinned to 5.6.1. Source bytes are preserved through Git attributes so compilation metadata remains reproducible. The compiler-only configuration has no remote networks, signers or deployment task.

## Publication scope

Production Solidity sources, their interfaces and libraries, compilation files and public contract addresses are included. Backend services, trading tools, deployment credentials, wallet material and runtime configuration are excluded. Test harness contracts are not part of this source-only publication.

## License

MIT. OpenZeppelin dependencies retain their respective copyright notices and MIT license.
