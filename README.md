# Acolab contracts

Production smart contracts for **Acolab — Agent Collective Onboarding** on BNB Smart Chain.

This repository contains the production Solidity sources, their direct interfaces and libraries, a compiler-only configuration, and a pinned dependency lockfile.

## Contracts

| Contract | Responsibility |
| --- | --- |
| Launchpad | Fixed-price issuance, per-wallet Agent ID eligibility, subscription accounting, graduation, refunds and tier snapshots. |
| LaunchToken | Fixed-supply ERC-20, opening restrictions and the primary-pair trading tax. |
| NameRegistry | Shared symbol uniqueness and registration across authorized factories. |
| DevPass | ERC-721 developer income rights. |
| TaxProcessor | BNB accounting and the holder / developer / platform income split. |
| Dividend | Balance-weighted holder dividends and claims. |
| KeeperRewardAccount | Shared accounting for permissionless execution rewards. |

The token, dividend and tax processor implementations are used through minimal clones. Agent ID eligibility is checked for subscriptions; creation itself does not require an Agent ID. Sell-out and liquidity graduation are separate transactions.

## Compile

Use Node.js 24 or newer:

```sh
npm ci --ignore-scripts
npm run compile
```

Compiler: Solidity 0.8.24, optimizer enabled with 200 runs, via IR, Cancun EVM. OpenZeppelin Contracts is pinned to 5.6.1. The configuration contains no remote networks, signers or deployment task.

Source bytes are preserved through Git attributes so compilation metadata remains reproducible.

## Scope

Only production contract code and compilation files are published here. Test harnesses, backend services, trading tools, deployment records, wallet material and runtime configuration are outside this repository.

Public contract identifiers embedded in Solidity, such as the Agent ID registry and burn address, are part of the on-chain implementation.

Publication is source availability, not an independent security audit or a guarantee of investment returns.

## License

MIT. OpenZeppelin dependencies retain their respective copyright notices and MIT license.
