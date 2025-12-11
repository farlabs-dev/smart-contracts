**FAR Labs Smart Contracts**

This repository contains the public smart contracts powering the FAR Labs on-chain ecosystem, including our Token, Vesting, and Staking modules. All contracts are written with a focus on security, gas efficiency, and transparent upgradeability.

The goal of this repository is to serve as a canonical reference for developers, auditors, contributors, and integrators interacting with the FAR on-chain infrastructure.

**Contracts Overview**
1. FAR Token (ERC-20)

Our token implementation follows the battle-tested ERC-20
 standard, with additional safeguards for cross-chain migration and controlled minting (where applicable).
Key features:

Standards-compliant interfaces

Safe-math assumptions removed in favor of Solidity’s built-in checks

Role-based permissions via minimal access control

Supports token migration flows between networks

2. Vesting Contract

The vesting module provides deterministic token release schedules for contributors, partners, and ecosystem programs.
Core capabilities:

Linear and cliff-based vesting

Revocable and non-revocable schedules

On-chain transparency for unlocked, claimable, and remaining balances

Designed to avoid “black-box” vesting practices often seen in Web3 projects

3. Staking Contract

Our staking system is built for long-term sustainability of the FAR ecosystem, supporting flexible lock periods and real-time reward calculations.

** Recent Update**: BNB Chain Emission Module

The staking contract has been recently upgraded with BNB Chain–compatible emission logic to support the migration of FAR tokens to BNB Chain.
Highlights:

Emission-driven reward model optimized for high-throughput networks

Native BNB Chain compatibility (gas, block timing, event patterns)

Migration-friendly reward accounting ensuring continuity for existing FAR holders

Designed to integrate seamlessly with far-side DApps and custodial flows

This upgrade ensures consistent user experience and accurate reward distribution during and after the multi-chain migration.

**Architecture**

Token: Minimal, deterministic ERC-20 implementation for predictable gas and audit simplicity.

Staking: Modular reward engine with clear separation between accounting, emission, and user interactions.

Vesting: Stateless unlock calculations to guarantee transparency and reduce storage overhead.

For developers exploring the architecture, recommended reading includes:

Solidity design patterns https://docs.soliditylang.org/en/latest/common-patterns.html

Proxy and upgrade pattern considerations https://docs.openzeppelin.com/upgrades-plugins/1.x/proxies
