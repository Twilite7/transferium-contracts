# Transferium Protocol — Smart Contracts

A decentralised football player transfer and loan protocol built on Arc Testnet. Transferium brings the legal and financial infrastructure of professional football transfers on-chain — player registration, identity verification, transfer escrow, loan agreements, and league governance.

## Overview

Transferium replaces the trust-based, opaque back-office of football transfers with transparent, auditable smart contracts. Clubs, players, agents, and league authorities interact directly on-chain — no intermediaries, no hidden fees, no disputed payments.

## Deployed Contracts (Arc Testnet — Chain ID 5042002)

| Contract | Address |
|---|---|
| PlayerRegistry | `0xdDa83cf2ADECD861Cc6aa947E167E29906BB77Ef` |
| TransferWindow | `0xcEDd544E087a670CcD4bBe0437F80BB6C8f837a4` |
| TransferEscrow | `0xa92C0648d97455D11713487FE6a1B784f74cB94A` |
| LoanEscrow | `0x2a0F089674ff1Eb1C035C19d61d4bfCc0360e9fC` |

## Architecture

### PlayerRegistry (ERC-721)
Each registered player is minted as an NFT owned by their club. The registry enforces a full compliance pipeline before a player can be listed for transfer:

- **Club registration** — only wallets with `CLUB_ROLE` can register players
- **Identity verification** — registrar must verify the player on-chain
- **Medical clearance** — registrar submits a hash of the medical report
- **Legal documents** — registration contract, identity document, FIFA TMS reference, and work permit hashes must all be unique across the entire registry
- **Player wallet** — a unique on-chain wallet is assigned to the player for receiving sell-on fees, performance bonuses, and salary guarantees

### TransferEscrow
Handles permanent player transfers between clubs. Supports:
- Transfer fee in EURC or USDC
- Agent fee (percentage routed to agent wallet)
- Sell-on clause (percentage of future sale routed to selling club)
- Performance add-ons (milestone-based payments to player wallet)
- Salary guarantee (locked in escrow, claimable by player wallet)
- Dispute window before funds are released

### LoanEscrow
Handles temporary loan agreements. Supports:
- Loan fee payments
- Recall mechanisms with notice periods
- Option to buy (converting a loan to a permanent transfer)
- Automatic settlement on loan expiry

### TransferWindow
Controls when transfers can be listed and executed. The league authority schedules open and close dates. Transfers outside the window are rejected at the contract level.

## Security Features

- Document hash uniqueness enforced globally — no two players can share a medical or legal document hash
- Player wallet uniqueness enforced globally — no two players can share the same wallet address
- Role-based access control (OpenZeppelin) — CLUB_ROLE, REGISTRAR_ROLE, ESCROW_ROLE, LEAGUE_ROLE
- Reentrancy protection on all state-changing functions
- Pausable contracts for emergency stops
- Transfer window enforcement at contract level

## Tech Stack

- Solidity 0.8.28
- Hardhat
- OpenZeppelin Contracts
- Arc Testnet (Chain ID 5042002)
- EURC and USDC whitelisted as payment tokens

## Test Coverage

33 tests passing across all four contracts covering the full transfer lifecycle, loan flows, dispute resolution, sell-on clauses, agent fees, performance add-ons, and salary guarantees.

```bash
npx hardhat test
```

## Deployment

```bash
npx hardhat run scripts/deploy.ts --network arc
npx hardhat run scripts/setup-test-roles.ts --network arc
npx hardhat run scripts/open-test-window.ts --network arc
```

## Frontend

The Transferium frontend is available at [github.com/Twilite7/transferium-frontend](https://github.com/Twilite7/transferium-frontend)

---

*Built on Arc Testnet. Security over speed. Always.*
