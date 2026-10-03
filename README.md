# Flurbo contracts

Solidity pools, resolvers, contract tests and deployment scripts for the Flurbo Monad testnet product. These contracts use test AUSD and the current pilot resolver has an operator-controlled dispute panel.

This source was extracted from `Flurbo-cmm/Flurbo` at company commit `6d144cc`. The web repository keeps its market registry, rule preparation workflow and deployment records. It checks out a pinned commit of this repository for contract builds and local-chain tests; the web Docker image does not contain contract source.

## Local checks

Install Node 24 and Foundry, then run:

```sh
npm ci
forge test --summary
```

Run deployment scripts only with reviewed prepared files and an authorized testnet operator account. CI compiles and tests contracts without broadcasting transactions.
